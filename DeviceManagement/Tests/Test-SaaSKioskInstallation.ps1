# In-memory registry/files/process fixtures only. Never install on this computer.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$handlerPath=Join-Path $projectRoot 'Installations\KIOSK\SaaS-Install.ps1'
$sourcePath=Join-Path $projectRoot 'Installations\KIOSK\SaaS\Kiosk_Mode_Setup.ps1'
$source=[IO.File]::ReadAllText($sourcePath)
$handler=[IO.File]::ReadAllText($handlerPath)
function Assert-Installation {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$body=$source.Substring($source.IndexOf('$URL ='))
$sha=[Security.Cryptography.SHA256]::Create()
try{$bodyHash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($body))).Replace('-','')}finally{$sha.Dispose()}
Assert-Installation ($bodyHash -ceq '4772119EC97EF52757019BB85F9B5ED33FD89EE5D17016EA0BF6EC3B1A1031F9') 'The preserved setup body changed.'
Assert-Installation (-not $source.Contains('$ZabbixHostName') -and $source.Contains('&host=$HostName')) 'Hostname rename did not reach the original launcher URL.'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($handler,[ref]$tokens,[ref]$parseErrors)
Assert-Installation ($parseErrors.Count -eq 0) 'Handler does not parse.'
$admin=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SaaSKioskInstallationAdministrator'},$true))
Assert-Installation ($admin.Count -eq 1) 'Administrator fixture boundary changed.'
$code=$handler.Remove($admin[0].Extent.StartOffset,$admin[0].Extent.EndOffset-$admin[0].Extent.StartOffset).Insert($admin[0].Extent.StartOffset,'function Test-SaaSKioskInstallationAdministrator { return Get-SaaSFixtureAdministrator }')
$fixtureAst=[Management.Automation.Language.Parser]::ParseInput($code,$handlerPath,[ref]$tokens,[ref]$parseErrors)
$fixture=$fixtureAst.GetScriptBlock()
$oldComputerName=$env:COMPUTERNAME
$env:COMPUTERNAME='DEVICE-KIOSK01'
function Get-SaaSFixtureAdministrator { $script:administrator }
function Get-CimInstance { [CmdletBinding()]param([string]$ClassName,[string[]]$Property) [pscustomobject]@{DNSHostName=$script:dnsHostName} }
function Get-LocalUser {[CmdletBinding()]param() $script:users}
function Read-Host {
    param([string]$Prompt)
    $script:prompts.Add($Prompt)
    if(-not $script:answers.Count){throw ('Unexpected input request: '+$Prompt)}
    $script:answers.Dequeue()
}
function Assert-FixtureWrite {
    Assert-Installation ($script:answers.Count -eq 0) 'Setup wrote before required input collection completed.'
    $script:writes++
}
function Test-Path {
    [CmdletBinding()]param([string]$Path,[string]$LiteralPath,[string]$PathType)
    $value=if($LiteralPath){$LiteralPath}else{$Path}
    if($value -eq 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'){return $script:edgePresent}
    if($value -match '^C:\\Users\\[^\\]+$'){return $script:profilePresent}
    return ($script:files.ContainsKey($value) -or $script:directories.ContainsKey($value))
}
function New-Item {
    [CmdletBinding()]param([string]$Path,[string]$ItemType,[switch]$Force)
    Assert-FixtureWrite
    $script:directories[$Path]=$true
}
function Set-ItemProperty {
    [CmdletBinding()]param([string]$Path,[string]$Name,$Value,[string]$Type)
    Assert-FixtureWrite
    if($script:writeDenied){throw 'Fixture write denied'}
    if(-not $script:propertyNoEffect){$script:registry[$Path+'|'+$Name]=$Value}
}
function Get-ItemProperty {
    [CmdletBinding()]param([string]$LiteralPath,[string]$Name)
    $key=$LiteralPath+'|'+$Name
    if(-not $script:registry.ContainsKey($key)){throw ('Fixture value missing: '+$key)}
    $properties=@{};$properties[$Name]=$script:registry[$key]
    [pscustomobject]$properties
}
function reg {
    Assert-FixtureWrite
    if($script:nativeFailure){$global:LASTEXITCODE=5;return 'Fixture reg failure'}
    $script:registry['HKLM:\SOFTWARE\Policies\Microsoft\Edge\LocalNetworkAccessAllowedForUrls|1']='https://kiosk.ordermonkey.com'
    $global:LASTEXITCODE=0
    'Fixture registry operation completed'
}
function Stop-Process {[CmdletBinding()]param([string]$Name,[switch]$Force) Assert-FixtureWrite;$script:stops.Add($Name)}
function Start-Process {[CmdletBinding()]param([string]$FilePath) Assert-FixtureWrite;$script:starts.Add($FilePath)}
function Set-Content {
    [CmdletBinding()]param([string]$Path,[Parameter(ValueFromPipeline=$true)]$Value)
    process { Assert-FixtureWrite;if(-not $script:fileNoEffect){$script:files[$Path]=[string]$Value+"`r`n"} }
}
function Get-Content {
    [CmdletBinding()]param([string]$LiteralPath,[switch]$Raw)
    if(-not $script:files.ContainsKey($LiteralPath)){throw 'Fixture file missing'}
    $script:files[$LiteralPath]
}
function Reset-Installation {
    param([string[]]$Answers=@('','RESTAURANT-01','Kiosk-1',''))
    $script:answers=New-Object 'Collections.Generic.Queue[string]'
    foreach($answer in $Answers){$script:answers.Enqueue($answer)}
    $script:prompts=New-Object 'Collections.Generic.List[string]'
    $script:users=@([pscustomobject]@{Name='Admin';Enabled=$true},[pscustomobject]@{Name='SELISE';Enabled=$true},[pscustomobject]@{Name='SELISE-KIOSK';Enabled=$true})
    $script:files=@{};$script:registry=@{};$script:directories=@{};$script:writes=0
    $script:stops=New-Object 'Collections.Generic.List[string]'
    $script:starts=New-Object 'Collections.Generic.List[string]'
    $script:administrator=$true;$script:profilePresent=$true;$script:edgePresent=$true;$script:dnsHostName='DEVICE-KIOSK01'
    $script:writeDenied=$false;$script:propertyNoEffect=$false;$script:fileNoEffect=$false;$script:nativeFailure=$false
    $script:DeviceManagementMemoryBundle=$null
    $script:context=[pscustomobject]@{ClientType='SaaS';DeviceType='KIOSK';Operation='KioskInstallation';Mode='Apply'}
}
function Invoke-InstallationFixture {
    $result=@(& $fixture -Context $script:context)
    Assert-Installation ($result.Count -eq 1) 'Handler leaked native stdout or lost its structured result.'
    $result[0]
}
try {
    Reset-Installation
    $global:LASTEXITCODE=487
    $result=Invoke-InstallationFixture
    Assert-Installation ($result.Status -eq 'Pass') ('Default installation failed: '+$result.Message)
    Assert-Installation ($global:LASTEXITCODE -eq 487) 'Installer changed the caller native exit state.'
    Assert-Installation ($script:prompts.Count -eq 4 -and $script:prompts[0] -eq 'Kiosk User [SELISE-KIOSK]' -and $script:prompts[3] -eq 'Hostname [DEVICE-KIOSK01]') 'Detected account/hostname suggestions or prompt order changed.'
    Assert-Installation ($script:files['C:\Users\SELISE-KIOSK\Scripts\LaunchKiosk.ps1'].Contains('?restaurantId=RESTAURANT-01&kioskId=Kiosk-1&host=DEVICE-KIOSK01')) 'Input values did not reach the original launcher.'
    Assert-Installation ($script:stops.Count -eq 1 -and $script:stops[0] -eq 'explorer' -and $script:starts.Count -eq 1 -and $script:starts[0] -eq 'explorer.exe') 'Original Explorer operations changed.'

    Reset-Installation
    $env:COMPUTERNAME='OM-DHK-PAN-KIOS';$script:dnsHostName='OM-DHK-PAN-KIOSK'
    try {
        $result=Invoke-InstallationFixture
        Assert-Installation ($result.Status -eq 'Pass' -and $script:prompts[3] -ceq 'Hostname [OM-DHK-PAN-KIOSK]' -and $script:files['C:\Users\SELISE-KIOSK\Scripts\LaunchKiosk.ps1'].Contains('host=OM-DHK-PAN-KIOSK')) 'Full DNS hostname was truncated during Edge setup.'
    } finally { $env:COMPUTERNAME='DEVICE-KIOSK01' }
    Reset-Installation @('missing-user','sElIsE','','BAD&ID','BRANCH-2',"bad'id",'Kiosk-2','bad host','MANUAL-HOST')
    $script:DeviceManagementMemoryBundle=@{Files=@{'DeviceManagement/Installations/KIOSK/SaaS/Kiosk_Mode_Setup.ps1'=$source}}
    $result=Invoke-InstallationFixture
    Assert-Installation ($result.Status -eq 'Pass') ('Manual/retry installation failed: '+$result.Message)
    Assert-Installation ($script:files['C:\Users\SELISE\Scripts\LaunchKiosk.ps1'].Contains('?restaurantId=BRANCH-2&kioskId=Kiosk-2&host=MANUAL-HOST')) 'Manual inputs were not retained.'
    Assert-Installation ($script:prompts.Count -eq 9) 'Invalid/missing values did not retry before writes.'

    Reset-Installation
    $script:users=@([pscustomobject]@{Name='SELISE';Enabled=$true})
    $result=Invoke-InstallationFixture
    Assert-Installation ($result.Status -eq 'Pass' -and $script:prompts[0] -eq 'Kiosk User [SELISE]') 'Existing SELISE fallback was not suggested.'

    foreach($failure in @('profilePresent','edgePresent','administrator')) {
        Reset-Installation
        Set-Variable -Name $failure -Value $false -Scope Script
        $result=Invoke-InstallationFixture
        Assert-Installation ($result.Status -eq 'Fail' -and $script:writes -eq 0) ('Failed prerequisite allowed changes: '+$failure)
    }
    foreach($failure in @('writeDenied','propertyNoEffect','fileNoEffect','nativeFailure')) {
        Reset-Installation
        Set-Variable -Name $failure -Value $true -Scope Script
        $result=Invoke-InstallationFixture
        Assert-Installation ($result.Status -eq 'Fail') ('Unverified installation was reported successful: '+$failure)
    }
    foreach($invalid in @(@{ClientType='Subway'},@{DeviceType='POS'},@{Operation='ThoroughCheck'},@{Mode='Audit'})) {
        Reset-Installation
        foreach($key in $invalid.Keys){$script:context.$key=$invalid[$key]}
        $result=Invoke-InstallationFixture
        Assert-Installation ($result.Status -eq 'Fail' -and $script:prompts.Count -eq 0 -and $script:writes -eq 0) 'Wrong context reached setup.'
    }
    Reset-Installation
    $WhatIfPreference=$true
    try{$result=Invoke-InstallationFixture}finally{$WhatIfPreference=$false}
    Assert-Installation ($result.Status -eq 'Unavailable' -and $script:writes -eq 0 -and $script:prompts.Count -eq 0) 'WhatIf reached setup.'

    Import-Module (Join-Path $projectRoot 'Core\Validation.psm1') -Force
    $operations=Import-PowerShellDataFile (Join-Path $projectRoot 'Config\Operations.psd1')
    $operation=Get-DeviceOperations $operations KIOSK SaaS | Where-Object Id -eq KioskInstallation
    Assert-Installation (Test-OperationSelectionReady $operation SaaS KIOSK Apply) 'SaaS KIOSK Apply is unavailable.'
    foreach($selection in @(@('SaaS','KIOSK','Audit'),@('Subway','KIOSK','Audit'),@('SaaS','POS','Apply'),@('ViCafe','KIOSK','Apply'))) {
        Assert-Installation (-not (Test-OperationSelectionReady $operation $selection[0] $selection[1] $selection[2])) 'Another installation selection was enabled.'
    }
    Write-Output 'PASS: SaaS setup input defaults/manual/retries; unchanged setup body; local and embedded source paths; prerequisites, readback/native failures, WhatIf and routing isolation. No Windows mutation executed.'
} finally { $env:COMPUTERNAME=$oldComputerName }
