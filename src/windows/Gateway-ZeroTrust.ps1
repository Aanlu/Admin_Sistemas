$rawUser = $env:USERNAME
# Normalización del nombre (maneja GOBERNANZA\usuario o usuario@dominio)
if ($rawUser -match "\\") { $rawUser = $rawUser.Split("\")[1] }
if ($rawUser -match "@")  { $rawUser = $rawUser.Split("@")[0] }
$usr = $rawUser.ToLower()

# --- EXCEPCIÓN VIP PARA ADMINISTRADOR SUPREMO (SOPORTE VS CODE) ---
if ($usr -match "^(administrador|administrator)$") {
    $originalCmd = $env:SSH_ORIGINAL_COMMAND
    if ($originalCmd) { 
        # VS Code envía scripts masivos; los ejecutamos directamente
        Invoke-Expression $originalCmd 
    } else { 
        # Sesión interactiva normal
        & powershell.exe -NoLogo -NoExit 
    }
    exit 0
}

# Soporte para transferencias SCP/SFTP para usuarios normales
$originalCmd = $env:SSH_ORIGINAL_COMMAND
if ($originalCmd -match "scp|sftp|rsync") { Invoke-Expression $originalCmd; exit 0 }

$motpDir = "C:\Program Files\multiOTP"
$motp    = "$motpDir\multiotp.exe"

Clear-Host
Write-Output " =============================================================== "
Write-Output "               UAS - SISTEMA ZERO-TRUST IDENTIDAD                  "
Write-Output " =============================================================== "
Write-Output "   [!] ALERTA: Conexion remota interceptada. Identidad: $usr"

$maxIntentos = 3
$intentos    = 0

while ($intentos -lt $maxIntentos) {
    Write-Output "   [>] Ingrese el codigo Google Authenticator (6 digitos):"
    $token = [Console]::ReadLine()

    # Validación directa con el motor multiOTP
    $p = New-Object System.Diagnostics.ProcessStartInfo -Property @{
        FileName = $motp; Arguments = "$usr $token"; WorkingDirectory = $motpDir;
        RedirectStandardOutput = $true; UseShellExecute = $false
    }
    $proc = [System.Diagnostics.Process]::Start($p); $proc.WaitForExit()

    if ($proc.ExitCode -eq 0) {
        Write-Output "`n   [+] ACCESO CONCEDIDO.`n"; & powershell.exe -NoLogo -NoExit; exit 0
    }
    $intentos++; $restantes = $maxIntentos - $intentos
    if ($restantes -gt 0) { Write-Output "   [X] Token incorrecto. Intentos restantes: $restantes" }
}

# --- BLOQUEO FÍSICO DE CUENTA (3 INTENTOS / 30 MIN) ---
Write-Output "`n   [!] Demasiados intentos. Bloqueando cuenta por 30 minutos..."
try {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Domain)
    # Forzamos fallos en AD para disparar la política de bloqueo
    1..4 | ForEach-Object { $ctx.ValidateCredentials($usr, "MFA_Lockout_$_") }
} catch {}
exit 1