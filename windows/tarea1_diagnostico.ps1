Clear-Host
Write-Output "Nombre del equipo:"
hostname
Write-Output "----------"

#Mostrar ip actual sin información extra
Write-Output "IP Actual:"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notlike "*Loopback*"} | Select-Object -ExpandProperty IPAddress
Write-Output "----------"

# Espacio en MB
$disco = Get-Volume -DriveLetter C
$libre = [math]::Round($disco.SizeRemaining / 1MB, 0)
$total = [math]::Round($disco.Size / 1MB, 0)

Write-Output "Espacio en Disco C:"
Write-Output "Libre: $libre MB"
Write-Output "Total: $total MB"
Write-Output "----------"