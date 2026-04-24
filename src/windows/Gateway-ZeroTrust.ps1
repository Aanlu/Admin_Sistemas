$rawUser = $env:USERNAME
if ($rawUser -match "\\") { $rawUser = $rawUser.Split("\")[1] }
if ($rawUser -match "@")  { $rawUser = $rawUser.Split("@")[0] }
$usr = $rawUser.ToLower()

$motpDir = "C:\Program Files\multiOTP"
$motp    = "$motpDir\multiotp.exe"

$mapaUsuarios = @{
    "administrador"   = "administrator"
    "administrator"   = "administrator"
    "admin_identidad" = "admin_identidad"
    "admin_storage"   = "admin_storage"
    "admin_politicas" = "admin_politicas"
    "admin_auditoria" = "admin_auditoria"
}
$usrMotp = if ($mapaUsuarios.ContainsKey($usr)) { $mapaUsuarios[$usr] } else { $usr }

$originalCmd = $env:SSH_ORIGINAL_COMMAND
if ($originalCmd -match "scp|sftp|rsync") { Invoke-Expression $originalCmd; exit 0 }

Clear-Host
Write-Output " =============================================================== "
Write-Output "             UAS - SISTEMA ZERO-TRUST IDENTIDAD                  "
Write-Output " =============================================================== "
Write-Output "   [!] ALERTA: Conexion remota interceptada."
Write-Output "   [*] Identidad: $usr"
Write-Output ""

$maxIntentos = 3
$intentos    = 0

while ($intentos -lt $maxIntentos) {
    Write-Output "   [>] Ingrese el codigo Google Authenticator (6 digitos):"
    $token = [Console]::ReadLine()

    $p = New-Object System.Diagnostics.ProcessStartInfo
    $p.FileName               = $motp
    $p.Arguments              = "$usrMotp $token"
    $p.WorkingDirectory       = $motpDir
    $p.RedirectStandardOutput = $true
    $p.RedirectStandardError  = $true
    $p.UseShellExecute        = $false
    $proc = [System.Diagnostics.Process]::Start($p)
    $proc.WaitForExit()

    if ($proc.ExitCode -eq 0) {
        Write-Output ""
        Write-Output "   [+] ACCESO CONCEDIDO."
        Write-Output ""
        & powershell.exe -NoLogo -NoExit
        exit 0
    }

    $intentos++
    $restantes = $maxIntentos - $intentos
    if ($restantes -gt 0) {
        Write-Output "   [X] Token incorrecto. Intentos restantes: $restantes"
    }
}

Write-Output ""
Write-Output "   [!] Demasiados intentos. Bloqueando cuenta por 30 minutos..."
try {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
        [System.DirectoryServices.AccountManagement.ContextType]::Domain
    )
    1..4 | ForEach-Object { $ctx.ValidateCredentials($usr, "MFA_Block_$_") }
} catch {}

Start-Sleep -Seconds 2
exit 1