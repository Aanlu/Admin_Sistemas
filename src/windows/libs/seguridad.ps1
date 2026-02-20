function Permitir-Ping-Global {
    Remove-NetFirewallRule -DisplayName "Regla-Global-ICMPv4" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "Regla-Global-ICMPv4" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow | Out-Null
}

function Abrir-Puertos-Servicio {
    param(
        [string]$NombreServicio,
        [int[]]$Puertos,
        [string]$Protocolo
    )
    
    $nombreRegla = "Permitir-$NombreServicio"
    Remove-NetFirewallRule -DisplayName $nombreRegla -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $nombreRegla -Direction Inbound -LocalPort $Puertos -Protocol $Protocolo -Action Allow | Out-Null
}

function Desactivar-Seguridad-Estricta {
    Set-ExecutionPolicy Bypass -Scope Process -Force
}