function Log-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Log-Ok { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Log-Error { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Log-Warning { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }

function Pausa {
    Write-Host "`nPresione [Enter] para continuar..." -ForegroundColor Cyan
    Read-Host | Out-Null
}

# ============================================================
# FIX: Mapa de traduccion ServerManager -> DISM feature names
# ============================================================
$global:FEATURE_DISM_MAP = @{
    "DHCP"                = @("DHCPServer")
    "DNS"                 = @("DNS-Server-Full-Role")
    "Web-Server"          = @("IIS-WebServerRole", "IIS-WebServer")
    "Web-Ftp-Server"      = @("IIS-FTPServer")
    "Web-Ftp-Ext"         = @("IIS-FTPExtensibility")
    "Web-Mgmt-Console"    = @("IIS-ManagementConsole")
    "Web-Scripting-Tools" = @("IIS-ManagementScriptingTools")
}

# Mapa de feature -> nombre del servicio de Windows (para deteccion de respaldo)
$global:FEATURE_SVC_MAP = @{
    "DHCP"           = "DHCPServer"
    "DNS"            = "DNS"
    "Web-Server"     = "W3SVC"
    "Web-Ftp-Server" = "ftpsvc"
}

# ============================================================
# FIX: Probar-FeatureInstalada
# Wrapper robusto de Get-WindowsFeature que no falla con error 0x80070003.
# Cuando ServerManager/DISM no responde, cae a deteccion por servicio.
# ============================================================
function Probar-FeatureInstalada {
    param([string]$FeatureName)
    try {
        $f = Get-WindowsFeature -Name $FeatureName -ErrorAction Stop
        return $f.Installed
    } catch {
        # DISM / ServerManager no responde (error 0x80070003 comun en algunas configs de WS2022)
        # Fallback: verificar por existencia del servicio de Windows asociado
        if ($global:FEATURE_SVC_MAP.ContainsKey($FeatureName)) {
            $svc = Get-Service -Name $global:FEATURE_SVC_MAP[$FeatureName] -ErrorAction SilentlyContinue
            return ($null -ne $svc)
        }
        return $false
    }
}

function Instalar-DependenciaSilenciosa {
    param([string]$FeatureName)

    # FIX: Usar wrapper robusto en lugar de Get-WindowsFeature directo
    if (Probar-FeatureInstalada $FeatureName) { return $true }

    Write-Host "[AVISO] Instalando dependencia requerida: $FeatureName..." -ForegroundColor Yellow

    try {
        Install-WindowsFeature -Name $FeatureName -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Host "[OK] Dependencia lista: $FeatureName" -ForegroundColor Green
        return $true
    } catch {
        $errMsg = $_.Exception.Message
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # ── FALLBACK 1: ISO de Windows Server montado ──────────────────────
        if ($errMsg -match "archivos de origen" -or $errMsg -match "source files") {
            Log-Warning "Archivos de origen no encontrados localmente."
            Write-Host "[INFO] Buscando el ISO de Windows Server montado..." -ForegroundColor Cyan

            $isoDrive = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
                        Select-Object -First 1 -ExpandProperty DriveLetter
            $sourcePath = "$($isoDrive):\sources\sxs"

            if ($isoDrive -and (Test-Path $sourcePath)) {
                Write-Host "[INFO] ISO detectado en ${isoDrive}:. Instalando desde $sourcePath..." -ForegroundColor Cyan
                try {
                    Install-WindowsFeature -Name $FeatureName -Source $sourcePath `
                        -IncludeManagementTools -ErrorAction Stop | Out-Null
                    Write-Host "[OK] Dependencia lista (desde ISO): $FeatureName" -ForegroundColor Green
                    "[$timestamp] INFO: $FeatureName instalado desde ISO $sourcePath." |
                        Out-File -FilePath $global:LOG_FILE -Append
                    return $true
                } catch {
                    $errMsg = $_.Exception.Message
                }
            } else {
                Write-Host "[!] Monte el ISO de Windows Server en la unidad CD e intente de nuevo." -ForegroundColor Red
            }
        }

        # ── FALLBACK 2: DISM directo ──────────────────────────────────────
        if ($global:FEATURE_DISM_MAP.ContainsKey($FeatureName)) {
            Log-Info "Intentando instalacion alternativa via DISM..."
            foreach ($dismFeature in $global:FEATURE_DISM_MAP[$FeatureName]) {
                $result = & dism /online /enable-feature /featurename:$dismFeature /all /norestart 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[OK] Dependencia instalada via DISM: $dismFeature" -ForegroundColor Green
                    "[$timestamp] INFO: $FeatureName instalado via DISM como $dismFeature." |
                        Out-File -FilePath $global:LOG_FILE -Append
                    return $true
                }
            }
            Log-Warning "DISM tampoco pudo instalar la feature. Ejecute: Dism /Online /Cleanup-Image /RestoreHealth"
        }

        "[$timestamp] CRITICO: Fallo al instalar $FeatureName. $errMsg" |
            Out-File -FilePath $global:LOG_FILE -Append
        Write-Host "[ERROR] Fallo al instalar: $FeatureName" -ForegroundColor Red
        return $false
    }
}

function Generar-Menu {
    param(
        [string]$Titulo,
        [array]$Opciones,
        [string]$TextoSalir = "Salir"
    )

    $itemsPorPagina = 5
    $totalPaginas = [math]::Ceiling($Opciones.Count / $itemsPorPagina)
    $paginaActual = 0
    $seleccionRelativa = 0

    $ancho = 65
    $pad = " " * $ancho

    # FIX: El menú ocupa exactamente 15 líneas
    $lineasMenu = 15 
    $cursorY = [Console]::CursorTop

    # Validar si hay espacio suficiente en la pantalla actual para no causar "Scroll fantasma"
    if (($cursorY + $lineasMenu) -ge [Console]::BufferHeight) {
        Clear-Host
        $cursorY = 0
    } elseif (($cursorY + $lineasMenu) -ge ([Console]::WindowTop + [Console]::WindowHeight)) {
        for($i=0; $i -lt $lineasMenu; $i++) { Write-Host "" }
        $cursorY = [Console]::CursorTop - $lineasMenu
    }

    [Console]::CursorVisible = $false

    try {
        while ($true) {
            $inicio = $paginaActual * $itemsPorPagina
            $fin = [math]::Min($inicio + $itemsPorPagina - 1, $Opciones.Count - 1)
            $opcionesPagina = $Opciones[$inicio..$fin]
            $maxSeleccion = $opcionesPagina.Count 

            [Console]::SetCursorPosition(0, $cursorY)

            # --- Encabezado ---
            Write-Host ("=" * $ancho) -ForegroundColor Cyan
            $titCenter = $Titulo.PadLeft((($ancho + $Titulo.Length) / 2)).PadRight($ancho)
            Write-Host $titCenter -ForegroundColor Yellow -BackgroundColor DarkBlue
            Write-Host ("=" * $ancho) -ForegroundColor Cyan

            # --- Navegacion ---
            if ($totalPaginas -gt 1) {
                $pagTxt = "[ Pagina $($paginaActual + 1) de $totalPaginas | Flechas < > para cambiar ]"
                Write-Host $pagTxt.PadLeft((($ancho + $pagTxt.Length) / 2)).PadRight($ancho) -ForegroundColor DarkCyan
            } else {
                Write-Host $pad
            }
            Write-Host $pad

            # --- Opciones ---
            for ($i = 0; $i -lt 5; $i++) {
                if ($i -lt $opcionesPagina.Count) {
                    $numStr = "[$($i + 1)]"
                    $texto = $opcionesPagina[$i]
                    $linea = "  $numStr $texto "

                    if ($i -eq $seleccionRelativa) {
                        Write-Host $linea.PadRight($ancho) -ForegroundColor Black -BackgroundColor Cyan
                    } else {
                        Write-Host $linea.PadRight($ancho) -ForegroundColor Gray
                    }
                } else {
                    Write-Host $pad 
                }
            }

            # --- Salir ---
            Write-Host $pad
            $lineaSalir = "  [6] $TextoSalir "
            if ($seleccionRelativa -eq $maxSeleccion) {
                Write-Host $lineaSalir.PadRight($ancho) -ForegroundColor White -BackgroundColor Red
            } else {
                Write-Host $lineaSalir.PadRight($ancho) -ForegroundColor Red
            }

            # --- Footer ---
            Write-Host $pad
            $inst = "   ^/v Mover  |  < > Pagina  |  1-6 Numeros  |  Enter "
            Write-Host $inst.PadRight($ancho) -ForegroundColor DarkGray
            
            # FIX PRINCIPAL: Evita el salto de linea final que rompia la coordenada Y
            Write-Host $pad -NoNewline

            # --- Teclado ---
            $tecla = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

         #   enum Tecla {
          #      ENTER = 13,
          #      UP = 38,
          #      DOWN = 40,
          #      LEFT = 37,
          #      RIGHT = 39
          #  } 

            switch ($tecla.VirtualKeyCode) {
                38 { $seleccionRelativa--; if ($seleccionRelativa -lt 0) { $seleccionRelativa = $maxSeleccion } }
                40 { $seleccionRelativa++; if ($seleccionRelativa -gt $maxSeleccion) { $seleccionRelativa = 0 } }
                37 { if ($totalPaginas -gt 1) { $paginaActual--; if ($paginaActual -lt 0) { $paginaActual = $totalPaginas - 1 }; $seleccionRelativa = 0 } }
                39 { if ($totalPaginas -gt 1) { $paginaActual++; if ($paginaActual -ge $totalPaginas) { $paginaActual = 0 }; $seleccionRelativa = 0 } }
                13 { 
                    if ($seleccionRelativa -eq $maxSeleccion) { return $Opciones.Count } 
                    else { return ($inicio + $seleccionRelativa) } 
                }
            }

            if ($tecla.Character -match "[1-5]") {
                $idxTarget = [int][string]$tecla.Character - 1
                if ($idxTarget -lt $opcionesPagina.Count) { return ($inicio + $idxTarget) }
            }

            if ($tecla.Character -match "j") {

            }

            if ($tecla.Character -eq '6') { return $Opciones.Count }
        }
    } finally {
        [Console]::CursorVisible = $true
        # Damos un salto y limpiamos la pantalla limpia para el submodulo que elijas
       # Write-Host "`n"
       # Clear-Host 
    }
}

function Confirmar-Accion {
    param([string]$mensaje)
    $opciones = @("Si, proceder con la accion")
    $eleccion = Generar-Menu "CONFIRMACION: $mensaje" $opciones "No, cancelar y volver"
    if ($eleccion -eq 0) { return $true } else { return $false }
}

# FIX: excluir 10.0.2.x (NAT VirtualBox) y priorizar la IP bridge real
function Obtener-IP-Local {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object {
              $_.IPAddress -notmatch "^127\." -and
              $_.IPAddress -notmatch "^169\.254\." -and
              $_.IPAddress -notmatch "^10\.0\.2\."
          } |
          Select-Object -First 1 -ExpandProperty IPAddress
    return $ip
}

function Seleccionar-Interfaz {
    $interfaces = Get-NetAdapter | Where-Object {
        $_.Virtual -eq $false -and
        $_.InterfaceDescription -notlike "*Loopback*" -and
        $_.Status -eq "Up"
    }

    if ($interfaces.Count -eq 0) {
        Log-Error "No hay interfaces fisicas activas."
        return $null
    }

    Write-Host "`n--- SELECCION DE INTERFAZ ---" -ForegroundColor Cyan
    for ($i = 0; $i -lt $interfaces.Count; $i++) {
        Write-Host "[$i] $($interfaces[$i].Name) | $($interfaces[$i].InterfaceDescription)"
    }

    while ($true) {
        $sel = Read-Host "Seleccione interfaz"
        if ($sel -match "^\d+$" -and [int]$sel -lt $interfaces.Count) {
            return $interfaces[[int]$sel]
        }
        Log-Error "Seleccion invalida."
    }
}

function Capturar-IP {
    param([string]$Mensaje)

    $ip_local = Obtener-IP-Local

    while ($true) {
        Write-Host "$Mensaje [Enter para usar: $ip_local]: " -NoNewline
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

function Capturar-IP-Opcional {
    param([string]$Mensaje)

    while ($true) {
        Write-Host "$Mensaje [Enter para omitir]: " -NoNewline
        $input_ip = Read-Host

        if ([string]::IsNullOrWhiteSpace($input_ip)) { return "" }
        if (Validar-Formato-IP $input_ip) { return $input_ip }
        Log-Error "IP invalida. Intente de nuevo o presione Enter para omitir."
    }
}

Function Descargar-ArchivoLigero {
    param([string]$Url, [string]$Destino)
    
    $ProgressPreference = 'SilentlyContinue' # Apaga la barra azul pesada
    $peticion = [System.Net.WebRequest]::Create($Url)
    $respuesta = $peticion.GetResponse()
    $tamanoTotal = $respuesta.ContentLength
    $stream = $respuesta.GetResponseStream()
    $archivo = New-Object System.IO.FileStream($Destino, [System.IO.FileMode]::Create)
    $buffer = New-Object byte[] 8192
    $leido = 0

    while (($cantidad = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $archivo.Write($buffer, 0, $cantidad)
        $leido += $cantidad
        $porcentaje = [math]::Round(($leido / $tamanoTotal) * 100, 0)
        Write-Host "`r  [>] Descargando: $porcentaje% " -NoNewline -ForegroundColor Cyan
    }
    
    $archivo.Close(); $stream.Close(); $respuesta.Close()
    Write-Host "`r  [OK] Descarga completada: 100%      " -ForegroundColor Green
}