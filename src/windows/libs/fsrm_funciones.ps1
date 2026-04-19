# ==============================================================================
# LIBRERÍA: fsrm_funciones.ps1
# PROPÓSITO: Arquitectura Idempotente de Cuotas, File Screens y Auditoría FSRM
# ==============================================================================

Function Configurar-AlmacenamientoDinamicop8 {
    param (
        [string]$RutaCSV, 
        $reglasJSON # Pasamos el JSON como parámetro para aislar la función
    )

    Write-Host "`n[*] Inicializando Gobernanza de Almacenamiento (FSRM)..." -ForegroundColor Yellow

    $usuarios = Import-Csv -Path $RutaCSV -ErrorAction SilentlyContinue
    if (-not $usuarios) { 
        Write-Host "[!] ERROR: CSV no encontrado o vacio en la ruta: $RutaCSV" -ForegroundColor Red
        return 
    }

    # 1. Crear Bóveda Central y Recurso Compartido SMB
    $rutaBase = "C:\Perfiles_P8"
    if (-Not (Test-Path $rutaBase)) { 
        New-Item -Path $rutaBase -ItemType Directory -Force | Out-Null 
    }
    
    if (-Not (Get-SmbShare -Name "Perfiles_P8" -ErrorAction SilentlyContinue)) {
        Write-Host "  [*] Generando recurso SMB (\\$($env:COMPUTERNAME)\Perfiles_P8)" -ForegroundColor Cyan
        New-SmbShare -Name "Perfiles_P8" -Path $rutaBase -FullAccess "Todos" | Out-Null
    }

    # ==========================================================================
    # 2. MOTOR DE APANTALLAMIENTO (FILE SCREENING) Y EVIDENCIAS
    # ==========================================================================
    $nombreGrupoArchivos = "Bloqueo_Multimedia_Ejecutables_P8"
    if (-Not (Get-FsrmFileGroup -Name $nombreGrupoArchivos -ErrorAction SilentlyContinue)) {
        Write-Host "  [*] Creando Grupo de Archivos Prohibidos (*.mp3, *.exe, etc)..." -ForegroundColor Cyan
        New-FsrmFileGroup -Name $nombreGrupoArchivos -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") | Out-Null
    }

    # Crear la acción de Evidencia (Alerta Amarilla en Visor de Eventos)
    $accionEvidencia = New-FsrmAction -Type Event -EventType Warning `
        -Body "ALERTA ZERO-TRUST: El usuario [Source Io Owner] intento evadir la politica guardando el archivo prohibido: [Source File Path]." `
        -RunLimitInterval 0

    $nombrePlantillaFiltro = "Plantilla_Filtro_ZeroTrust_P8"
    if (-Not (Get-FsrmFileScreenTemplate -Name $nombrePlantillaFiltro -ErrorAction SilentlyContinue)) {
        Write-Host "  [*] Generando Plantilla de Apantallamiento..." -ForegroundColor Cyan
        New-FsrmFileScreenTemplate -Name $nombrePlantillaFiltro -IncludeGroup $nombreGrupoArchivos -Active:$true -Notification $accionEvidencia | Out-Null
    }

    # Aplicar el escudo a la carpeta raíz (Se hereda automáticamente a todos los usuarios)
    if (-Not (Get-FsrmFileScreen -Path $rutaBase -ErrorAction SilentlyContinue)) {
        New-FsrmFileScreen -Path $rutaBase -Template $nombrePlantillaFiltro | Out-Null
        Write-Host "  [+] Escudo FSRM y Auditoria de Eventos activado en la raiz: $rutaBase" -ForegroundColor Green
    }

    # ==========================================================================
    # 3. MOTOR DE CUOTAS DINÁMICAS E IDEMPOTENCIA
    # ==========================================================================
    Write-Host "  [*] Procesando Cuotas Strict-Limit por Usuario..." -ForegroundColor Cyan

    foreach ($user in $usuarios) {
        $valUser = $user.Usuario.Trim()
        $depto = $user.Departamento.Trim()
        
        # Buscar regla exacta del JSON
        $regla = $reglasJSON.GruposDefinidos | Where-Object { $_.NombreDepartamento -eq $depto }
        if (-Not $regla) { continue }

        # Generar la plantilla correspondiente si no existe (Ej. Plantilla_10MB_P8)
        $nombrePlantillaCuota = "Plantilla_$($regla.LimiteCuotaMB)MB_P8"
        if (-Not (Get-FsrmQuotaTemplate -Name $nombrePlantillaCuota -ErrorAction SilentlyContinue)) {
            New-FsrmQuotaTemplate -Name $nombrePlantillaCuota -Size ($regla.LimiteCuotaMB * 1MB) -LimitType Hard | Out-Null
        }

        # Asegurar que exista la carpeta física para inyectarle la cuota
        $rutaUsuario = "$rutaBase\$valUser"
        if (-Not (Test-Path $rutaUsuario)) { 
            New-Item -Path $rutaUsuario -ItemType Directory -Force | Out-Null 
        }

        # Lógica de Actualización (Idempotencia y Prevención de fallos)
        $cuotaActual = Get-FsrmQuota -Path $rutaUsuario -ErrorAction SilentlyContinue

        if ($cuotaActual) {
            if ($cuotaActual.Template -ne $nombrePlantillaCuota) {
                
                # Validación lógica: ¿El usuario tiene más datos de lo que permite su nueva cuota?
                $nuevoLimiteBytes = $regla.LimiteCuotaMB * 1MB
                if ($cuotaActual.Usage -gt $nuevoLimiteBytes) {
                    Write-Host "      [!] PELIGRO: Imposible reducir cuota de $valUser a $($regla.LimiteCuotaMB)MB. Uso actual es mayor. Se requiere limpieza manual." -ForegroundColor Red
                } else {
                    Set-FsrmQuota -Path $rutaUsuario -Template $nombrePlantillaCuota | Out-Null
                    Write-Host "      [~] Cuota de $valUser ajustada a $nombrePlantillaCuota (Cambio de departamento)" -ForegroundColor Magenta
                }
            }
        } else {
            New-FsrmQuota -Path $rutaUsuario -Template $nombrePlantillaCuota | Out-Null
            Write-Host "      [+] Cuota RIGIDA de $($regla.LimiteCuotaMB)MB asignada a $valUser" -ForegroundColor Green
        }
    }
    Write-Host "[OK] Subsistema de Almacenamiento FSRM actualizado y estable.`n" -ForegroundColor Green
}