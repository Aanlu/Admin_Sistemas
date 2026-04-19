# 06_http.ps1
# Libs y http_funciones.ps1 cargados por menu_principal.ps1
# Requiere globals: $global:REPO_ROOT  $global:LOG_FILE  $global:TEMPLATE_WIN

# =============================================================================
# DESPLEGAR SERVIDOR HTTP
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

    # FIX CRITICO: $version NUNCA se asignaba en el codigo original.
    # Extraer-VersionesDinamicas devuelve "2.4.58 (Latest)" o "10.0 (LTS - Nativo)".
    # Necesitamos solo el numero: "2.4.58"
    $version = ($versiones[0] -split '\s+')[0]

    # ── FASE 1.5: Analisis de Estado (Upgrade/Downgrade) ──────────────────────
    $infoActual = Obtener-InfoServidor -Motor $motor
    $saltarInstalacion = $false

    if ($motor -eq "iis") {
        if ($infoActual -and $infoActual.Estado -ne "No instalado") {
            Write-Host "`n  [INFO] IIS ya esta instalado (Su version es nativa del Kernel de Windows)." -ForegroundColor Yellow
            if (-not (Confirmar-Accion "Desea omitir la instalacion y solo reconfigurar puertos/plantillas?")) { return }
            $saltarInstalacion = $true
        }
    } else {
        $vActStr = if ($infoActual -and $infoActual.Version -match '^[\d\.]+$') { $infoActual.Version } else { $null }

        if ($vActStr) {
            try {
                $vSel = [version]$version
                $vAct = [version]$vActStr

                if ($vAct -eq $vSel) {
                    Write-Host "`n  [INFO] La version $version ya se encuentra instalada." -ForegroundColor Yellow
                    if (-not (Confirmar-Accion "Desea forzar una reinstalacion destructiva?")) {
                        $saltarInstalacion = $true
                    }
                } elseif ($vAct -lt $vSel) {
                    Write-Host "`n  [ACTUALIZACION] Tiene la version $vAct. Se actualizara a la $vSel." -ForegroundColor Cyan
                    if (-not (Confirmar-Accion "Desea proceder con la actualizacion (Upgrade)?")) { return }
                } else {
                    Write-Host "`n  [PELIGRO] Tiene instalada una version SUPERIOR ($vAct)." -ForegroundColor Red
                    Write-Host "  Forzar la version inferior ($vSel) ejecutara una purga total del servidor." -ForegroundColor Yellow
                    if (-not (Confirmar-Accion "Desea forzar la degradacion (Downgrade)?")) { return }
                }
            } catch {
                # Si falla el parseo, ignoramos y seguimos flujo normal
            }
        }
    }

    # ── FASE 2: Puerto ────────────────────────────────────────────────────────
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
            $puerto = $puertoAnterior
            Write-Host "  [*] Puerto $puerto conservado. Se liberara antes de la instalacion." `
                       -ForegroundColor Cyan
        }
    }

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
    Write-Host "`n--- FASE 3: LIBERACION DE PUERTO ANTERIOR ---" -ForegroundColor Yellow
    Liberar-PuertoAnterior -Motor $motor -Puerto $puerto
    Log-Ok "Puerto $puerto liberado y listo para el nuevo servidor."

    # ── FASE 4: Instalacion ───────────────────────────────────────────────────
    Write-Host "`n--- FASE 4: APROVISIONAMIENTO ---" -ForegroundColor Yellow

    if ($saltarInstalacion) {
        Write-Host "  [*] Instalacion de binarios omitida por solicitud del usuario." -ForegroundColor DarkGray
    } else {
        if (-not (Instalar-PaquetesWeb -Motor $motor -Version $version -Puerto $puerto)) {
            Log-Error "Fallo critico en la instalacion. Ver log en: $($global:LOG_FILE)"
            Pausa; return
        }
        Log-Ok "Binarios de $motor $version instalados correctamente."
    }

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
# =============================================================================
function Modificar-PuertoCaliente {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host "         MODIFICACION DE PUERTO EN CALIENTE      " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Yellow

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

    if (-not (Configurar-PuertoServicio -Motor $motor -Puerto $puertNuevo)) {
        Log-Error "No se pudo aplicar el nuevo puerto. Ver log: $($global:LOG_FILE)"
        Pausa; return
    }

    Actualizar-PuertoEnHTML -Motor $motor -PuertoNuevo $puertNuevo

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
# =============================================================================
function Auditoria-ServidoresHTTP {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host "         AUDITORIA DE SERVIDORES HTTP            " -ForegroundColor Yellow
    Write-Host "=================================================" -ForegroundColor Yellow
    Write-Host ""

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

    $cMotor   = 10; $cVersion = 14; $cPuerto  = 8; $cEstado  = 12; $cURL = 32
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

    if (-not (Confirmar-Accion "Eliminar completamente $($motor.ToUpper()) del sistema")) { return }

    Write-Host "`n  [*] Iniciando reset completo de $($motor.ToUpper())..." -ForegroundColor Cyan

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
