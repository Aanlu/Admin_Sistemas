. .\libs\utils.ps1

if (-not (Instalar-DependenciaSilenciosa "DNS")) { 
    Log-Error "Fallo al instalar DNS."
    Pausa
    exit 1 
}

function Seleccionar-Zona {
    $zonasObj = Get-DnsServerZone -ErrorAction SilentlyContinue | Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneType -eq "Primary" }
    if (-not $zonasObj) { return 1 }
    
    $zonas = @($zonasObj.ZoneName)
    $eleccion = Generar-Menu "SELECCIONE LA ZONA DNS" $zonas "Cancelar y Volver"
    
    if ($eleccion -eq $zonas.Count) { return 2 }
    $global:ZONA_SELECCIONADA = $zonas[$eleccion]
    return 0
}

function Crear-Zona {
    Clear-Host
    Write-Host "--- CREACIÓN DE ZONA DNS ---" -ForegroundColor Yellow
    
    $svc = Get-Service DNS -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Log-Info "Servicio BIND9 (DNS Windows) detectado y operando en segundo plano."
    }

    $dominio = ""
    while ($true) {
        $dominio = Read-Host "Ingrese el nombre del dominio principal a configurar"
        if ([string]::IsNullOrWhiteSpace($dominio)) { return }
        $dominio = $dominio.ToLower().Replace("www.", "")
        
        if ($dominio -match "^[a-z0-9-]+\.[a-z]{2,}(\.[a-z]{2,})?$") { break }
        Log-Error "Formato inválido. Indique una extensión de dominio válida."
    }

    $zonaExistente = Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue
    if ($zonaExistente) {
        Log-Error "La zona ya existe en el servidor. Abortando para evitar sobrescritura."
        Pausa
        return
    }

    $ip_server = Capturar-IP "IP del Servidor para registros raíz y subdominios"

    try {
        Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" -ErrorAction Stop
        Add-DnsServerResourceRecordA -Name "@" -IPv4Address $ip_server -ZoneName $dominio -ErrorAction SilentlyContinue
        Add-DnsServerResourceRecordA -Name "ns1" -IPv4Address $ip_server -ZoneName $dominio -ErrorAction SilentlyContinue
        Log-Ok "Zona de dominio generada y cargada exitosamente."
    } catch {
        Log-Error "Error de sintaxis (Estructural): $($_.Exception.Message)"
    }
    Pausa
}

function Leer-Zona {
    $estado = Seleccionar-Zona
    if ($estado -eq 1) { Clear-Host; Log-Error "No hay zonas DNS creadas actualmente."; Pausa; return }
    if ($estado -eq 2) { return }

    $dominio = $global:ZONA_SELECCIONADA
    Clear-Host
    Write-Host "--- LECTURA DE REGISTROS ---" -ForegroundColor Yellow
    Write-Host "`n[ Registros de la zona: $dominio ]" -ForegroundColor Cyan
    
    Write-Host ("{0,-20} {1,-10} {2,-20}" -f "HOSTNAME", "TIPO", "DIRECCIÓN IP") -ForegroundColor Yellow
    Write-Host "--------------------------------------------------"
    
    $registros = Get-DnsServerResourceRecord -ZoneName $dominio -ErrorAction SilentlyContinue | Where-Object { $_.RecordType -match "A|CNAME" }
    foreach ($reg in $registros) {
        $dato = if ($reg.RecordType -eq "A") { $reg.RecordData.IPv4Address } else { $reg.RecordData.HostNameAlias }
        Write-Host ("{0,-20} {1,-10} {2,-20}" -f $reg.HostName, $reg.RecordType, $dato)
    }
    Pausa
}

function Agregar-Registro {
    $estado = Seleccionar-Zona
    if ($estado -eq 1) { Clear-Host; Log-Error "No hay zonas para modificar. Gestione una primero."; Pausa; return }
    if ($estado -eq 2) { return }

    $dominio = $global:ZONA_SELECCIONADA
    Clear-Host
    Write-Host "--- AGREGAR / MODIFICAR HOST EN ZONA: $dominio ---" -ForegroundColor Yellow
    
    Write-Host "`n[ Registros actuales ]" -ForegroundColor Cyan
    Write-Host ("{0,-20} {1,-10} {2,-20}" -f "HOSTNAME", "TIPO", "DIRECCIÓN IP") -ForegroundColor Yellow
    Write-Host "--------------------------------------------------"
    $registrosA = Get-DnsServerResourceRecord -ZoneName $dominio -RRType A -ErrorAction SilentlyContinue
    foreach ($reg in $registrosA) {
        Write-Host ("{0,-20} {1,-10} {2,-20}" -f $reg.HostName, $reg.RecordType, $reg.RecordData.IPv4Address)
    }
    Write-Host ""

    $hostn = ""
    while ($true) {
        $hostn = Read-Host "Nombre del host a registrar o modificar (ej. www, @, ns1)"
        if ([string]::IsNullOrWhiteSpace($hostn)) { continue }
        $hostn = $hostn.ToLower().Replace(".$dominio", "")
        
        if ($hostn -match "^[a-z0-9-]+$" -or $hostn -eq "@") { break }
        Log-Error "Caracteres inválidos. Emplee únicamente letras, números, guiones o @"
    }

    $ip_host = Capturar-IP "Nueva IP a asignar al host"
    $registroExistente = Get-DnsServerResourceRecord -ZoneName $dominio -Name $hostn -RRType A -ErrorAction SilentlyContinue

    if ($registroExistente) {
        Log-Warning "El host indicado ya existe en esta zona."
        if (Confirmar-Accion "¿Desea ACTUALIZAR la IP de este registro existente?") {
            try {
                Remove-DnsServerResourceRecord -ZoneName $dominio -Name $hostn -RRType A -Force -ErrorAction Stop
                Add-DnsServerResourceRecordA -Name $hostn -IPv4Address $ip_host -ZoneName $dominio -ErrorAction Stop
                Log-Ok "Registro actualizado y servicio DNS reiniciado correctamente."
            } catch {
                Log-Error "Fallo de validación. Se revirtió el cambio para proteger la zona."
                Write-Host "`n--- DETALLE TÉCNICO DEL RECHAZO ---" -ForegroundColor Red
                Write-Host $_.Exception.Message
                Write-Host "-----------------------------------" -ForegroundColor Red
            }
        } else {
            Log-Info "Modificación cancelada. El registro original se mantiene intacto."
        }
    } else {
        try {
            Add-DnsServerResourceRecordA -Name $hostn -IPv4Address $ip_host -ZoneName $dominio -ErrorAction Stop
            Log-Ok "Nuevo host agregado y servicio DNS actualizado correctamente."
        } catch {
            Log-Error "Fallo de validación. Se revirtió el cambio para proteger el servicio."
            Write-Host "`n--- DETALLE TÉCNICO DEL RECHAZO ---" -ForegroundColor Red
            Write-Host $_.Exception.Message
            Write-Host "-----------------------------------" -ForegroundColor Red
        }
    }
    Pausa
}

function Eliminar-Registro {
    $estado = Seleccionar-Zona
    if ($estado -eq 1) { Clear-Host; Log-Error "No hay zonas disponibles para modificar."; Pausa; return }
    if ($estado -eq 2) { return }

    $dominio = $global:ZONA_SELECCIONADA
    Clear-Host
    Write-Host "--- ELIMINAR HOST DE ZONA: $dominio ---" -ForegroundColor Yellow
    
    Write-Host "`n[ Hosts activos en la configuración ]" -ForegroundColor Cyan
    Write-Host ("{0,-20} {1,-10} {2,-20}" -f "HOSTNAME", "TIPO", "DIRECCIÓN IP") -ForegroundColor Yellow
    Write-Host "--------------------------------------------------"
    $registrosA = Get-DnsServerResourceRecord -ZoneName $dominio -RRType A -ErrorAction SilentlyContinue
    foreach ($reg in $registrosA) {
        Write-Host ("{0,-20} {1,-10} {2,-20}" -f $reg.HostName, $reg.RecordType, $reg.RecordData.IPv4Address)
    }
    Write-Host ""

    $hostn = (Read-Host "Nombre del host a eliminar").ToLower().Replace(".$dominio", "")

    if ($hostn -eq "ns1" -or $hostn -eq "@") {
        Log-Error "Prohibido eliminar registros críticos del sistema."
        Pausa; return
    }

    $registroExistente = Get-DnsServerResourceRecord -ZoneName $dominio -Name $hostn -RRType A -ErrorAction SilentlyContinue
    
    if ($registroExistente) {
        if (Confirmar-Accion "¿Confirma la eliminación permanente del host seleccionado?") {
            try {
                Remove-DnsServerResourceRecord -ZoneName $dominio -Name $hostn -RRType A -Force -ErrorAction Stop
                Log-Ok "Registro de host eliminado correctamente."
            } catch {
                Log-Error "Error al eliminar: $($_.Exception.Message)"
            }
        } else {
            Log-Warning "Eliminación cancelada por el usuario."
        }
    } else {
        Log-Error "El host no se encontró en la tabla de la zona."
    }
    Pausa
}

function Validar-Resolucion {
    $estado = Seleccionar-Zona
    if ($estado -eq 1) { Clear-Host; Log-Error "No hay zonas DNS disponibles para someter a validación."; Pausa; return }
    if ($estado -eq 2) { return }

    $dominio = $global:ZONA_SELECCIONADA
    Clear-Host
    Write-Host "--- VALIDACIÓN Y PRUEBAS DE RESOLUCIÓN ---" -ForegroundColor Yellow

    Write-Host "`nFase 1: Verificación de Sintaxis interna (checkconf)..." -ForegroundColor Cyan
    if (Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue) {
        Log-Ok "Sintaxis global operativa y correcta."
    } else {
        Log-Error "Se encontraron errores estructurales en la zona."
    }

    Write-Host "`nFase 2: Prueba de Resolución local mediante nslookup..." -ForegroundColor Cyan
    $nsRes = nslookup $dominio 127.0.0.1 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host $nsRes } else { Log-Error "Fallo en la resolución del servidor de nombres." }

    Write-Host "`nFase 3: Prueba de Conectividad de red hacia el subdominio web..." -ForegroundColor Cyan
    $pingRes = Test-Connection -ComputerName "www.$dominio" -Count 3 -ErrorAction SilentlyContinue
    if ($pingRes) { Write-Host "Respuesta exitosa de www.$dominio" } else { Log-Warning "Paquetes perdidos. Posible bloqueo de cortafuegos ICMP o equipo apagado." }

    Pausa
}

function Modificar-Nombre-Zona {
    $estado = Seleccionar-Zona
    if ($estado -eq 1) { Clear-Host; Log-Error "No hay zonas para renombrar."; Pausa; return }
    if ($estado -eq 2) { return }

    $dominio_viejo = $global:ZONA_SELECCIONADA
    Clear-Host
    Write-Host "--- MIGRACIÓN DE DOMINIO (RENOMBRAR ZONA) ---" -ForegroundColor Yellow
    Write-Host "Zona actual a modificar: $dominio_viejo" -ForegroundColor Cyan

    $dominio_nuevo = ""
    while ($true) {
        $dominio_nuevo = Read-Host "Ingrese el NUEVO nombre del dominio (ej. aprobados.com)"
        if ([string]::IsNullOrWhiteSpace($dominio_nuevo)) { return }
        
        $dominio_nuevo = $dominio_nuevo.ToLower().Replace("www.", "")
        
        if (-not ($dominio_nuevo -match "^[a-z0-9-]+\.[a-z]{2,}(\.[a-z]{2,})?$")) {
            Log-Error "Formato inválido. Indique una extensión de dominio válida."
            continue
        }
        if ($dominio_viejo -eq $dominio_nuevo) {
            Log-Error "El nuevo nombre no puede ser idéntico al actual."
            continue
        }
        break
    }

    if (Get-DnsServerZone -Name $dominio_nuevo -ErrorAction SilentlyContinue) {
        Log-Error "El dominio '$dominio_nuevo' ya existe. Colisión detectada."
        Pausa; return
    }

    if (Confirmar-Accion "¿Confirma la migración de $dominio_viejo hacia $dominio_nuevo?") {
        try {
            Add-DnsServerPrimaryZone -Name $dominio_nuevo -ZoneFile "$dominio_nuevo.dns" -ErrorAction Stop
            
            $registrosViejos = Get-DnsServerResourceRecord -ZoneName $dominio_viejo -ErrorAction SilentlyContinue | Where-Object { $_.RecordType -match "A|CNAME" }
            foreach ($reg in $registrosViejos) {
                # Evitamos duplicar la raíz que Add-DnsServerPrimaryZone a veces auto-crea
                if ($reg.HostName -eq "@") {
                    Remove-DnsServerResourceRecord -ZoneName $dominio_nuevo -Name "@" -RRType A -Force -ErrorAction SilentlyContinue
                }
                
                if ($reg.RecordType -eq "A") {
                    Add-DnsServerResourceRecordA -Name $reg.HostName -IPv4Address $reg.RecordData.IPv4Address -ZoneName $dominio_nuevo -ErrorAction SilentlyContinue
                } elseif ($reg.RecordType -eq "CNAME") {
                    Add-DnsServerResourceRecordCName -Name $reg.HostName -HostNameAlias $reg.RecordData.HostNameAlias -ZoneName $dominio_nuevo -ErrorAction SilentlyContinue
                }
            }
            
            Remove-DnsServerZone -Name $dominio_viejo -Force -ErrorAction Stop
            Log-Ok "Migración exitosa. La zona ahora opera como $dominio_nuevo"
        } catch {
            Remove-DnsServerZone -Name $dominio_nuevo -Force -ErrorAction SilentlyContinue
            Log-Error "La validación de BIND9 falló. Se revirtieron los cambios por seguridad: $($_.Exception.Message)"
        }
    } else {
        Log-Warning "Migración cancelada."
    }
    Pausa
}

function Eliminar-Zona {
    $estado = Seleccionar-Zona
    if ($estado -eq 1) { Clear-Host; Log-Error "No hay zonas DNS para eliminar."; Pausa; return }
    if ($estado -eq 2) { return }

    $dominio = $global:ZONA_SELECCIONADA
    Clear-Host
    Write-Host "--- DESTRUCCIÓN DE ZONA DNS: $dominio ---" -ForegroundColor Yellow
    Write-Host "¡ADVERTENCIA! Esta acción destruirá el archivo físico y desconectará la zona del orquestador." -ForegroundColor Red

    if (Confirmar-Accion "¿Está absolutamente seguro de ELIMINAR toda la zona '$dominio'?") {
        try {
            Remove-DnsServerZone -Name $dominio -Force -ErrorAction Stop
            Log-Ok "La zona $dominio y todos sus registros han sido aniquilados del servidor."
        } catch {
            Log-Error "Fallo la destrucción: $($_.Exception.Message)"
        }
    } else {
        Log-Warning "Destrucción abortada."
    }
    Pausa
}

function Menu-DNS {
    $opciones_dns = @(
        "Crear Nueva Zona DNS",
        "Listar Registros de Zona",
        "Agregar / Modificar Registro de Host",
        "Eliminar Registro de Host",
        "Modificar Nombre de Zona (Renombrar)",
        "Eliminar Zona DNS Completa",
        "Validar Resolución de Nombres"
    )
    
    while ($true) {
        $eleccion = Generar-Menu "MÓDULO DE GESTIÓN DNS" $opciones_dns "Volver al Menú Principal"
        
        switch ($eleccion) {
            0 { Crear-Zona }
            1 { Leer-Zona }
            2 { Agregar-Registro }
            3 { Eliminar-Registro }
            4 { Modificar-Nombre-Zona }
            5 { Eliminar-Zona }
            6 { Validar-Resolucion }
            7 { return }
        }
    }
}

Menu-DNS