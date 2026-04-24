# ==============================================================================
# MÓDULO: applocker_funciones.ps1 (LA RED DE ARRASTRE - SYSADMIN)
# PROPÓSITO: Hash (Rúbrica) + Bloqueo de Rutas Comodín (Destrucción Total)
# ==============================================================================

Function Configurar-AppLockerP8 {
    Write-Host "`n[*] Configurando AppLocker Zero-Trust (EXE + UWP)..." -ForegroundColor Yellow

    # 1. Asegurar servicio en el servidor
    & sc.exe config AppIDSvc start= auto | Out-Null
    & sc.exe start AppIDSvc | Out-Null
    Write-Host "  [+] Servicio AppIDSvc activado localmente." -ForegroundColor Green

    $GpoName = "GPO_ZeroTrust_AppLocker"
    if (Get-GPO -Name $GpoName -ErrorAction SilentlyContinue) {
        Remove-GPO -Name $GpoName -ErrorAction SilentlyContinue
    }
    New-GPO -Name $GpoName | Out-Null
    New-GPLink -Name $GpoName -Target (Get-ADDomain).DistinguishedName -LinkEnabled Yes | Out-Null

    # 2. Forzar el servicio en los clientes Windows 10
    $AppIdKey = "HKLM\System\CurrentControlSet\Services\AppIDSvc"
    Set-GPRegistryValue -Name $GpoName -Key $AppIdKey -ValueName "Start" -Type DWord -Value 2 | Out-Null

    $GpoGuid  = (Get-GPO -Name $GpoName).Id
    $LdapPath = "LDAP://CN={$GpoGuid},CN=Policies,CN=System,$((Get-ADDomain).DistinguishedName)"

    # 3. Inyectar Reglas Salvavidas
    $xmlSalvavidas = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Windows" Description="Esencial" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="Program Files" Description="Esencial" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="b83c8b2c-a319-4cd0-9690-d2177cad7b52" Name="Program Files x86" Description="Esencial" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES(X86)%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="Administradores" Description="Esencial" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
"@
    $tempSalva = "$env:TEMP\AL_Salvavidas.xml"
    $xmlSalvavidas | Out-File $tempSalva -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $tempSalva -Ldap $LdapPath
    Write-Host "  [+] Reglas salvavidas inyectadas." -ForegroundColor Green

    # 4. Candado Doble al Bloc de Notas (Appx + Exe)
    $sidNC = (Get-ADGroup "Grupo_No Cuates").SID.Value
    $xmlDobleCandado = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePublisherRule Id="$([guid]::NewGuid())" Name="Bloquear Notepad EXE" Description="Bloqueo EXE" UserOrGroupSid="$sidNC" Action="Deny">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="*" BinaryName="NOTEPAD.EXE">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="$([guid]::NewGuid())" Name="Bloquear Notepad UWP" Description="Bloqueo Appx" UserOrGroupSid="$sidNC" Action="Deny">
      <Conditions>
        <FilePublisherCondition PublisherName="CN=MICROSOFT WINDOWS, O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="Microsoft.WindowsNotepad" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@
    $tempPub = "$env:TEMP\AL_DobleCandado.xml"
    $xmlDobleCandado | Out-File $tempPub -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $tempPub -Ldap $LdapPath -Merge
    Write-Host "  [+] Candado Doble (Notepad EXE + UWP) aplicado." -ForegroundColor Green

    Remove-Item $tempSalva, $tempPub -ErrorAction SilentlyContinue
}