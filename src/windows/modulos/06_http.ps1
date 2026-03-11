# Las libs (utils.ps1, validaciones.ps1, seguridad.ps1) y http_funciones.ps1
# son cargadas por menu_principal.ps1 antes de invocar Menu-HTTP.
# Se eliminaron los dot-source locales porque $PSScriptRoot apuntaba al directorio
# de menu_principal.ps1 al momento de carga, rompiendo la ruta a http_funciones.ps1.

function Desplegar-ServidorHTTP {
    Clear-Host
    $arr_motores = @("iis", "apache", "nginx")

    $opcion_motor = Generar-Menu "SELECCIONE EL MOTOR HTTP A DESPLEGAR" $arr_motores "Volver al menú HTTP"
    if ($opcion_motor -eq $arr_motores.Count) { return }
    $motor_seleccionado = $arr_motores[$opcion_motor]

    Write-Host "`n[*] Interrogando repositorios de Chocolatey y Kernel de Windows..." -ForegroundColor Cyan
    $versionesObj = Extraer-VersionesDinamicas -Motor $motor_seleccionado

    if (-not $versionesObj -or $versionesObj.Count -eq 0) {
        Log-Error "Fallo de red o repositorios. Verifique su conexión a internet."
        Pausa; return
    }

    $arr_versiones  = @($versionesObj)
    $opcion_version = Generar-Menu "SELECCIONE LA VERSIÓN DE $($motor_seleccionado.ToUpper())" $arr_versiones "Cancelar"
    if ($opcion_version -eq $arr_versiones.Count) { return }

    $version_con_etiqueta = $arr_versiones[$opcion_version]
    $version_seleccionada = ($version_con_etiqueta -split " ")[0]

    Clear-Host
    Write-Host "--- FASE 2: CONFIGURACIÓN DE RED ---`n" -ForegroundColor Yellow
    $puerto_seleccionado = 0

    while ($true) {
        $puerto_seleccionado = Capturar-Entero "Ingrese el puerto TCP de escucha deseado"
        Write-Host "[*] Auditando disponibilidad del puerto $puerto_seleccionado..." -ForegroundColor Cyan

        $estado_puerto = Validar-PuertoTCP -Puerto $puerto_seleccionado

        if ($estado_puerto -eq 0) {
            Log-Ok "Puerto $puerto_seleccionado libre y validado en la tabla TCP."
            break
        }
        elseif ($estado_puerto -eq 2) {
            Log-Error "El puerto $puerto_seleccionado esta reservado para infraestructura critica (RDP, SMB, etc)."
        }
        else {
            Log-Error "El puerto YA ESTÁ EN USO en el Kernel de Windows. Elija otro."
        }
    }

    Write-Host "`n--- FASE 3: APROVISIONAMIENTO SILENCIOSO ---" -ForegroundColor Yellow
    if (Instalar-PaquetesWeb -Motor $motor_seleccionado -Version $version_seleccionada) {
        Log-Ok "Binarios aprovisionados e instalados correctamente."
    }
    else {
        Log-Error "Fallo crítico en descarga o instalación."; Pausa; return
    }

    Write-Host "`n--- FASE 4: INYECCIÓN DE PARÁMETROS DE RED ---" -ForegroundColor Yellow
    if (Configurar-PuertoServicio -Motor $motor_seleccionado -Puerto $puerto_seleccionado) {
        Log-Ok "Servicio $motor_seleccionado atado al puerto $puerto_seleccionado y Firewall ajustado."
    }
    else {
        Log-Error "Fallo al inyectar el puerto en el archivo de configuración."; Pausa; return
    }

    Write-Host "`n--- FASE 5: APLICACIÓN DE HARDENING (SEGURIDAD) ---" -ForegroundColor Yellow
    Aplicar-HardeningSeguridad -Motor $motor_seleccionado
    Aislar-DirectorioWeb -Motor $motor_seleccionado
    Log-Ok "Firmas del servidor apagadas, cabeceras preventivas NTFS aplicadas."

    Write-Host "`n--- FASE 6: INYECCIÓN DE CONTENIDO WEB ---" -ForegroundColor Yellow
    Desplegar-PlantillaHTML -Motor $motor_seleccionado -Version $version_seleccionada -Puerto $puerto_seleccionado
    Log-Ok "Página Index generada a partir de la plantilla maestra transpuesta a Windows."

    Pausa
}

function Escanear-ServiciosVivos {
    $servicios  = @()
    $conexiones = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq "::" -or $_.LocalAddress -eq "127.0.0.1"
    }

    foreach ($conn in $conexiones) {
        $puerto = $conn.LocalPort
        $proc   = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        $motor  = "Desconocido"

        if ($proc.Name -match "httpd")                                { $motor = "Apache" }
        elseif ($proc.Name -match "nginx")                            { $motor = "Nginx" }
        elseif ($proc.Name -eq "System" -or $proc.Name -match "w3wp") {
            if (Get-Service W3SVC -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') {
                $motor = "IIS"
            }
        }

        if ($motor -ne "Desconocido") {
            $item = "$puerto - $motor"
            if ($servicios -notcontains $item) { $servicios += $item }
        }
    }
    return $servicios
}

function Prueba-CabeceraHTTP {
    Clear-Host
    Write-Host "--- AUDITORÍA LOCAL DE CABECERAS HTTP ---" -ForegroundColor Yellow

    $puertos_vivos = Escanear-ServiciosVivos
    if (-not $puertos_vivos -or $puertos_vivos.Count -eq 0) {
        Log-Error "No se detectó ningún servidor web corriendo en el sistema."
        Pausa; return
    }

    $opcion = Generar-Menu "SELECCIONE EL PUERTO Y SERVICIO A AUDITAR" $puertos_vivos "Cancelar"
    if ($opcion -eq $puertos_vivos.Count) { return }

    $seleccion = $puertos_vivos[$opcion]
    $puerto    = ($seleccion -split " - ")[0]

    Clear-Host
    Write-Host "`n[*] Lanzando petición web (Head) hacia localhost:$puerto...`n" -ForegroundColor Cyan

    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$puerto" -Method Head -UseBasicParsing -ErrorAction Stop
        Write-Host "HTTP $([int]$response.StatusCode) $($response.StatusDescription)"
        foreach ($header in $response.Headers.Keys) {
            Write-Host "$header: $($response.Headers[$header])"
        }
    }
    catch {
        if ($_.Exception.Response) {
            $response = $_.Exception.Response
            Write-Host "HTTP $([int]$response.StatusCode) $($response.StatusCode)"
            foreach ($header in $response.Headers.Keys) {
                Write-Host "$header: $($response.Headers[$header])"
            }
        }
        else {
            Log-Error "Conexión rechazada o fallo crítico en la petición. El servicio podría estar colgado."
        }
    }
    Pausa
}

function Modificar-PuertoCaliente {
    Clear-Host
    Write-Host "--- MODIFICADOR DE PUERTOS EN CALIENTE ---" -ForegroundColor Yellow

    $arr_instalados = @()
    if (Get-Service W3SVC  -ErrorAction SilentlyContinue) { $arr_instalados += "iis" }
    if (Get-Service apache -ErrorAction SilentlyContinue) { $arr_instalados += "apache" }
    if (Get-Process nginx  -ErrorAction SilentlyContinue) { $arr_instalados += "nginx" }

    if ($arr_instalados.Count -eq 0) {
        Log-Error "No se encontró ningún servicio web en ejecución o instalado."
        Pausa; return
    }

    $eleccion = Generar-Menu "SELECCIONE EL SERVICIO A MODIFICAR" $arr_instalados "Cancelar"
    if ($eleccion -eq $arr_instalados.Count) { return }
    $motor = $arr_instalados[$eleccion]

    Clear-Host
    Write-Host "[*] Servicio seleccionado: $($motor.ToUpper())" -ForegroundColor Cyan

    $puerto_nuevo = 0
    while ($true) {
        $puerto_nuevo = Capturar-Entero "Ingrese el NUEVO puerto TCP de escucha deseado"
        $estado = Validar-PuertoTCP -Puerto $puerto_nuevo

        if ($estado -eq 0)     { break }
        elseif ($estado -eq 2) { Log-Error "El puerto $puerto_nuevo está reservado para infraestructura crítica." }
        else                   { Log-Error "El puerto YA ESTÁ EN USO en el Kernel. Elija otro." }
    }

    Write-Host "`n[*] Deteniendo el servicio $($motor.ToUpper())..." -ForegroundColor Cyan
    if ($motor -eq "iis")        { Stop-Service W3SVC  -Force -ErrorAction SilentlyContinue }
    elseif ($motor -eq "apache") { Stop-Service apache -Force -ErrorAction SilentlyContinue }
    elseif ($motor -eq "nginx")  { Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force }

    Write-Host "[*] Inyectando el puerto $puerto_nuevo y actualizando el Firewall..." -ForegroundColor Cyan
    if (Configurar-PuertoServicio -Motor $motor -Puerto $puerto_nuevo) {
        $rutaHtml = ""
        if ($motor -eq "iis")        { $rutaHtml = "C:\inetpub\wwwroot\index.html" }
        elseif ($motor -eq "apache") { $rutaHtml = "C:\tools\apache24\htdocs\index.html" }
        elseif ($motor -eq "nginx")  { $rutaHtml = "C:\tools\nginx\html\index.html" }

        if (Test-Path $rutaHtml) {
            (Get-Content $rutaHtml -Raw) -replace 'id="puerto-display">\d+</span>', "id=`"puerto-display`">$puerto_nuevo</span>" | Set-Content $rutaHtml -Encoding UTF8
        }
        Log-Ok "¡ÉXITO! El servicio $($motor.ToUpper()) fue migrado en caliente al puerto $puerto_nuevo."
    }
    else {
        Log-Error "Fallo crítico al reconfigurar el puerto."
    }
    Pausa
}

function Reset-TotalServicioHTTP {
    Clear-Host
    Write-Host "--- DESTRUCCIÓN DEL ENTORNO WEB ---" -ForegroundColor Red

    if (Confirmar-Accion "¿Desea PURGAR todos los motores web y sus configuraciones?") {
        Write-Host "[*] Desinstalando procesos y liberando puertos..." -ForegroundColor Cyan

        Stop-Service W3SVC  -Force -ErrorAction SilentlyContinue
        Stop-Service apache -Force -ErrorAction SilentlyContinue
        Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force

        Write-Host "[*] Desinstalando roles de Windows y paquetes de Chocolatey..." -ForegroundColor Cyan
        Remove-WindowsFeature Web-Server, Web-Mgmt-Tools -ErrorAction SilentlyContinue | Out-Null

        if (Get-Command choco -ErrorAction SilentlyContinue) {
            choco uninstall apache-httpd nginx -y -v --force | Out-Null
        }

        Write-Host "[*] Destruyendo directorios web y purgando reglas de Firewall..." -ForegroundColor Cyan
        Remove-Item -Path "C:\inetpub"        -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\tools\apache24" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "C:\tools\nginx"    -Recurse -Force -ErrorAction SilentlyContinue

        Get-NetFirewallRule -DisplayName "HTTP-iis-*"    -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Get-NetFirewallRule -DisplayName "HTTP-apache-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        Get-NetFirewallRule -DisplayName "HTTP-nginx-*"  -ErrorAction SilentlyContinue | Remove-NetFirewallRule

        Log-Ok "Entorno web aniquilado. El servidor regresó a estado base inmaculado."
    }
    Pausa
}

function Menu-HTTP {
    $opciones_http = @(
        "Desplegar Nuevo Servidor HTTP (IIS / Apache / Nginx)",
        "Modificar Puerto en Caliente",
        "Prueba de Cabeceras HTTP (Auditoría)",
        "Reset Total del Entorno HTTP"
    )

    while ($true) {
        $opcion_seleccionada = Generar-Menu "MÓDULO DE GESTIÓN HTTP (WINDOWS)" $opciones_http "Volver al Menú Principal"

        switch ($opcion_seleccionada) {
            0 { Desplegar-ServidorHTTP }
            1 { Modificar-PuertoCaliente }
            2 { Prueba-CabeceraHTTP }
            3 { Reset-TotalServicioHTTP }
            4 { Clear-Host; return }
        }
    }
}