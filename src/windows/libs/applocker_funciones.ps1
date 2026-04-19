# ==============================================================================
# MÓDULO: applocker_funciones.ps1 (LA RED DE ARRASTRE - SYSADMIN)
# PROPÓSITO: Hash (Rúbrica) + Bloqueo de Rutas Comodín (Destrucción Total)
# ==============================================================================

function Configurar-AppLockerP8 {
    Write-Host "`n[*] Desplegando Red de Arrastre (Hash + Path Exhaustivo)..." -ForegroundColor Yellow

    $DominioDN = (Get-ADDomain).DistinguishedName
    $GpoName = "GPO_AppLocker_NoCuates_P8"
    $fqdn = (Get-ADDomain).DNSRoot

    # 1. Resolución de Identidad a prueba de fallos
    $grupoAD = Get-ADGroup -Filter "Name -like '*No*Cuates*'" | Select-Object -First 1
    if (-not $grupoAD) { Write-Host "  [!] ERROR: No se encontró el grupo." -ForegroundColor Red; return }
    $sidGrupo = $grupoAD.SID.Value

    # 2. Recrear GPO
    Write-Host "  -> Limpiando GPO anterior..." -ForegroundColor Cyan
    Remove-GPO -Name $GpoName -KeepLinks:$false -ErrorAction SilentlyContinue
    $Gpo = New-GPO -Name $GpoName
    New-GPLink -Name $GpoName -Target $DominioDN -Enforced Yes | Out-Null
    $RutaLdap = "LDAP://CN={$($Gpo.Id)},CN=Policies,CN=System,$DominioDN"

    Start-Sleep -Seconds 2

    # 3. ENSAMBLAJE DE LA RED
    Write-Host "  -> Configurando Muro de Contención..." -ForegroundColor Cyan
    
    # Hash extraído anteriormente para cumplir la rúbrica
    $hashData = "0xDA5807BB0997CC6B5132950EC87EDA2B33B1AC4533CF1F7A22A6F3B576ED7C5B"
    $hashLen = 200704

    $xmlDefinitivo = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Allow Program Files" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="Allow Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="Allow Admins" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>

    <FileHashRule Id="$([guid]::NewGuid().ToString())" Name="DENY Notepad Hash" Description="Bloqueo criptográfico" UserOrGroupSid="$sidGrupo" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="$hashData" SourceFileName="notepad.exe" SourceFileLength="$hashLen" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>

    <FilePathRule Id="$([guid]::NewGuid().ToString())" Name="DENY Notepad Sys32" Description="" UserOrGroupSid="$sidGrupo" Action="Deny">
      <Conditions><FilePathCondition Path="%SYSTEM32%\notepad.exe" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$([guid]::NewGuid().ToString())" Name="DENY Notepad Win" Description="" UserOrGroupSid="$sidGrupo" Action="Deny">
      <Conditions><FilePathCondition Path="%WINDIR%\notepad.exe" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$([guid]::NewGuid().ToString())" Name="DENY Notepad SysWOW64" Description="" UserOrGroupSid="$sidGrupo" Action="Deny">
      <Conditions><FilePathCondition Path="%WINDIR%\SysWOW64\notepad.exe" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$([guid]::NewGuid().ToString())" Name="DENY Notepad Comodin" Description="" UserOrGroupSid="$sidGrupo" Action="Deny">
      <Conditions><FilePathCondition Path="*\notepad.exe" /></Conditions>
    </FilePathRule>

  </RuleCollection>

  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="$([guid]::NewGuid().ToString())" Name="DENY UWP Notepad" Description="" UserOrGroupSid="$sidGrupo" Action="Deny">
      <Conditions>
        <FilePublisherCondition PublisherName="*" ProductName="*Notepad*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba" Name="Allow Otras Apps UWP" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="*" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@

    # 4. Inyección en el Cerebro de AD y SYSVOL
    $TempXml = "$env:TEMP\AppLockerSysAdmin.xml"
    [System.IO.File]::WriteAllText($TempXml, $xmlDefinitivo, [System.Text.Encoding]::UTF8)
    Set-AppLockerPolicy -XmlPolicy $TempXml -Ldap $RutaLdap
    Remove-Item $TempXml -Force

    $applockerDir = "\\$fqdn\SYSVOL\$fqdn\Policies\{$($Gpo.Id)}\Machine\AppLocker"
    if (-not (Test-Path $applockerDir)) { New-Item -Path $applockerDir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText("$applockerDir\AppLocker.xml", $xmlDefinitivo, [System.Text.Encoding]::UTF8)

    # 5. Configuración de Servicios y Logoff
    Set-GPRegistryValue -Name $GpoName -Key "HKLM\System\CurrentControlSet\Services\AppIDSvc" -ValueName "Start" -Type DWord -Value 2 | Out-Null
    
    $secEditDir = "\\$fqdn\SYSVOL\$fqdn\Policies\{$($Gpo.Id)}\Machine\Microsoft\Windows NT\SecEdit"
    if (-not (Test-Path $secEditDir)) { New-Item -Path $secEditDir -ItemType Directory -Force | Out-Null }
    $tmplContent = "[Unicode]`r`nUnicode=yes`r`n[System Access]`r`nForceLogoffWhenHourExpire = 1`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1"
    [System.IO.File]::WriteAllText("$secEditDir\GptTmpl.inf", $tmplContent, [System.Text.Encoding]::Unicode)

    Write-Host "`n[FORTALEZA ACTIVA] Bloqueo ineludible desplegado." -ForegroundColor Green
}