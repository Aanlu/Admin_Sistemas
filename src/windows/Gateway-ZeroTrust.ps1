# Gateway-ZeroTrust.ps1
# FIX: normalizar username — en SSH puede llegar como DOMINIO\usuario o usuario@dominio

$rawUser = $env:USERNAME
# Quitar prefijo de dominio (DOMINIO\usuario → usuario)
if ($rawUser -match "\\") { $rawUser = $rawUser.Split("\")[1] }
# Quitar sufijo UPN (usuario@dominio → usuario)
if ($rawUser -match "@")  { $rawUser = $rawUser.Split("@")[0] }
$usr = $rawUser.ToLower()

$motpDir = "C:\Program Files\multiOTP"
$motp    = "$motpDir\multiotp.exe"

Clear-Host
Write-Host " =============================================================== " -ForegroundColor Cyan
Write-Host "             UAS - SISTEMA ZERO-TRUST IDENTIDAD                  " -ForegroundColor Cyan
Write-Host " =============================================================== " -ForegroundColor Cyan
Write-Host "   [!] ALERTA: Conexion remota interceptada." -ForegroundColor Yellow
Write-Host "   [*] Identidad: $usr" -ForegroundColor DarkGray
Write-Host ""

$maxIntentos = 3
$intentos    = 0

while ($intentos -lt $maxIntentos) {
    $token = Read-Host "   [>] Ingrese el codigo Google Authenticator (6 digitos)"

    $proc = Start-Process -FilePath $motp `
        -ArgumentList $usr, $token `
        -WorkingDirectory $motpDir `
        -NoNewWindow -Wait -PassThru

    if ($proc.ExitCode -eq 0) {
        Write-Host "`n   [+] ACCESO CONCEDIDO." -ForegroundColor Green
        Start-Sleep -Seconds 1
        Clear-Host
        powershell.exe -NoProfile -NoExit
        exit 0
    }

    $intentos++
    $restantes = $maxIntentos - $intentos
    if ($restantes -gt 0) {
        Write-Host "   [X] Token incorrecto. Intentos restantes: $restantes" -ForegroundColor Red
    }
}

# 3 fallos → bloquear cuenta en AD
Write-Host "`n   [!] Demasiados intentos fallidos. Bloqueando cuenta..." -ForegroundColor Red
try {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    Disable-ADAccount -Identity $usr -ErrorAction SilentlyContinue
    # También marcar error_counter en multiOTP (ya lo hace automáticamente si está configurado)
} catch {}

Start-Sleep -Seconds 2
exit 1