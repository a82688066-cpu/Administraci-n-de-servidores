@echo off
:: Doble clic: se eleva a administrador y configura TODO el servidor (IP, DNS, correo)
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
set "SELF=%~f0"
set "BATDIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF); iex $c.Substring($c.LastIndexOf('#PSBEGIN'))"
echo.
pause
exit /b

#PSBEGIN
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Dir = $env:BATDIR

# ================= VARIABLES (ajusta si hace falta) =================
$IP           = "192.168.2.5"
$Prefijo      = 24
$Gateway      = "192.168.2.1"
$Dominio      = "panaderia3.com"
$Adaptador    = ""                 # vacio = primera tarjeta conectada
$AdminHMail   = "Admin1234"        # clave de Administrator de hMailServer (el script la fija)
$PassUsuarios = "1234"
$Usuarios     = "tere","oscar","angel","marta","sara","sergio"
$UrlHMail     = "https://www.hmailserver.com/download_file?downloadid=271"
# =====================================================================

try {
    # ---------- 1. IP estatica ----------
    Write-Host "[1/6] Configurando IP estatica..." -ForegroundColor Cyan
    if (-not $Adaptador) { $Adaptador = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).Name }
    Get-NetIPAddress -InterfaceAlias $Adaptador -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $Adaptador -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $Adaptador -IPAddress $IP -PrefixLength $Prefijo -DefaultGateway $Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $Adaptador -ServerAddresses $IP

    # ---------- 2. DNS ----------
    Write-Host "[2/6] Instalando DNS y creando zona $Dominio..." -ForegroundColor Cyan
    Install-WindowsFeature DNS -IncludeManagementTools | Out-Null
    if (-not (Get-DnsServerZone -Name $Dominio -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -Name $Dominio -ZoneFile "$Dominio.dns"
    }
    foreach ($n in "@","www","mail") {
        if (-not (Get-DnsServerResourceRecord -ZoneName $Dominio -Name $n -RRType A -ErrorAction SilentlyContinue)) {
            Add-DnsServerResourceRecordA -ZoneName $Dominio -Name $n -IPv4Address $IP
        }
    }
    if (-not (Get-DnsServerResourceRecord -ZoneName $Dominio -RRType MX -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordMX -ZoneName $Dominio -Name "." -MailExchange "mail.$Dominio" -Preference 10
    }

    # ---------- 3. Firewall ----------
    Write-Host "[3/6] Abriendo puertos..." -ForegroundColor Cyan
    New-NetFirewallRule -DisplayName "Correo SMTP/POP3/IMAP" -Direction Inbound -Protocol TCP -LocalPort 25,110,143 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "DNS UDP" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "DNS TCP" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "ICMP Echo" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # ---------- 4. Instalar hMailServer ----------
    Write-Host "[4/6] Revisando hMailServer..." -ForegroundColor Cyan
    if (-not (Get-Service hMailServer -ErrorAction SilentlyContinue)) {
        $inst = Get-ChildItem -Path $Dir -Filter "hMailServer*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        $ruta = $null
        if ($inst) { $ruta = $inst.FullName }
        else {
            Write-Host "  No hay instalador en la carpeta, intentando descargarlo..."
            $tmp = Join-Path $env:TEMP "hMailServer-setup.exe"
            try {
                Invoke-WebRequest -Uri $UrlHMail -OutFile $tmp -UseBasicParsing
                if ((Get-Item $tmp).Length -gt 5MB) { $ruta = $tmp }
            } catch { }
        }
        if (-not $ruta) {
            throw "No se encontro ni se pudo descargar hMailServer. Descargalo de hmailserver.com, ponlo junto a este .bat (hMailServer-x.x.x.exe) y vuelve a abrirlo."
        }
        Write-Host "  Instalando hMailServer (puede tardar un par de minutos)..."
        Start-Process $ruta -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/SP-" -Wait
    }

    # ---------- 5. Fijar clave de administrador ----------
    Write-Host "[5/6] Preparando hMailServer..." -ForegroundColor Cyan
    Start-Service hMailServer -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8
    $ini = Join-Path ${env:ProgramFiles(x86)} "hMailServer\Bin\hMailServer.INI"
    if (-not (Test-Path $ini)) { $ini = Join-Path $env:ProgramFiles "hMailServer\Bin\hMailServer.INI" }
    if (Test-Path $ini) {
        $md5  = [Security.Cryptography.MD5]::Create()
        $hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($AdminHMail)))).Replace("-","").ToLower()
        Stop-Service hMailServer -Force
        $txt = Get-Content $ini -Raw
        if ($txt -match '(?m)^AdministratorPassword=.*$') {
            $txt = $txt -replace '(?m)^AdministratorPassword=.*$', "AdministratorPassword=$hash"
        } else {
            $txt = $txt -replace '(?m)^\[Security\]\s*$', "[Security]`r`nAdministratorPassword=$hash"
        }
        Set-Content -Path $ini -Value $txt -Encoding ASCII
        Start-Service hMailServer
    }

    # ---------- 6. Dominio y cuentas ----------
    Write-Host "[6/6] Creando dominio y usuarios de correo..." -ForegroundColor Cyan
    $app = $null; $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $app = New-Object -ComObject hMailServer.Application
            if ($app.Authenticate("Administrator", $AdminHMail)) { $ok = $true; break }
        } catch { }
        Start-Sleep -Seconds 3
    }
    if (-not $ok) { throw "No se pudo entrar a hMailServer (autenticacion)." }

    try { $dom = $app.Domains.ItemByName($Dominio) }
    catch {
        $dom = $app.Domains.Add()
        $dom.Name = $Dominio
        $dom.Active = $true
        $dom.Save()
    }
    foreach ($u in $Usuarios) {
        $mail = "$u@$Dominio"
        $existe = $true
        try { $null = $dom.Accounts.ItemByAddress($mail) } catch { $existe = $false }
        if (-not $existe) {
            $acc = $dom.Accounts.Add()
            $acc.Address  = $mail
            $acc.Password = $PassUsuarios
            $acc.Active   = $true
            $acc.Save()
            Write-Host "  Cuenta creada: $mail"
        }
    }

    Write-Host ""
    Write-Host "LISTO. Servidor $IP con DNS y correo de $Dominio." -ForegroundColor Green
    Write-Host "Usuarios: $($Usuarios -join ', ') | clave: $PassUsuarios"
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
