#!/bin/bash

source ../libs/utils.sh

clear
echo -e "El nombre del equipo es: \c"
hostname
echo "----------"
echo "Dirección IP actual: "
ip -br addr show | grep -v "127.0.0.1" | awk '{print $3}'
echo "----------"
echo "Espacio en disco:"
df -h /
echo "----------"
pausa