Write-Host "`n=== FASE 3: DESPLIEGUE ZERO-TOUCH AL CLIENTE WIN10 (VERSIÓN CORE) ===" -ForegroundColor Cyan

$ClienteIP = Read-Host "Ingresa la IP de tu Windows 10 (Ej. 192.168.50.20)"

Write-Host "`n[*] Ingresa la contrasena del Administrador del dominio (No se vera al escribir):" -ForegroundColor Yellow
$Pass = Read-Host -AsSecureString
$Cred = New-Object System.Management.Automation.PSCredential ("GOBERNANZA\Administrador", $Pass)

$ScriptBlock = {
    param($NombreServidor)
    Write-Host " -> [CLIENTE] Iniciando operacion en $($env:COMPUTERNAME)..." -ForegroundColor Cyan
    
    # 1. Copiar toda la carpeta desde el servidor
    $RutaRed = "\\$NombreServidor\Deploy$\MFA_Provider"
    $RutaTemp = "C:\Windows\Temp\MFA_Provider"
    if (Test-Path $RutaTemp) { Remove-Item $RutaTemp -Recurse -Force }
    
    Write-Host " -> [CLIENTE] Copiando instalador desde el servidor..."
    Copy-Item -Path $RutaRed -Destination $RutaTemp -Recurse -Force
    
    # 2. Detectar e instalar
    Write-Host " -> [CLIENTE] Instalando Credential Provider de forma silenciosa..."
    $Exe = Get-ChildItem $RutaTemp -Filter "*.exe" -Recurse | Select-Object -First 1
    $Msi = Get-ChildItem $RutaTemp -Filter "*.msi" -Recurse | Select-Object -First 1
    
    if ($Msi) {
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($Msi.FullName)`" /qn /norestart" -Wait
    } elseif ($Exe) {
        Start-Process -FilePath $Exe.FullName -ArgumentList "/S" -Wait
    } else {
        $Cmd = Get-ChildItem $RutaTemp -Include "*install*.cmd", "*setup*.bat" -Recurse | Select-Object -First 1
        Start-Process -FilePath $Cmd.FullName -Wait
    }
    
    # 3. Excepción de Seguridad y Enlace a Base de Datos Central
    Write-Host " -> [CLIENTE] Configurando parametros de seguridad en el Registro..."
    $RegPath = "HKLM:\SOFTWARE\multiOTP"
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name "ExcludedUsers" -Value "Administrador" -Force
    
    $ExeMultiOTP = "C:\multiOTP\multiotp.exe"
    if (Test-Path $ExeMultiOTP) {
        Write-Host " -> [CLIENTE] Enlazando Boveda de Tokens hacia el servidor..."
        & $ExeMultiOTP -config users_folder="\\$NombreServidor\multiOTP_DB$" | Out-Null
        Write-Host " -> [CLIENTE] Enlace completado. Base de datos remota activa." -ForegroundColor Green
    } else {
        Write-Host " -> [CLIENTE] ALERTA: No se detecto multiotp.exe." -ForegroundColor Yellow
    }
    
    # 4. Limpieza del cliente
    Remove-Item $RutaTemp -Recurse -Force
    Write-Host " -> [CLIENTE] Operacion Finalizada con exito." -ForegroundColor Green
}

try {
    # Ejecutamos el asalto remoto usando WinRM
    Write-Host "[*] Conectando con $ClienteIP..." -ForegroundColor Yellow
    Invoke-Command -ComputerName $ClienteIP -Credential $Cred -ScriptBlock $ScriptBlock -ArgumentList $env:COMPUTERNAME
    
    Write-Host "`n[+] MISION CUMPLIDA. Reiniciando el cliente en 5 segundos..." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Restart-Computer -ComputerName $ClienteIP -Credential $Cred -Force
} catch {
    Write-Host "`n[X] ERROR DE CONEXIÓN WINRM: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    -> Si el mensaje dice 'Acceso Denegado' o 'RPC', el Firewall de Windows 10 esta bloqueando." -ForegroundColor DarkGray
}