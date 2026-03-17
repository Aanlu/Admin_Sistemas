#!/bin/bash
source libs/utils.sh

clear
echo -e "${CIAN}=================================================${RESET}"
echo -e "${AMARILLO}         DASHBOARD DEL SERVIDOR LINUX            ${RESET}"
echo -e "${CIAN}=================================================${RESET}"

# 1. Información del Sistema Operativo (Más exacto que hostname)
echo -e "${AZUL}[+] Sistema Operativo:${RESET}"
# Extraemos el nombre bonito del OS leyendo el archivo de release
OS_NAME=$(cat /etc/os-release | grep "PRETTY_NAME" | cut -d '"' -f 2)
echo -e "    Hostname: $(uname -n)"
echo -e "    OS: $OS_NAME"
echo -e "    Kernel: $(uname -r)"
echo -e "    Uptime: $(uptime -p | sed 's/up //')"

# 2. Información de Red (Mantenemos tu lógica, pero mejor presentada)
echo -e "\n${AZUL}[+] Interfaces de Red Activas:${RESET}"
# awk '{printf...}' nos ayuda a tabular la IP y la interfaz limpiamente
ip -br addr show | grep -v "127.0.0.1" | awk '{printf "    %-10s %-20s\n", $1, $3}'

# 3. Recursos (RAM) - CRÍTICO para saber si aguantará la Tarea 07
echo -e "\n${AZUL}[+] Memoria RAM:${RESET}"
# Extraemos el total y el usado de free -h
free -h | awk '/^Mem:/ {printf "    Total: %s | Usada: %s | Libre: %s\n", $2, $3, $4}'

# 4. Almacenamiento (Mejor filtrado)
echo -e "\n${AZUL}[+] Almacenamiento Principal (/):${RESET}"
# Solo mostramos la raíz, evitamos mostrar particiones loop o tmpfs basura
df -h / | awk 'NR==2 {printf "    Tamaño: %s | Usado: %s (%s) | Libre: %s\n", $2, $3, $5, $4}'

echo -e "${CIAN}=================================================${RESET}"
pausa