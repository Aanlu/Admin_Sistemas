# ==============================================================================
# LIBRERÍA: gobernanza_funciones.ps1
# PROPÓSITO: Motor CRUD para reglas_gobernanza.json
# ==============================================================================

# ==============================================================================
# LIBRERÍA: gobernanza_funciones.ps1
# PROPÓSITO: Motor CRUD y Visualización para reglas_gobernanza.json
# ==============================================================================

# ==============================================================================
# FUNCIONES DE VALIDACIÓN DE ENTORNO Y RED
# ==============================================================================

function Verificar-EntornoGobernanza {
    Write-Host "  [*] Verificando integridad del entorno de Directorio Activo..." -ForegroundColor Cyan
    $domain = Get-ADDomain -ErrorAction SilentlyContinue
    if (-not $domain) {
        Write-Host "  [!] ERROR CRÍTICO: Este servidor no es un Controlador de Dominio." -ForegroundColor Red
        Write-Host "      No se pueden aplicar políticas de gobernanza sin Active Directory." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Asegurar-EnrutamientoDNS {
    Write-Host "  [*] Auditando enrutamiento DNS local..." -ForegroundColor Cyan
    
    # Obtener la IP principal del servidor
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    
    # Obtener los servidores DNS configurados en la tarjeta de red
    $dns = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" -ErrorAction SilentlyContinue | Select-Object -First 1).ServerAddresses
    
    # Si el servidor no se apunta a sí mismo (localhost o su propia IP), AD y las uniones de Linux fallarán
    if ($dns -notcontains $ip -and $dns -notcontains "127.0.0.1" -and $dns -notcontains "::1") {
        Write-Host "  [!] ALERTA: El servidor no usa su propio DNS. Corrigiendo adaptador de red..." -ForegroundColor Yellow
        try {
            Set-DnsClientServerAddress -InterfaceAlias "Ethernet*" -ServerAddresses ("127.0.0.1", "8.8.8.8") -ErrorAction Stop
            Write-Host "  [+] Enrutamiento DNS corregido (Loopback inyectado)." -ForegroundColor Green
        } catch {
            Write-Host "  [!] Fallo al corregir DNS. Verifica si la interfaz se llama 'Ethernet'." -ForegroundColor Red
        }
    } else {
        Write-Host "  [+] Enrutamiento DNS correcto." -ForegroundColor Green
    }
}

Function Cargar-Reglas {
    # Ruta dinamica (sube 3 niveles desde la libreria hasta la raiz)
    $rutaReglas = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\config\reglas_gobernanza.json")
    
    if (-Not (Test-Path $rutaReglas)) {
        Write-Host "[!] ERROR CRÍTICO: No se encuentra el JSON en $rutaReglas" -ForegroundColor Red
        return $null
    }
    
    return Get-Content $rutaReglas -Raw | ConvertFrom-Json
}

Function Show-AdministrarReglas {
    $reglas = Cargar-Reglas
    
    if ($null -eq $reglas) { 
        Write-Host "  -> El sistema no pudo cargar el JSON." -ForegroundColor Red
        return 
    }
    
    Write-Host "`n=== REGLAS GLOBALES ACTIVAS (JSON) ===" -ForegroundColor Cyan
    
    # Iteramos sobre el arreglo correcto que tienes en tu JSON
    foreach ($grupo in $reglas.GruposDefinidos) {
        Write-Host "Departamento : $($grupo.NombreDepartamento)" -ForegroundColor Yellow
        Write-Host "  -> Ruta OU  : $($grupo.RutaOU)"
        Write-Host "  -> Cuota    : $($grupo.LimiteCuotaMB) MB"
        Write-Host "  -> Horario  : De $($grupo.HorarioPermitido.HoraInicio):00 a $($grupo.HorarioPermitido.HoraFin):00"
    }
    
    Write-Host "`nAdministradores Supremos:" -ForegroundColor Magenta
    Write-Host "  -> $($reglas.AdministradoresSupremos -join ', ')"
    Write-Host ""
    pause
}

Function Guardar-Reglas {
    param($ObjetoReglas)
    $rutaReglas = Join-Path $global:REPO_ROOT "config\reglas_gobernanza.json"
    $ObjetoReglas | ConvertTo-Json -Depth 5 | Out-File -FilePath $rutaReglas -Encoding UTF8 -Force
    Write-Host "[OK] Reglas inyectadas en JSON exitosamente." -ForegroundColor Green
}
