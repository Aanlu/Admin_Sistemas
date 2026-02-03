#!/bin/bash
clear
echo -e "El nombre del equipo es: \c"
hostname
echo "----------"
# Mostrar IP actual sin información extra
echo "Dirección IP actual: "
ip -br addr show | grep -v "127.0.0.1" | awk '{print $3}'
echo "----------"
# Espacio en disco con poco detalle
echo "Espacio en disco:"
df -h /
echo "----------"