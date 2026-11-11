#Requires -RunAsAdministrator
# ===== Configuración del servidor Correo y DNS (Windows Server) =====
$ErrorActionPreference = "Stop"

# ---------- Variables (ajusta si hace falta) ----------
$IP        = "192.168.2.5"
$Prefijo   = 24
$Gateway   = "192.168.2.1"
$Dominio   = "panaderia3.com"
$Adaptador = ""            # vacío = toma la primera tarjeta conectada
$AdminHMail = ""           # contraseña de Administrator de hMailServer
$PassUsuarios = "1234"
$Usuarios  = "tere","oscar","angel","marta","sara","sergio"
$Instalador = Get-ChildItem -Path $PSScriptRoot -Filter "hMailServer*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1

# ---------- 1. IP estática ----------
Write-Host "[1/5] Configurando IP estática..." -ForegroundColor Cyan
if (-not $Adaptador) { $Adaptador = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).Name }
Get-NetIPAddress -InterfaceAlias $Adaptador -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceAlias $Adaptador -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceAlias $Adaptador -IPAddress $IP -PrefixLength $Prefijo -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceAlias $Adaptador -ServerAddresses $IP

# ---------- 2. Rol DNS ----------
Write-Host "[2/5] Instalando DNS y creando zona $Dominio..." -ForegroundColor Cyan
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
Write-Host "[3/5] Abriendo puertos de correo y DNS..." -ForegroundColor Cyan
New-NetFirewallRule -DisplayName "Correo SMTP/POP3/IMAP" -Direction Inbound -Protocol TCP -LocalPort 25,110,143 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "DNS" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "ICMP Echo" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -ErrorAction SilentlyContinue | Out-Null

# ---------- 4. hMailServer ----------
Write-Host "[4/5] Revisando hMailServer..." -ForegroundColor Cyan
if (-not (Get-Service hMailServer -ErrorAction SilentlyContinue)) {
    if ($Instalador) {
        Write-Host "Instalando $($Instalador.Name)..."
        Start-Process $Instalador.FullName -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART" -Wait
    } else {
        Write-Host "No está hMailServer. Descarga el instalador (hMailServer-x.x.x.exe) y ponlo junto a este script, o instálalo a mano, y vuelve a ejecutar." -ForegroundColor Yellow
        exit 1
    }
}
Start-Service hMailServer -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# ---------- 5. Dominio y cuentas ----------
Write-Host "[5/5] Creando dominio y usuarios de correo..." -ForegroundColor Cyan
$app = New-Object -ComObject hMailServer.Application
if (-not $app.Authenticate("Administrator", $AdminHMail)) {
    Write-Host "No se pudo autenticar en hMailServer. Revisa la variable `$AdminHMail." -ForegroundColor Red
    exit 1
}
try { $dom = $app.Domains.ItemByName($Dominio) }
catch {
    $dom = $app.Domains.Add()
    $dom.Name = $Dominio
    $dom.Active = $true
    $dom.Save()
}
foreach ($u in $Usuarios) {
    $mail = "$u@$Dominio"
    try { $null = $dom.Accounts.ItemByAddress($mail) }
    catch {
        $acc = $dom.Accounts.Add()
        $acc.Address  = $mail
        $acc.Password = $PassUsuarios
        $acc.Active   = $true
        $acc.Save()
        Write-Host "  Cuenta creada: $mail"
    }
}
Write-Host "Listo. Servidor $IP con DNS y correo de $Dominio." -ForegroundColor Green
