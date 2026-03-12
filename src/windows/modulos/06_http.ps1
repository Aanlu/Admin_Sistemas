# 06_http.ps1
# Libs y http_funciones.ps1 cargados por menu_principal.ps1
# Requiere globals: $global:REPO_ROOT  $global:LOG_FILE  $global:TEMPLATE_WIN

# =============================================================================
# DESPLEGAR SERVIDOR HTTP
# Fases: Motor -> Version -> Puerto -> Instalar -> Puerto -> Hardening -> HTML
# Novedad: detecta instalacion previa del motor para ofrecer reutilizar puerto.
# =============================================================================
function Desplegar-ServidorHTTP {
    Clear-Host
    $motores = @("iis", "apache", "nginx")

    $selMotor = Generar-Menu "SELECCIONE EL MOTOR HTTP A DESPLEGAR" $motores "Volver al menu HTTP"
    if ($selMotor -eq $motores.Count) { return }
    $motor = $motores[$selMotor]

    # ── FASE 1: Versiones ─────────────────────────────────────────────────────
    Write-Host "`n[*] Interrogando repositorios y analizando sistema..." -ForegroundColor Cyan
    $versiones = @(Extraer-VersionesDinamicas -Motor $motor)

    if ($versiones.Count -eq 0) {
        Log-Error "Sin conexion a internet o repositorio no disponible."
        Pausa; return
    }

    $selVer = Generar-Menu "SELECCIONE LA VERSION DE $($motor.ToUpper())" $versiones "Cancelar"
    if ($selVer -eq $versiones.Count) { return }
    $version = ($versiones[$selVer] -split " ")[0]

    # ── FASE 2: Puerto ────────────────────────────────────────────────────────
    # Detectar si ya hay una instalacion previa del mismo motor corriendo.
    # Si existe, ofrecer reutilizar su puerto actual para evitar que quede
    # un proceso ocupando un puerto huerfano tras la reinstalacion.
    Clear-Host
    Write-Host "--- FASE 2: CONFIGURACION DE RED ---`n" -ForegroundColor Yellow

    $puertoAnterior = Detectar-PuertoActual -Motor $motor
    $puerto         = 0

    if ($puertoAnterior -gt 0) {
        Write-Host "  [!] Se detecto una instalacion previa de $($motor.ToUpper()) en el puerto $puertoAnterior." `
                   -ForegroundColor Yellow

        $optsPort = @(
            "Conservar el puerto actual  [$puertoAnterior]",
            "Elegir un puerto diferente"
        )
        $selPort = Generar-Menu "GESTION DE PUERTO EXISTENTE" $optsPort "Cancelar despliegue"
        if ($selPort -eq $optsPort.Count) { return }

        if ($selPort -eq 0) {
            # Reutilizar: el nuevo servidor tomara el mismo puerto que el anterior.
            # Liberar-PuertoAnterior se encarga de matar el proceso que lo ocupa
            # para que la nueva instancia pueda bindearlo sin conflicto.
            $puerto = $puertoAnterior
            Write-Host "  [*] Puerto $puerto conservado. Se liberara antes de la instalacion." `
                       -ForegroundColor Cyan
        }
        # Si eligio "Diferente", $puerto sigue en 0 y cae al bucle de abajo.
    }

    # Captura interactiva solo cuando no se reutilizo el puerto anterior
    if ($puerto -eq 0) {
        do {
            $puerto    = Capturar-Entero "Ingrese el puerto TCP de escucha deseado"
            $estPuerto = Validar-PuertoTCP -Puerto $puerto -Motor $motor
            Write-Host "  [*] Auditando disponibilidad del puerto $puerto..." -ForegroundColor Cyan

            if     ($estPuerto -eq 2) { Log-Error "Puerto reservado para infraestructura critica (RDP, SMB, etc)." }
            elseif ($estPuerto -eq 1) { Log-Error "El puerto $puerto ya esta en uso. Elija otro o use la funcion 'Resetear'." }
            else                      { Log-Ok    "Puerto $puerto libre y validado." }
        } while ($estPuerto -ne 0)
    }

    # ── FASE 3: Liberacion del puerto anterior ────────────────────────────────
    # OBLIGATORIO: si habia un motor previo (mismo u otro) ocupando ese puerto,
    # hay que liberarlo antes de instalar para no recibir
    # "bind: solo se permite un uso de cada direccion" al arrancar el nuevo.
    Write-Host "`n--- FASE 3: LIBERACION DE PUERTO ANTERIOR ---" -ForegroundColor Yellow
    Liberar-PuertoAnterior -Motor $motor -Puerto $puerto
    Log-Ok "Puerto $puerto liberado y listo para el nuevo servidor."

    # ── FASE 4: Instalacion ───────────────────────────────────────────────────
    Write-Host "`n--- FASE 4: APROVISIONAMIENTO ---" -ForegroundColor Yellow

    if (-not (Instalar-PaquetesWeb -Motor $motor -Version $version -Puerto $puerto)) {
        Log-Error "Fallo critico en la instalacion. Ver log en: $($global:LOG_FILE)"
        Pausa; return
    }
    Log-Ok "Binarios de $motor $version instalados correctamente."

    # ── FASE 5: Inyeccion de puerto ───────────────────────────────────────────
    Write-Host "`n--- FASE 5: INYECCION DE PUERTO ---" -ForegroundColor Yellow

    if (-not (Configurar-PuertoServicio -Motor $motor -Puerto $puerto)) {
        Log-Error "Fallo al configurar el puerto $puerto."
        Pausa; return
    }
    Log-Ok "$motor escuchando en puerto $puerto."

    # ── FASE 6: Hardening ─────────────────────────────────────────────────────
    Write-Host "`n--- FASE 6: HARDENING DE SEGURIDAD ---" -ForegroundColor Yellow
    Aplicar-HardeningSeguridad -Motor $motor
    Aislar-DirectorioWeb -Motor $motor
    Log-Ok "Firmas ocultas, security headers y permisos NTFS aplicados."

    # ── FASE 7: Plantilla HTML ────────────────────────────────────────────────
    Write-Host "`n--- FASE 7: PLANTILLA WEB ---" -ForegroundColor Yellow
    Desplegar-PlantillaHTML -Motor $motor -Version $version -Puerto $puerto
    Log-Ok "index.html generado. Acceso: http://localhost:$puerto"

    Pausa
}

# =============================================================================
# MODIFICAR PUERTO EN CALIENTE
# Cambia el puerto de escucha de un servidor ya instalado SIN reinstalarlo.
# Flujo: detectar motores instalados -> validar nuevo puerto -> reconfigurar ->
#        actualizar el span id="puerto-display" en el index.html existente.
# =============================================================================
function Modificar-PuertoCaliente {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host "         MODIFICACION DE PUERTO EN CALIENTE      " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Yellow

    # Mostrar solo los motores que esten efectivamente instalados
    $instalados = @(Obtener-MotoresInstalados)
    if ($instalados.Count -eq 0) {
        Log-Error "No se detecto ningun servidor HTTP instalado en este sistema."
        Pausa; return
    }

    $selMotor = Generar-Menu "SELECCIONE EL MOTOR A MODIFICAR" $instalados "Cancelar"
    if ($selMotor -eq $instalados.Count) { return }
    $motor = $instalados[$selMotor]

    $puertoActual = Detectar-PuertoActual -Motor $motor
    Write-Host "`n  [*] Puerto actual de $($motor.ToUpper()): " -NoNewline
    if ($puertoActual -gt 0) {
        Write-Host "$puertoActual" -ForegroundColor Cyan
    } else {
        Write-Host "No detectado (el servidor puede estar detenido)" -ForegroundColor Yellow
    }

    # Capturar y validar el nuevo puerto
    $puertNuevo = 0
    $est        = -1
    do {
        $puertNuevo = Capturar-Entero "Ingrese el NUEVO puerto TCP"

        if ($puertNuevo -eq $puertoActual) {
            Log-Warning "Es el mismo puerto actual. Elija uno diferente."
            $puertNuevo = 0
            continue
        }

        $est = Validar-PuertoTCP -Puerto $puertNuevo -Motor $motor
        if     ($est -eq 2) { Log-Error "Puerto reservado para infraestructura critica." }
        elseif ($est -eq 1) { Log-Error "Puerto $puertNuevo en uso por otro proceso." }
        else                 { Log-Ok   "Puerto $puertNuevo libre y validado." }
    } while ($est -ne 0 -or $puertNuevo -eq 0)

    Write-Host "`n  [*] Aplicando cambio de puerto: $puertoActual -> $puertNuevo..." `
               -ForegroundColor Cyan

    # Reconfigurar el servicio con el nuevo puerto
    if (-not (Configurar-PuertoServicio -Motor $motor -Puerto $puertNuevo)) {
        Log-Error "No se pudo aplicar el nuevo puerto. Ver log: $($global:LOG_FILE)"
        Pausa; return
    }

    # Actualizar el puerto visible en el index.html sin regenerar la pagina entera.
    # Busca el span id="puerto-display" y reemplaza su contenido.
    Actualizar-PuertoEnHTML -Motor $motor -PuertoNuevo $puertNuevo

    # Ajustar regla de firewall: borrar la antigua y crear la nueva
    Remove-NetFirewallRule -DisplayName "HTTP-$motor-$puertoActual" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "HTTP-$motor-$puertNuevo" `
        -Direction Inbound -LocalPort $puertNuevo -Protocol TCP `
        -Action Allow -ErrorAction SilentlyContinue | Out-Null

    Log-Ok "Puerto cambiado exitosamente. Nuevo acceso: http://localhost:$puertNuevo"
    Escribir-Log "INFO" "Puerto en caliente: $motor $puertoActual -> $puertNuevo"
    Pausa
}

# =============================================================================
# AUDITORIA DE SERVIDORES HTTP
# Muestra un panel con todos los servidores HTTP detectados:
#   Motor | Version | Puerto | Estado | URL de prueba
# Incluye opcion para abrir el localhost directamente desde el menu.
# =============================================================================
function Auditoria-ServidoresHTTP {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host "         AUDITORIA DE SERVIDORES HTTP            " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host ""

    # Recopilar estado de cada motor posible
    $registros = @()
    foreach ($m in @("iis", "apache", "nginx")) {
        $info = Obtener-InfoServidor -Motor $m
        if ($info) { $registros += $info }
    }

    if ($registros.Count -eq 0) {
        Write-Host "  No se detecto ningun servidor HTTP instalado en este sistema." `
                   -ForegroundColor DarkYellow
        Write-Host ""
        Pausa; return
    }

    # ── Tabla de estado ───────────────────────────────────────────────────────
    $cMotor   = 10
    $cVersion = 14
    $cPuerto  = 8
    $cEstado  = 12
    $cURL     = 32
    $sep      = "-" * ($cMotor + $cVersion + $cPuerto + $cEstado + $cURL + 8)

    Write-Host ("  {0,-$cMotor} {1,-$cVersion} {2,-$cPuerto} {3,-$cEstado} {4,-$cURL}" -f `
                "MOTOR", "VERSION", "PUERTO", "ESTADO", "URL DE PRUEBA") -ForegroundColor White
    Write-Host "  $sep"

    foreach ($r in $registros) {
        $colorEstado = switch ($r.Estado) {
            "Corriendo"   { "Green"  }
            "Detenido"    { "Red"    }
            default       { "Yellow" }
        }
        Write-Host ("  {0,-$cMotor} {1,-$cVersion} {2,-$cPuerto}" -f `
                    $r.Motor, $r.Version, $r.Puerto) -NoNewline -ForegroundColor Gray
        Write-Host (" {0,-$cEstado}" -f $r.Estado) -NoNewline -ForegroundColor $colorEstado
        Write-Host (" {0,-$cURL}"   -f $r.URL)     -ForegroundColor Cyan
    }

    Write-Host "  $sep"
    Write-Host ""

    # ── Datos de conexion ─────────────────────────────────────────────────────
    Write-Host "  DATOS DE CONEXION:" -ForegroundColor Yellow
    $ipLocal = Obtener-IP-Local
    if ($ipLocal) {
        Write-Host "  IP de la maquina : $ipLocal" -ForegroundColor Gray
    }
    foreach ($r in ($registros | Where-Object { $_.Puerto -gt 0 })) {
        Write-Host "  $($r.Motor.ToUpper().PadRight(7)) -> http://localhost:$($r.Puerto)  |  http://$($ipLocal):$($r.Puerto)" `
                   -ForegroundColor DarkCyan
    }
    Write-Host ""

    # ── Sub-menu de prueba ────────────────────────────────────────────────────
    $corriendo = @($registros | Where-Object { $_.Estado -eq "Corriendo" -and $_.Puerto -gt 0 })

    if ($corriendo.Count -eq 0) {
        Write-Host "  (Ningun servidor activo para probar en este momento)" -ForegroundColor DarkYellow
        Write-Host ""
        Pausa; return
    }

    $optsAbrir = @($corriendo | ForEach-Object {
        "Abrir http://localhost:$($_.Puerto)  [$($_.Motor.ToUpper())]"
    })

    $selAccion = Generar-Menu "ABRIR EN NAVEGADOR" $optsAbrir "Volver"
    if ($selAccion -lt $corriendo.Count) {
        Start-Process "http://localhost:$($corriendo[$selAccion].Puerto)"
    }
}

# =============================================================================
# RESETEAR / DESINSTALAR SERVIDOR HTTP
# Desinstala completamente el motor elegido sin reiniciar la VM:
#   - Detiene el servicio de Windows y mata procesos residuales
#   - Desinstala via Chocolatey (Apache/Nginx) o deshabilita el rol (IIS)
#   - Elimina el directorio de datos (htdocs / html / wwwroot)
#   - Borra residuos en C:\ProgramData\chocolatey\lib\<paquete>
#   - Limpia la clave del servicio en el Registro de Windows
#   - Elimina las reglas de firewall creadas por este modulo
# =============================================================================
function Resetear-ServidorHTTP {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Red
    Write-Host "        RESETEAR / DESINSTALAR SERVIDOR HTTP     " -ForegroundColor Red
    Write-Host "=================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Esta operacion elimina COMPLETAMENTE el servidor seleccionado" `
               -ForegroundColor Yellow
    Write-Host "  del sistema. No se requiere reiniciar la VM." -ForegroundColor Yellow
    Write-Host ""

    $instalados = @(Obtener-MotoresInstalados)
    if ($instalados.Count -eq 0) {
        Log-Error "No se detecto ningun servidor HTTP instalado para resetear."
        Pausa; return
    }

    $selMotor = Generar-Menu "SELECCIONE EL MOTOR A ELIMINAR" $instalados "Cancelar"
    if ($selMotor -eq $instalados.Count) { return }
    $motor = $instalados[$selMotor]

    # Confirmacion explicita antes de una operacion destructiva
    if (-not (Confirmar-Accion "Eliminar completamente $($motor.ToUpper()) del sistema")) { return }

    Write-Host "`n  [*] Iniciando reset completo de $($motor.ToUpper())..." -ForegroundColor Cyan

    # Toda la logica destructiva vive en http_funciones.ps1
    # para mantener este archivo como capa de presentacion pura.
    $ok = Desinstalar-ServidorCompleto -Motor $motor

    if ($ok) {
        Log-Ok "$($motor.ToUpper()) eliminado completamente. Sistema limpio sin reinicio."
        Escribir-Log "INFO" "Reset completo ejecutado: $motor eliminado."
    } else {
        Log-Error "El reset de $($motor.ToUpper()) encontro errores. Ver log: $($global:LOG_FILE)"
        Write-Host "  [!] Algunos componentes pueden requerir atencion manual." `
                   -ForegroundColor Yellow
    }

    Pausa
}

# =============================================================================
# MENU HTTP PRINCIPAL
# Punto de entrada del modulo. Llama a las 4 funciones principales.
# =============================================================================
function Menu-HTTP {
    $opts = @(
        "Desplegar Nuevo Servidor HTTP",
        "Modificar Puerto en Caliente",
        "Auditoria de Servidores HTTP",
        "Resetear / Desinstalar Servidor HTTP"
    )

    while ($true) {
        switch (Generar-Menu "MODULO HTTP (WINDOWS)" $opts "Volver al Menu Principal") {
            0 { Desplegar-ServidorHTTP   }
            1 { Modificar-PuertoCaliente  }
            2 { Auditoria-ServidoresHTTP  }
            3 { Resetear-ServidorHTTP    }
            4 { Clear-Host; return        }
        }
    }
}