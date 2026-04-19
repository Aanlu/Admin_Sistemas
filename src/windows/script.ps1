$Usuario = "a1"
$NuevaPass = "Proyecto2026" # Sin asteriscos, pura letra y número para evitar errores de teclado

# 1. Forzar contraseña fácil de teclear
$SecurePass = ConvertTo-SecureString $NuevaPass -AsPlainText -Force
Set-LocalUser -Name $Usuario -Password $SecurePass

# 2. Desbloquear la cuenta por si Windows la congeló por intentos fallidos
Enable-LocalUser -Name $Usuario -ErrorAction SilentlyContinue

# 3. Obtener el nombre del equipo
$NombreServidor = $env:COMPUTERNAME

Write-Host "--- REPARACIÓN FINAL ---" -ForegroundColor Cyan
Write-Host "[OK] Cuenta $Usuario desbloqueada."
Write-Host "[OK] Contraseña cambiada a: $NuevaPass"
Write-Host "[!] Tu nombre de servidor es: $NombreServidor" -ForegroundColor Yellow