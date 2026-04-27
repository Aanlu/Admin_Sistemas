# ==============================================================================
# MODULO 09: Seguridad de Identidad, Delegacion RBAC y MFA
# ==============================================================================
. "$PSScriptRoot\..\libs\seguridad.ps1"
. "$PSScriptRoot\..\libs\fsrm_funciones.ps1"  # <--- ESTA ES LA LÍNEA QUE FALTA

function Menu-GestionUsuariosP09 {
    $opcs = @("Mostrar Token MFA de un usuario", "Restablecer Contrasena de AD", "Crear Usuario Nuevo", "Eliminar Usuario")

    while ($true) {
        $sel = Generar-Menu -Titulo "PANEL DE GESTION DE IDENTIDADES (MFA/AD)" -Opciones $opcs -TextoSalir "Volver al Menu 09"
        Clear-Host

        switch ($sel) {
            0 { 
                $u = Seleccionar-UsuarioAD -Titulo "SELECCIONE USUARIO PARA EXTRAER TOKEN"
                if ($u) { Mostrar-TokenUsuario -Usuario $u }
                Pausa 
            }
            1 {
                $u = Seleccionar-UsuarioAD -Titulo "SELECCIONE USUARIO A RESTABLECER"
                if ($u) {
                    $p = Read-Host "Nueva Contrasena" -AsSecureString
                    try { Set-ADAccountPassword -Identity $u -NewPassword $p -Reset -ErrorAction Stop; Log-Ok "Exito." } catch { Log-Error $_.Exception.Message }
                }
                Pausa
            }
           2 {
                Write-Host "--- NUEVA IDENTIDAD INTEGRAL ---" -ForegroundColor Cyan
                $nombreCompleto = Read-Host "Nombre completo (Ej: Carlos Slim)"
                $samAccount     = Read-Host "Username (Ej: carlos01)"
                
                # Leer contraseña y convertirla a texto plano de forma segura para el CSV
                $p = Read-Host "Contrasena" -AsSecureString
                $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))
                
                $opcTipo = @("Administrador", "Cuate", "No Cuate", "Individual/Externo")
                $tipo = Generar-Menu -Titulo "Clasificacion de Privilegios" -Opciones $opcTipo -TextoSalir "Cancelar"
                
                if ($tipo -ne $null) {
                    $grupo = $opcTipo[$tipo]
                    $dominio = (Get-ADDomain).DistinguishedName
                    
                    # 1. Definir rutas y departamento según el grupo
                    $ouPath = ""
                    $deptoCSV = "Externo"
                    if ($grupo -eq "Cuate") { $ouPath = "OU=Cuates,$dominio"; $deptoCSV = "Cuates" }
                    if ($grupo -eq "No Cuate") { $ouPath = "OU=No Cuates,$dominio"; $deptoCSV = "No Cuates" }
                    if ($grupo -eq "Administrador") { $deptoCSV = "Sistemas" }

                    # 2. Creación en Active Directory
                    $perfilUNC = "\\$env:COMPUTERNAME\Perfiles_P8\$samAccount"
                    if ($ouPath) {
                        New-ADUser -Name $nombreCompleto -SamAccountName $samAccount -AccountPassword $p -Enabled $true -Path $ouPath -ProfilePath $perfilUNC
                    } else {
                        New-ADUser -Name $nombreCompleto -SamAccountName $samAccount -AccountPassword $p -Enabled $true -ProfilePath $perfilUNC
                    }
                    
                    # 3. Lógica de Tokens MFA (Aquí aseguramos que los Cuates compartan token)
                    $semilla = switch ($grupo) {
                        "Cuate"    { "CUATESAAAAAA2226" }
                        "No Cuate" { "NOCUATESAAAA2226" }
                        Default    { [char[]](65..90) + 2..7 | Get-Random -Count 16 | Join-String } # Admin y Externos son individuales
                    }

                    Push-Location "C:\Program Files\multiOTP"
                    .\multiotp.exe -delete $samAccount.ToLower() 2>$null
                    .\multiotp.exe -createga $samAccount.ToLower() $semilla | Out-Null
                    .\multiotp.exe -set $samAccount.ToLower() prefix-pin=0 | Out-Null
                    Pop-Location
                    $semilla | Out-File "C:\Admin_Sistemas\mfa_seeds\$samAccount.b32" -Encoding ASCII -Force
                    
                  # 4. Inyección en el archivo CSV (Protección Anti-Colisión)
                    $rutaCSV = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\config\usuarios.csv")
                    $nuevaLinea = "$nombreCompleto,$samAccount,$passPlain,$deptoCSV"
                    
                    if (Test-Path $rutaCSV) {
                        # Leemos todo el archivo como un solo bloque de texto continuo (-Raw)
                        $contenidoCrudo = Get-Content $rutaCSV -Raw
                        
                        # Evaluamos lógicamente: ¿El archivo NO termina con un salto de línea (`n)?
                        if ($contenidoCrudo -and -not $contenidoCrudo.EndsWith("`n")) {
                            # Si es cierto, inyectamos un salto de línea forzado (Carriage Return + Line Feed)
                            Write-Host "   [~] Detectada falta de salto de linea en CSV. Corrigiendo..." -ForegroundColor Magenta
                            "`r`n" | Out-File -FilePath $rutaCSV -Append -NoNewline -Encoding UTF8
                        }
                    }
                    
                    # Con el terreno seguro, escribimos el nuevo usuario. Out-File agregará automáticamente un `n al final.
                    $nuevaLinea | Out-File -FilePath $rutaCSV -Append -Encoding UTF8
                    Log-Ok "Usuario $samAccount añadido de forma segura al archivo usuarios.csv"

                    # 5. Ejecutar FSRM Automáticamente para este usuario
                    $rutaJSON = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\config\reglas_gobernanza.json")
                    if ((Test-Path $rutaCSV) -and (Test-Path $rutaJSON)) {
                        $reglasJSON = Get-Content $rutaJSON -Raw | ConvertFrom-Json
                        Configurar-AlmacenamientoDinamicop8 -RutaCSV $rutaCSV -reglasJSON $reglasJSON
                    }

                    Log-Ok "IDENTIDAD COMPLETADA: AD + MFA ($grupo) + CSV + FSRM."
                }
                Pausa
            }
            3 {
                $u = Seleccionar-UsuarioAD -Titulo "SELECCIONE USUARIO A ELIMINAR"
                if ($u) {
                    try {
                        Remove-ADUser -Identity $u -Confirm:$false -ErrorAction Stop
                        & "C:\Program Files\multiOTP\multiotp.exe" -delete $u 2>&1 | Out-Null
                        Log-Ok "Eliminado."
                    } catch { Log-Error $_.Exception.Message }
                }
                Pausa
            }
            4 { return }
        }
    }
}

function Menu-EvaluacionP09 {
    $opcEval = @(
        "Test 1: Comandos para Delegacion (RBAC)",
        "Test 2: Comandos para Directiva de Contrasena (FGPP)",
        "Test 3: Instrucciones para Flujo MFA",
        "Test 4: Comandos para Bloqueo de Cuenta",
        "Test 5: Ejecutar Reporte de Auditoria"
    )

    # Preguntamos las contraseñas una sola vez para inyectarlas en los comandos
    Clear-Host
    Write-Host "--- CONFIGURACION DEL TELEPROMPTER ---" -ForegroundColor Cyan
    $pAdmins = Read-Host "Ingrese la contrasena actual de los Administradores"
    $pUsers  = Read-Host "Ingrese la contrasena actual de los Usuarios"
    $pNueva  = Read-Host "Ingrese una contraseña de prueba temporal (Ej. Hacker123!)"

    while ($true) {
        $sel = Generar-Menu -Titulo "TELEPROMPTER DE DEMOSTRACION (Copia y Pega)" -Opciones $opcEval -TextoSalir "Volver al Menu 09"
        Clear-Host
        
        switch ($sel) {
            0 { 
                Write-Host "`n=== TEST 1: CONTROL DE ACCESO BASADO EN ROLES ===" -ForegroundColor Yellow
                Write-Host "Dile al profesor: 'Voy a intentar cambiar la clave de usuario_cuate con admin_storage (que NO tiene permisos)'" -ForegroundColor DarkGray
                Write-Host "`nCopia y pega este bloque en tu consola SSH:`n" -ForegroundColor White
                Write-Host "`$cred = New-Object System.Management.Automation.PSCredential (`"gobernanza\admin_storage`", (ConvertTo-SecureString `"$pAdmins`" -AsPlainText -Force))" -ForegroundColor Cyan
                Write-Host "Set-ADAccountPassword -Identity `"usuario_cuate`" -NewPassword (ConvertTo-SecureString `"$pNueva`" -AsPlainText -Force) -Credential `$cred -Reset" -ForegroundColor Cyan
                Write-Host "`n(El sistema te escupira un error rojo de Acceso Denegado. Demostracion exitosa)." -ForegroundColor Green
                Pausa 
            }
            1 { 
                Write-Host "`n=== TEST 2: DIRECTIVA FGPP (12 Caracteres) ===" -ForegroundColor Yellow
                Write-Host "Dile al profesor: 'Voy a intentar ponerle una contrasena de 8 caracteres al admin_identidad'" -ForegroundColor DarkGray
                Write-Host "`nCopia y pega este comando en tu consola SSH:`n" -ForegroundColor White
                Write-Host "Set-ADAccountPassword -Identity `"admin_identidad`" -NewPassword (ConvertTo-SecureString `"Corta12!`" -AsPlainText -Force) -Reset" -ForegroundColor Cyan
                Write-Host "`n(El sistema lo rechazara por longitud/complejidad. Demostracion exitosa)." -ForegroundColor Green
                Pausa 
            }
            2 { 
                Write-Host "`n=== TEST 3: FLUJO MFA (INTERCEPCION SSH) ===" -ForegroundColor Yellow
                Write-Host "El Test 3 es completamente visual. Haz lo siguiente frente al profesor:" -ForegroundColor White
                Write-Host "1. Abre una nueva ventana de terminal." -ForegroundColor Cyan
                Write-Host "2. Escribe: ssh usuario_cuate@IP_DE_TU_SERVIDOR" -ForegroundColor Cyan
                Write-Host "3. Ingresa la contrasena: $pUsers" -ForegroundColor Cyan
                Write-Host "4. El servidor te mostrara la pantalla azul del Gateway exigiendo el token." -ForegroundColor Cyan
                Write-Host "5. Abre Google Authenticator en tu celular y pon el codigo de 6 digitos." -ForegroundColor Cyan
                Pausa 
            }
            3 { 
                Write-Host "`n=== TEST 4: BLOQUEO POR FUERZA BRUTA ===" -ForegroundColor Yellow
                Write-Host "Dile al profesor: 'Voy a simular 4 intentos de inicio de sesion falsos para disparar el bloqueo'" -ForegroundColor DarkGray
                Write-Host "`nCopia y pega este bloque completo en tu consola SSH:`n" -ForegroundColor White
                Write-Host "Add-Type -AssemblyName System.DirectoryServices.AccountManagement" -ForegroundColor Cyan
                Write-Host "`$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Domain)" -ForegroundColor Cyan
                Write-Host "1..4 | ForEach-Object { `$ctx.ValidateCredentials(`"admin_identidad`", `"ClaveFalsa`$_`") }" -ForegroundColor Cyan
                Write-Host "Get-ADUser -Identity `"admin_identidad`" -Properties LockedOut | Select-Object Name, LockedOut" -ForegroundColor Cyan
                Write-Host "`n(Veras que LockedOut pasa a estar en True. Usa la opcion 4 del Menu 09 para desbloquearlo despues)." -ForegroundColor Green
                Pausa 
            }
            4 { 
                Log-Info "TEST 5: REPORTE AUDITORIA 4625"
                $eventos = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 10 -ErrorAction SilentlyContinue
                if ($eventos) {
                    $ruta = "C:\Users\Administrador\Desktop\Reporte_Auditoria_4625.txt"
                    $resultado = $eventos | Select-Object TimeCreated, Id, @{Name="Motivo"; Expression={$_.Message.Split("`n")[0]}}
                    $resultado | Format-Table -AutoSize
                    $eventos | Format-List | Out-File $ruta
                    Log-Ok "Reporte generado en: $ruta"
                } else {
                    Log-Warning "No se encontraron eventos. Haz el Test 4 primero."
                }
                Pausa 
            }
            5 { return }
        }
    }
}

function Sync-MFA-DesdeCSV {
    $RutaCSV = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\..\..\config\usuarios.csv")
    Log-Info "Sincronizando tokens MFA masivos desde CSV y forzando DB..."
    if (-not (Test-Path $RutaCSV)) { Log-Error "No se encontro el CSV en $RutaCSV"; return }

    $usuarios = Import-Csv -Path $RutaCSV -ErrorAction SilentlyContinue
    if (-not $usuarios) { Log-Error "El CSV esta vacio o corrupto."; return }

    $sCuates   = "CUATESAAAAAA2226"
    $sNoCuates = "NOCUATESAAAA2226"
    $motpDir   = "C:\Program Files\multiOTP"
    $semillasDir = "C:\Admin_Sistemas\mfa_seeds"
    if (-not (Test-Path $semillasDir)) { New-Item $semillasDir -ItemType Directory -Force | Out-Null }

    Push-Location $motpDir
    foreach ($u in $usuarios) {
        $username = $u.Usuario.Trim().ToLower()
        $depto    = $u.Departamento.Trim()
        $semilla  = if ($depto -match "No") { $sNoCuates } else { $sCuates }

        # Forzar borrado y re-creación en DB de multiOTP
        .\multiotp.exe -delete $username 2>&1 | Out-Null
        .\multiotp.exe -createga $username $semilla 2>&1 | Out-Null
        .\multiotp.exe -set $username prefix-pin=0 2>&1 | Out-Null

        $semilla | Out-File "$semillasDir\$username.b32" -Encoding ASCII -Force
        Log-Ok "MFA anclado en DB y archivo: $username ($depto)"
    }
    Pop-Location
}

function Menu-P09 {
    $opciones = @(
        "1. Instalacion Completa (Infraestructura, Roles y Tokens)", 
        "2. Gestion de Usuarios (Ver Tokens / Cambiar Claves)", 
        "3. Submenu de Evaluacion (Teleprompter de Comandos)", 
        "4. Desbloquear Usuarios AD (Lockout)",
        "5. Sincronizar MFA Masivo desde CSV" # <--- NUEVA OPCION
    )

    while ($true) {
        $op = Generar-Menu -Titulo "MODULO 09: SEGURIDAD, RBAC Y MFA" -Opciones $opciones -TextoSalir "Volver al Menu Principal"
        Clear-Host

        switch ($op) {
            0 { Preparar-InfraestructuraP09; Crear-UsuariosRBAC; Configurar-FGPP-Roles; Aplicar-DelegacionControl; Pausa }
            1 { Menu-GestionUsuariosP09 }
            2 { Menu-EvaluacionP09 }
            3 { Desbloquear-UsuariosAD; Pausa }
            4 { Sync-MFA-DesdeCSV; Pausa } # <--- LLAMADA A LA FUNCION
            5 { return }
        }
    }
}