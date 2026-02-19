$global:LOG_FILE = "..\..\logs\windows_services.log"

function Log-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Blue }
function Log-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Warning { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }

function Pausa {
    Write-Host "`nPresione cualquier tecla para continuar..." -NoNewline -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
    Write-Host ""
}

function Instalar-DependenciaSilenciosa {
    param([string]$FeatureName)
    
    $check = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
    if ($check.Installed) { return $true }

    Write-Host "[AVISO] Instalando rol requerido: $FeatureName..." -ForegroundColor Yellow
    
    try {
        Install-WindowsFeature -Name $FeatureName -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Host "`r[OK] Rol instalado y listo: $FeatureName                 " -ForegroundColor Green
        return $true
    } catch {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] CRITICO: Fallo al instalar $FeatureName. Detalle: $($_.Exception.Message)" | Out-File -FilePath $global:LOG_FILE -Append
        
        Write-Host "`r[ERROR] Fallo al instalar $FeatureName. Revise el log." -ForegroundColor Red
        return $false
    }
}

function Generar-Menu {
    param(
        [string]$Titulo,
        [string[]]$Opciones,
        [string]$TextoSalida
    )
    
    $MenuOpciones = $Opciones + $TextoSalida
    $Seleccion = 0

    while ($true) {
        Clear-Host
        Write-Host "================================================="
        Write-Host "                 $Titulo" -ForegroundColor Yellow
        Write-Host "================================================="
        
        for ($i=0; $i -lt $MenuOpciones.Count; $i++) {
            if ($i -eq $Seleccion) {
                Write-Host "> $($MenuOpciones[$i])" -BackgroundColor Green -ForegroundColor Black
            } else {
                Write-Host "  $($MenuOpciones[$i])"
            }
        }
        
        $key = [System.Console]::ReadKey($true)
        if ($key.Key -eq "UpArrow") { 
            $Seleccion--
            if ($Seleccion -lt 0) { $Seleccion = $MenuOpciones.Count - 1 }
        } elseif ($key.Key -eq "DownArrow") { 
            $Seleccion++
            if ($Seleccion -ge $MenuOpciones.Count) { $Seleccion = 0 }
        } elseif ($key.Key -eq "Enter") {
            return $Seleccion
        }
    }
}

function Obtener-IP-Local {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.InterfaceAlias -notmatch "vEthernet" } | Select-Object -First 1 -ExpandProperty IPAddress
    return $ip
}

function Capturar-IP {
    param([string]$Mensaje)
    
    $ip_local = Obtener-IP-Local
    
    while ($true) {
        Write-Host "$Mensaje [Enter para usar: $($ip_local -join '')]: " -NoNewline
        $input_ip = Read-Host
        
        if ([string]::IsNullOrWhiteSpace($input_ip) -and $ip_local) {
            $input_ip = $ip_local
        }
        
        if (Validar-Formato-IP $input_ip) {
            return $input_ip
        } else {
            Log-Error "IP invalida o prohibida. Intente de nuevo."
        }
    }
}