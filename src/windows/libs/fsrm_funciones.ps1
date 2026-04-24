# ==============================================================================
# LIBRERÍA: fsrm_funciones.ps1
# PROPÓSITO: Arquitectura Idempotente de Cuotas, File Screens y Auditoría FSRM
# ==============================================================================

Function Configurar-AlmacenamientoDinamicop8 {
    param ([string]$RutaCSV, $reglasJSON)

    Write-Host "`n[*] Inicializando Gobernanza de Almacenamiento (FSRM)..." -ForegroundColor Yellow

    $usuarios = Import-Csv -Path $RutaCSV -ErrorAction SilentlyContinue
    if (-not $usuarios) { Write-Host "[!] ERROR: CSV no encontrado o vacio." -ForegroundColor Red; return }

    $rutaBase           = "C:\Perfiles_P8"
    $rutaPerfilesMoviles = "C:\Admin_Sistemas\RoamingProfiles"

    foreach ($path in @($rutaBase, $rutaPerfilesMoviles)) {
        if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
    }

    $nombreGrupoArchivos = "Bloqueo_Multimedia_Ejecutables_P8"
    if (-not (Get-FsrmFileGroup -Name $nombreGrupoArchivos -ErrorAction SilentlyContinue)) {
        New-FsrmFileGroup -Name $nombreGrupoArchivos -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi") | Out-Null
    }

    $nombrePlantillaFiltro = "Plantilla_Filtro_ZeroTrust_P8"
    if (-not (Get-FsrmFileScreenTemplate -Name $nombrePlantillaFiltro -ErrorAction SilentlyContinue)) {
        $accionEvento = New-FsrmAction -Type Event -EventType Warning -Body "FSRM BLOQUEO: [Source Io Owner] intento guardar [Source File Path]" -RunLimitInterval 0
        New-FsrmFileScreenTemplate -Name $nombrePlantillaFiltro -IncludeGroup $nombreGrupoArchivos -Active:$true -Notification $accionEvento | Out-Null
    }

    foreach ($targetPath in @($rutaBase, $rutaPerfilesMoviles)) {
        if (-not (Get-FsrmFileScreen -Path $targetPath -ErrorAction SilentlyContinue)) {
            New-FsrmFileScreen -Path $targetPath -Template $nombrePlantillaFiltro -Active:$true | Out-Null
            Write-Host "  [+] FileScreen activo (tiempo real) en: $targetPath" -ForegroundColor Green
        }
    }

    foreach ($user in $usuarios) {
        $valUser = $user.Usuario.Trim()
        $depto   = $user.Departamento.Trim()

        $regla = $reglasJSON.GruposDefinidos | Where-Object { $_.NombreDepartamento -eq $depto }
        if (-not $regla) {
            $regla = $reglasJSON.GruposDefinidos | Where-Object {
                ($depto -match "No" -and $_.NombreDepartamento -match "No") -or
                ($depto -notmatch "No" -and $_.NombreDepartamento -notmatch "No")
            } | Select-Object -First 1
        }
        if (-not $regla) { continue }

        $limiteMB = $regla.LimiteCuotaMB
        $nombrePlantillaCuota = "Plantilla_${limiteMB}MB_P8"

        if (-not (Get-FsrmQuotaTemplate -Name $nombrePlantillaCuota -ErrorAction SilentlyContinue)) {
            New-FsrmQuotaTemplate -Name $nombrePlantillaCuota -Size ($limiteMB * 1MB) -HardLimit $true | Out-Null
        }

        $rutaH = "$rutaBase\$valUser"
        if (-not (Test-Path $rutaH)) { New-Item -Path $rutaH -ItemType Directory -Force | Out-Null }

        foreach ($subDir in @("Desktop", "Documents", "Downloads")) {
            $rutaSub = "$rutaH\$subDir"
            if (-not (Test-Path $rutaSub)) { New-Item -Path $rutaSub -ItemType Directory -Force | Out-Null }
        }

        icacls $rutaH /grant "${valUser}:(OI)(CI)F" /T 2>$null | Out-Null
        icacls $rutaH /grant "*S-1-5-32-544:(OI)(CI)F" /T 2>$null | Out-Null

        $cuotaActual = Get-FsrmQuota -Path $rutaH -ErrorAction SilentlyContinue
        if ($cuotaActual) {
            if ($cuotaActual.Template -ne $nombrePlantillaCuota) {
                Set-FsrmQuota -Path $rutaH -Template $nombrePlantillaCuota | Out-Null
                Write-Host "      [~] Cuota de $valUser ajustada a $($limiteMB)MB" -ForegroundColor Magenta
            }
        } else {
            New-FsrmQuota -Path $rutaH -Template $nombrePlantillaCuota | Out-Null
            Write-Host "      [+] Cuota rigida $($limiteMB)MB para $valUser en H: + subfolders" -ForegroundColor Green
        }

        $rutaV6 = "$rutaPerfilesMoviles\$valUser.V6"
        if (Test-Path $rutaV6) {
            if (-not (Get-FsrmQuota -Path $rutaV6 -ErrorAction SilentlyContinue)) {
                New-FsrmQuota -Path $rutaV6 -Template $nombrePlantillaCuota | Out-Null
                Write-Host "      [+] Cuota rigida $($limiteMB)MB en perfil movil $valUser.V6" -ForegroundColor Green
            }
        }
    }
    Write-Host "[OK] FSRM sincronizado. FileScreen activo en tiempo real en Perfiles_P8 y RoamingProfiles.`n" -ForegroundColor Green
}