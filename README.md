# ⚙️ Infraestructura como Código (IaC): Orquestación de Servidores Multiplataforma

Este repositorio documenta la arquitectura, el código fuente y las pruebas de concepto desarrolladas para el proyecto integrador de la asignatura **Administración de Sistemas (6to Semestre)**. 

El propósito de esta suite es demostrar la viabilidad de transicionar de una administración de sistemas tradicional (manual y propensa a errores) hacia una metodología de **Automatización e Infraestructura como Código**. El proyecto aborda el despliegue, configuración, *hardening* (aseguramiento) y monitorización de servicios de red en entornos virtualizados heterogéneos (GNU/Linux y Windows Server).

## 🎯 Objetivos de Ingeniería
* **Despliegue Determinista:** Prevención de errores de "Capa 8" mediante menús TUI interactivos, validaciones estrictas con expresiones regulares (Regex) y cálculos automatizados de subredes.
* **Modularidad Estricta:** Separación absoluta entre la capa de presentación (orquestadores) y la capa lógica (librerías y módulos).
* **Seguridad por Diseño (Hardening):** Aplicación estricta del principio de menor privilegio, enjaulamiento de procesos (*Chroot*) y manipulación avanzada de Listas de Control de Acceso (NTFS ACLs).

## 🛠️ Stack Tecnológico y Servicios Orquestados

| Entorno (Guest OS) | Intérprete | Servicios Gestionados | Core Técnico |
| :--- | :--- | :--- | :--- |
| **Linux** (Ubuntu/Debian) | Bash | DHCP, DNS, SSH, FTP, Web | `isc-dhcp-server`, `bind9`, `vsftpd`, `Apache/Nginx` |
| **Windows Server** | PowerShell 5.1+ | DHCP, DNS, SSH, FTP, Web | `DHCP/DNS Roles`, `IIS`, `AppCmd`, `Chocolatey`, `NTFS` |

## 🏗️ Módulos de la Solución

1. **[01] Diagnóstico Base:** Analizador en tiempo real de topología de red, interfaces físicas y almacenamiento.
2. **[02] Core DHCP:** Despliegue de ámbitos de red dinámicos con monitorización en tiempo real de concesiones (*Leases*).
3. **[03] Core DNS:** Aprovisionamiento de zonas maestras. Integra un subsistema de *Bypass* para forzar a las interfaces a usar resolución local (vía `systemd-resolved` o `DnsClientServerAddress`).
4. **[04] Acceso Remoto (SSH):** Aislamiento de redes de administración (*Out-Of-Band*) e instalación de demonios OpenSSH.
5. **[05] Almacenamiento Seguro (FTP):** Implementación de bóvedas compartidas. Utiliza túneles lógicos (`Junctions` y `Bind mounts`), reglas `Deny Delete` contra auto-sabotajes y purga dinámica de memoria caché LSA.
6. **[06] Aprovisionamiento Web (En Desarrollo):** Módulo para el despliegue silencioso de servidores HTTP/HTTPS con inyección de puertos, extracción dinámica de versiones y mitigación de vulnerabilidades vía *Security Headers*.

## 📁 Arquitectura del Repositorio

El código está estructurado para operar exclusivamente en máquinas virtuales, aislando el código fuente de los logs y la documentación:

    ADMIN_SISTEMAS/
    ├── docs/                    # Documentación técnica formal
    ├── logs/                    # Historial de eventos y tracking de errores
    ├── src/                 
    │   ├── linux/               # Entorno Bash
    │   │   ├── libs/            # Utilidades de validación y cálculos IP
    │   │   ├── modulos/         # Scripts independientes por servicio
    │   │   └── menu_principal.sh# Orquestador maestro
    │   └── windows/             # Entorno PowerShell
    │       ├── libs/            # Manipulación NTFS, Firewall y Seguridad
    │       ├── modulos/         # Scripts de inyección a IIS y Roles
    │       └── menu_principal.ps1 # Orquestador maestro
    └── templates/               # Archivos de inyección (ej. zonas BIND9)

## 📖 Despliegue y Operación
Debido a que el código interactúa directamente con el núcleo del OS (servicios, discos y red), se requiere un entorno de laboratorio virtualizado específico. Para instrucciones detalladas, consulte el **[Manual de Usuario Operativo](docs/manual_usuario.md)**.

