# 📘 Manual de Usuario Operativo - Suite de Administración

## 1. Propósito del Documento
Este manual define los procedimientos operativos estándar para el despliegue, auditoría y recuperación de los servicios orquestados por los scripts de esta suite. Está dirigido a administradores, profesores y evaluadores que deseen replicar el proyecto en un entorno seguro.

## 2. Arquitectura de Laboratorio (Máquinas Virtuales)
Para garantizar la integridad del equipo físico (Host) y permitir el correcto flujo de los protocolos (especialmente DHCP), es **obligatorio** ejecutar esta suite dentro de un Hypervisor (VirtualBox, VMware, Hyper-V) utilizando la siguiente topología de red para las máquinas "Guest":

* **Adaptador 1 (NAT / Bridge):** Necesario para la fase de aprovisionamiento. Permite a los scripts consultar repositorios (`apt-cache`, `Windows Update`, `Chocolatey`) y descargar dependencias silenciosamente.
* **Adaptador 2 (Red Interna / Host-Only):** Este es el entorno de trabajo real. Aisla los broadcast de DHCP y las peticiones DNS del router de su casa/universidad, evitando colisiones en la red física.
* **Sistemas Operativos (Guest):** Se recomiendan instalaciones limpias de **Ubuntu Server 22.04+** o **Windows Server 2019/2022**.

## 3. Políticas y Requisitos Previos
1. **Privilegios de Ejecución:** Los orquestadores validan activamente la sesión. Si no se cuenta con privilegios `root` (Linux) o de `Administrador` (Windows), el script denegará la ejecución para prevenir corrupciones a medio proceso.
2. **Nomenclatura Segura:** Como medida de mitigación contra inyecciones en el sistema de archivos (Path Traversal / Command Injection), **está estrictamente prohibido el uso de espacios en blanco** en nombres de usuarios, grupos o ámbitos. El motor Regex solo admite alfanuméricos y guiones.

---

## 4. Ejecución en GNU/Linux (Bash)

### Inicialización
Abra la terminal de su servidor Linux, diríjase a la raíz del proyecto y otorgue los permisos de ejecución recursivos antes del primer uso:

    cd ADMIN_SISTEMAS/src/linux
    chmod +x -R .
    sudo bash menu_principal.sh

### Consideraciones Operativas
* **Módulo DNS:** Antes de crear una zona, el sistema le pedirá asegurar una IP estática en la Red Interna. El script verifica la integridad del archivo BIND9 con `named-checkconf` antes de aplicarlo.
* **Módulo FTP:** Utiliza `mount --bind` en lugar de *symlinks* para construir las jaulas. Si el cliente FTP intenta escapar al directorio raíz `/`, el demonio abortará la solicitud.
* **Módulo Web (Próximo):** Extraerá las versiones de Apache/Nginx dinámicamente usando utilidades como `apt-cache madison`, inyectando puertos personalizados mediante el procesador de flujo `sed`.

---

## 5. Ejecución en Windows Server (PowerShell)

### Desbloqueo de Políticas (Execution Policy)
Windows Server bloquea scripts de terceros por seguridad. Abra una consola de **PowerShell como Administrador** e ingrese el siguiente comando para permitir la ejecución en la sesión actual:

    Set-ExecutionPolicy Bypass -Scope Process -Force

Posteriormente, lance el orquestador:

    cd ADMIN_SISTEMAS\src\windows
    .\menu_principal.ps1

### Consideraciones Operativas
* **Aprovisionamiento Offline:** Si el Adaptador NAT falla y no hay internet, el script de instalación intentará buscar la unidad de CD/DVD, solicitando que el usuario "Monte" la ISO de Windows Server para extraer los binarios nativos (`\sources\sxs`).
* **Arquitectura FTP (IIS):** El script crea un grupo de seguridad de Windows llamado `FTP_Auth_Users`. Para evitar el auto-sabotaje desde el cliente FTP (FileZilla), inyecta una regla de denegación explícita (`Deny Delete`) en la raíz del usuario, superponiéndose a los permisos heredados.

---

## 6. Procedimiento de "Destrucción Total" (Reset de Entorno)

Al ser una herramienta académica, el entorno debe ser fácilmente restaurable para múltiples pruebas. Todos los módulos críticos incluyen una opción llamada **"Destruir Entorno (Reset Total)"**. 

Esta rutina ejecuta una limpieza profunda a nivel Kernel y Registro:
1. Elimina usuarios físicos y desvincula grupos locales.
2. Desmonta túneles lógicos. En Linux usa `umount -l` (Lazy unmount) para forzar la desconexión sin colgar el kernel si un cliente está activo. En Windows usa el motor nativo `cmd.exe /c rmdir` para evitar la aniquilación recursiva accidental de PowerShell sobre uniones NTFS.
3. Purga las bóvedas centrales y limpia la persistencia (`/etc/fstab` o las entradas en IIS).

---

## 7. Solución de Problemas (Troubleshooting)

| Fallo Identificado | Causa Común (Entorno Virtual) | Solución |
| :--- | :--- | :--- |
| **Linux:** Fallo silencioso en dependencias o error de `dpkg`. | El archivo `.lock` de APT está siendo utilizado por actualizaciones automáticas del sistema operativo (unattended-upgrades). | Revise `logs/linux_services.log`. Espere 5 minutos a que el OS libere el candado o mate el proceso. |
| **Windows:** El usuario FTP da error `550` al cambiarlo de grupo. | El servicio IIS mantiene el *Token LSA* del grupo anterior en la memoria caché RAM. | El script ejecuta un *Restart-Service* para mitigarlo, pero si la conexión persiste, utilice la opción "Alternar Estado" para matar los sockets TCP vivos. |
| **Windows:** Fallo de acceso denegado al borrar/destruir el entorno. | El Explorador de Archivos o el "Server Manager" tienen bloqueada la carpeta en el Host. | Cierre todas las ventanas gráficas antes de invocar la Destrucción Total. |