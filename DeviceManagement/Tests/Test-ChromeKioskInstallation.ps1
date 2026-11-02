# In-memory Windows fixtures only. Never execute a kiosk installer against this computer.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
function Assert-Chrome { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
function Mock-ChromeAdmin { $script:admin }
function Mock-ChromeRegistryRead {
 param([string]$Path,[string]$Name)
 $key=$Path+'|'+$Name
 if($script:registry.ContainsKey($key)) { return @{Exists=$true;Value=$script:registry[$key].Value;Type=$script:registry[$key].Type} }
 return @{Exists=$false;Value=$null;Type=$null}
}
function Mock-ChromeRegistryWrite {
 param([string]$Path,[string]$Name,$Value,[string]$Type)
 Assert-Chrome ($script:answers.Count -eq 0) 'Mutation preceded input completion.'
 $script:writes++
 if(-not $script:registryNoEffect) { $script:registry[$Path+'|'+$Name]=@{Value=$Value;Type=$Type} }
}
function Mock-ChromeFileRead {
 param([string]$Path)
 if(-not $script:files.ContainsKey($Path)){throw ('Missing fixture file: '+$Path)}
 return ,([byte[]]$script:files[$Path])
}
function Mock-ChromeFileWrite {
 param([string]$Path,[byte[]]$Bytes)
 $script:writes++
 $script:fileWriteCount++
 if($script:failSecondFile -and $script:fileWriteCount -eq 2) { throw 'Fixture file write failed' }
 if(-not $script:fileNoEffect){$script:files[$Path]=[byte[]]$Bytes.Clone()}
}
function Get-LocalUser { [CmdletBinding()]param() $script:users }
function Read-Host {
 param([string]$Prompt)
 $script:prompts.Add($Prompt)
 if(-not $script:answers.Count){throw ('Unexpected prompt: '+$Prompt)}
 $script:answers.Dequeue()
}
function Test-Path {
 [CmdletBinding()]param([string]$LiteralPath,[string]$Path,[string]$PathType)
 $value=if($LiteralPath){$LiteralPath}else{$Path}
 if($value -like '*\chrome.exe'){return $value -eq $script:chromePath}
 if($value -eq $script:profilePath){return $script:profilePresent}
 if($value -like 'HKLM:*'){return @($script:registry.Keys | Where-Object { $_.StartsWith($value+'|') }).Count -gt 0}
 return $script:files.ContainsKey($value) -or $script:directories.ContainsKey($value)
}
function Get-Item {
 [CmdletBinding()]param([string]$LiteralPath)
 $key=[pscustomobject]@{Path=$LiteralPath}
 $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value {
     foreach($entry in $script:registry.Keys) { if($entry.StartsWith($this.Path+'|')) { $entry.Substring($this.Path.Length+1) } }
 }
 return $key
}
function New-Item {
 [CmdletBinding()]param([string]$Path,[string]$ItemType,[switch]$Force)
 $script:writes++;$script:directories[$Path]=$true
}
function Remove-Item {
 [CmdletBinding()]param([string]$LiteralPath,[switch]$Force)
 $script:writes++;$script:files.Remove($LiteralPath)
}
function Remove-ItemProperty {
 [CmdletBinding()]param([string]$LiteralPath,[string]$Name)
 $script:writes++;$script:registry.Remove($LiteralPath+'|'+$Name)
}
function New-Object {
 [CmdletBinding(DefaultParameterSetName='Type')]
 param([Parameter(Position=0,ParameterSetName='Type')][string]$TypeName,[Parameter(Position=1,ParameterSetName='Type')][object[]]$ArgumentList,[Parameter(ParameterSetName='COM')][string]$ComObject)
 if($ComObject) {
     Assert-Chrome ($ComObject -eq 'WScript.Shell') 'Unexpected COM access.'
     $shell=[pscustomobject]@{}
     $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
         param($path)
         $shortcut=[pscustomobject]@{Path=$path;TargetPath='';WorkingDirectory='';WindowStyle=0;Description=''}
         if($script:savedShortcut -and $script:files.ContainsKey($path)) {
             $shortcut.TargetPath=$script:savedShortcut.TargetPath;$shortcut.WorkingDirectory=$script:savedShortcut.WorkingDirectory
             $shortcut.WindowStyle=$script:savedShortcut.WindowStyle;$shortcut.Description=$script:savedShortcut.Description
         }
         $shortcut | Add-Member -MemberType ScriptMethod -Name Save -Value {
             $script:writes++
             $script:files[$this.Path]=[byte[]](1,2,3)
             $script:savedShortcut=$this
             if($script:shortcutNoEffect){$this.TargetPath='wrong'}
         }
         return $shortcut
     }
     return $shell
 }
 Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}
function Start-Process {
 [CmdletBinding()]param([string]$FilePath,[string]$ArgumentList,[string]$WindowStyle)
 $script:launchedPath=$FilePath;$script:launchedArguments=$ArgumentList
}
function Reset-Chrome {
 param([string[]]$Answers=@('','BRANCH-1','KIOSK-2',''))
 $script:answers=[Collections.Generic.Queue[string]]::new()
 foreach($answer in $Answers){$script:answers.Enqueue($answer)}
 $script:prompts=[Collections.Generic.List[string]]::new()
 $script:users=@([pscustomobject]@{Name='SELISE-KIOSK';Enabled=$true})
 $script:admin=$true;$script:profilePresent=$true;$script:profilePath='C:\Users\SELISE-KIOSK'
 $script:chromePath='C:\Program Files\Google\Chrome\Application\chrome.exe'
 $script:files=@{};$script:directories=@{};$script:registry=@{}
 $script:writes=0;$script:fileWriteCount=0
 $script:registryNoEffect=$false;$script:fileNoEffect=$false;$script:failSecondFile=$false;$script:shortcutNoEffect=$false;$script:savedShortcut=$null
}
function Get-ChromeFixtureLocalSource {
 param([string]$Path)
 Assert-Chrome ($Path -ceq $script:expectedLocalSource) 'Handler selected the wrong local Chrome source.'
 return $script:chromeSetupFixtureCode
}
function Invoke-ChromeFixture { & $script:fixture -Confirm:$false }
function Assert-ChromeFailure {
 param([string]$Message)
 $failed=$false
 try{Invoke-ChromeFixture}catch{$failed=$true}
 Assert-Chrome $failed $Message
}
$oldComputer=$env:COMPUTERNAME
$env:COMPUTERNAME='FIXTURE-KIOSK01'
try {
 foreach($client in @('SaaS','Subway')) {
     $sourcePath=Join-Path $projectRoot ('Installations\KIOSK\'+$client+'\Kiosk_Mode_Setup_Chrome.ps1')
     $source=[IO.File]::ReadAllText($sourcePath)
     $tokens=$null;$errors=$null
     $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
     Assert-Chrome ($errors.Count -eq 0) ($client+' source parse failure.')
     $replacements=@{
         'Test-ChromeKioskAdministrator'='function Test-ChromeKioskAdministrator { Mock-ChromeAdmin }'
         'Read-ChromeKioskFile'='function Read-ChromeKioskFile { param($Path) return ,(Mock-ChromeFileRead $Path) }'
         'Write-ChromeKioskFile'='function Write-ChromeKioskFile { param($Path,[byte[]]$Bytes) Mock-ChromeFileWrite $Path $Bytes }'
         'Get-ChromeKioskRegistryState'='function Get-ChromeKioskRegistryState { param($Path,$Name) Mock-ChromeRegistryRead $Path $Name }'
         'Set-ChromeKioskRegistryValue'='function Set-ChromeKioskRegistryValue { param($Path,$Name,$Value,$Type) Mock-ChromeRegistryWrite $Path $Name $Value $Type }'
     }
     $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $replacements.ContainsKey($n.Name)},$true))
     Assert-Chrome ($functions.Count -eq 5) 'Fixture isolation boundary changed.'
     foreach($fn in @($functions | Sort-Object {$_.Extent.StartOffset} -Descending)) {
         $source=$source.Remove($fn.Extent.StartOffset,$fn.Extent.EndOffset-$fn.Extent.StartOffset).Insert($fn.Extent.StartOffset,$replacements[$fn.Name])
     }
     $script:fixture=[scriptblock]::Create($source)
     $origin=if($client -eq 'SaaS'){'https://kiosk.ordermonkey.com'}else{'https://kiosk.subway.ch'}
     $reg='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
     $policy='HKLM:\SOFTWARE\Policies\Google\Chrome\LocalNetworkAccessAllowedForUrls'
     $launch='C:\Users\SELISE-KIOSK\Scripts\LaunchKiosk.ps1'
     $batch='C:\Users\SELISE-KIOSK\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
     foreach($chrome in @('C:\Program Files\Google\Chrome\Application\chrome.exe','C:\Program Files (x86)\Google\Chrome\Application\chrome.exe','C:\Users\SELISE-KIOSK\AppData\Local\Google\Chrome\Application\chrome.exe')) {
         Reset-Chrome;$script:chromePath=$chrome
         Invoke-ChromeFixture
         Assert-Chrome ([Convert]::ToBase64String([byte[]]$script:files[$launch][0..2]) -ceq '77u/') 'Generated PowerShell launcher lacks its UTF-8 BOM.'
         $launcher=[Text.Encoding]::UTF8.GetString($script:files[$launch])
         Assert-Chrome ($launcher.Contains($chrome) -and $launcher.Contains('--kiosk "'+$origin+'/#/onboarding/login?restaurantId=BRANCH-1&kioskId=KIOSK-2&host=FIXTURE-KIOSK01"')) 'Browser detection or onboarding URL failed.'
         Assert-Chrome ($launcher.Contains('--disable-pinch') -and $launcher.Contains('--overscroll-history-navigation=0') -and $launcher.Contains('--user-data-dir="C:\Users\SELISE-KIOSK\Scripts\ChromeKioskProfile"')) 'Gesture flags/profile quoting failed.'
         Assert-Chrome (-not $launcher.Contains('msedge') -and -not $launcher.Contains('--edge-')) 'Edge command leaked into Chrome launcher.'
         $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($launcher,[ref]$t,[ref]$e)
         Assert-Chrome ($e.Count -eq 0) 'Generated launcher does not parse.'
         Assert-Chrome ($script:files.ContainsKey($batch)) 'Startup launcher missing.'
         $batchBytes=$script:files[$batch]
         Assert-Chrome ($batchBytes[0] -eq 64 -and [Text.Encoding]::UTF8.GetString($batchBytes).StartsWith("@echo off`r`nsetlocal DisableDelayedExpansion`r`nchcp 65001 >nul`r`n")) 'BAT has an invalid CMD encoding/header.'
         & ([scriptblock]::Create($launcher.TrimStart([char]0xFEFF)))
         Assert-Chrome ([regex]::Matches($script:launchedArguments,'(?:^|\s)--incognito(?:\s|$)').Count -eq 1) 'Generated kiosk launcher must pass --incognito exactly once.'
         Assert-Chrome ($script:launchedPath -eq $chrome -and $script:launchedArguments.Contains('--kiosk "'+$origin+'/#/onboarding/login?restaurantId=BRANCH-1&kioskId=KIOSK-2&host=FIXTURE-KIOSK01"')) 'Generated launcher changed runtime arguments.'
         Assert-Chrome (($script:savedShortcut -ne $null) -eq ($client -eq 'Subway')) 'Desktop shortcut scope changed.'
     }
     Reset-Chrome @("Kiosk O'Brien",'BRANCH-1','KIOSK-2','')
     $script:users=@([pscustomobject]@{Name="Kiosk O'Brien";Enabled=$true})
     $script:profilePath="C:\Users\Kiosk O'Brien"
     Invoke-ChromeFixture
     $customLauncher=[Text.Encoding]::UTF8.GetString($script:files["C:\Users\Kiosk O'Brien\Scripts\LaunchKiosk.ps1"])
     & ([scriptblock]::Create($customLauncher.TrimStart([char]0xFEFF)))
     Assert-Chrome ($script:launchedArguments.Contains('--user-data-dir="C:\Users\Kiosk O''Brien\Scripts\ChromeKioskProfile"')) 'Spaces/apostrophe in user path broke the generated launcher.'
     Reset-Chrome @('missing','SELISE-KIOSK','','bad&id','BRANCH-1',"bad'id",'KIOSK-2','bad host','MANUAL-HOST')
     Invoke-ChromeFixture
     Assert-Chrome ($script:prompts.Count -eq 9 -and [Text.Encoding]::UTF8.GetString($script:files[$launch]).Contains('host=MANUAL-HOST')) 'Input retry/manual hostname failed.'
     foreach($failure in @('admin','profilePresent','chromePath')) {
         Reset-Chrome
         if($failure -eq 'chromePath'){$script:chromePath='missing'}else{Set-Variable -Scope Script -Name $failure -Value $false}
         Assert-ChromeFailure ('Missing prerequisite allowed setup: '+$failure)
         Assert-Chrome ($script:writes -eq 0) 'Prerequisite failure mutated state.'
     }
     Reset-Chrome
     $script:registry[$reg+'|DefaultUserName']=@{Value='SELISE-KIOSK';Type='String'}
     $script:registry[$reg+'|DefaultPassword']=@{Value='fixture-secret';Type='String'}
     $script:registry[$policy+'|1']=@{Value='https://another.example';Type='String'}
     $script:registry[$policy+'|3']=@{Value=$origin;Type='String'}
     Invoke-ChromeFixture
     Assert-Chrome ($script:registry[$reg+'|DefaultPassword'].Value -ceq 'fixture-secret') 'Existing credentials were overwritten.'
     Assert-Chrome (-not $script:registry.ContainsKey($policy+'|2') -and $script:registry[$policy+'|1'].Value -eq 'https://another.example') 'Allowlist entries or gap handling failed.'
     $script:answers=[Collections.Generic.Queue[string]]::new([string[]]@('','BRANCH-1','KIOSK-2',''))
     $registryCount=$script:registry.Count
     Invoke-ChromeFixture
     Assert-Chrome ($script:registry.Count -eq $registryCount) 'Repeated setup added registry values.'
     Reset-Chrome
     $script:registry[$reg+'|DefaultUserName']=@{Value='Other';Type='String'}
     $script:registry[$reg+'|DefaultPassword']=@{Value='fixture-secret';Type='String'}
     Assert-ChromeFailure 'Other account credentials allowed replacement.'
     Assert-Chrome ($script:writes -eq 0) 'Credential conflict mutated state.'
     foreach($failure in @('registryNoEffect','fileNoEffect','failSecondFile','shortcutNoEffect')) {
         if($failure -eq 'shortcutNoEffect' -and $client -ne 'Subway'){continue}
         Reset-Chrome
         Set-Variable -Scope Script -Name $failure -Value $true
         Assert-ChromeFailure ('Unverified setup succeeded: '+$failure)
         Assert-Chrome ($script:registry.Count -eq 0 -and $script:files.Count -eq 0) ('Rollback left managed values/files: '+$failure)
     }
     Reset-Chrome
     $script:files[$launch]=[byte[]](255,254,1,0);$script:files[$batch]=[byte[]](9,8,7)
     $script:registry[$reg+'|DefaultUserName']=@{Value='OldUser';Type='String'}
     $script:failSecondFile=$true
     Assert-ChromeFailure 'Partial write did not fail.'
     Assert-Chrome ([Convert]::ToBase64String($script:files[$launch]) -ceq '//4BAA==' -and [Convert]::ToBase64String($script:files[$batch]) -ceq 'CQgH') 'Existing launcher bytes were not restored.'
     Assert-Chrome ($script:registry.Count -eq 1 -and $script:registry[$reg+'|DefaultUserName'].Value -ceq 'OldUser') 'Existing registry value was not restored.'
     Reset-Chrome
     & $script:fixture -WhatIf
     Assert-Chrome ($script:writes -eq 0 -and $script:prompts.Count -eq 0) 'WhatIf requested input or mutated state.'
     # Run the real per-client handler through both source loaders, with the same
     # isolated setup body used above. No registry, file, account, or COM access is live.
     $handlerPath=Join-Path $projectRoot ('Installations\KIOSK\'+$client+'-Install.ps1')
     $handlerCode=[IO.File]::ReadAllText($handlerPath)
     $handlerAst=[Management.Automation.Language.Parser]::ParseInput($handlerCode,[ref]$tokens,[ref]$errors)
     Assert-Chrome ($errors.Count -eq 0) 'Handler parse failure.'
     $adminName='Test-'+$client+'KioskInstallationAdministrator'
     $adminFn=@($handlerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $adminName},$true))[0]
     $handlerCode=$handlerCode.Remove($adminFn.Extent.StartOffset,$adminFn.Extent.EndOffset-$adminFn.Extent.StartOffset).Insert($adminFn.Extent.StartOffset,('function '+$adminName+' { Mock-ChromeAdmin }'))
     $handlerCode=$handlerCode.Replace('[IO.File]::ReadAllText($sourcePath)','(Get-ChromeFixtureLocalSource $sourcePath)')
     $handlerAst=[Management.Automation.Language.Parser]::ParseInput($handlerCode,$handlerPath,[ref]$tokens,[ref]$errors)
     $handlerFixture=$handlerAst.GetScriptBlock()
     $script:expectedLocalSource=$sourcePath
     $script:chromeSetupFixtureCode=$source
     $context=[pscustomobject]@{ClientType=$client;DeviceType='KIOSK';Operation='KioskInstallation';Mode='Apply';Browser='Chrome'}
     $resource='DeviceManagement/Installations/KIOSK/'+$client+'/Kiosk_Mode_Setup_Chrome.ps1'
     foreach($loader in @('local','embedded')) {
         Reset-Chrome
         $script:DeviceManagementMemoryBundle=if($loader -eq 'embedded'){@{Files=@{$resource=$source}}}else{$null}
         $global:LASTEXITCODE=487
         $result=@(& $handlerFixture -Context $context)
         Assert-Chrome ($result.Count -eq 1 -and $result[0].Status -eq 'Pass' -and $result[0].Message.Contains('Chrome KIOSK Installation')) ('Chrome handler failed through '+$loader+' source loader.')
         Assert-Chrome ($global:LASTEXITCODE -eq 487) 'Chrome handler changed caller native exit state.'
     }
     foreach($failure in @('registryNoEffect','fileNoEffect','failSecondFile')) {
         Reset-Chrome
         $script:DeviceManagementMemoryBundle=@{Files=@{$resource=$source}}
         Set-Variable -Scope Script -Name $failure -Value $true
         $result=@(& $handlerFixture -Context $context)
         Assert-Chrome ($result.Count -eq 1 -and $result[0].Status -eq 'Fail') ('Handler hid Chrome setup failure: '+$failure)
     }
     foreach($badSource in @(
         'param([switch]$PassThru)',
         'param([switch]$PassThru) throw "Fixture failed"',
         'param([switch]$PassThru) [pscustomobject]@{ChromeKioskSetupCompleted=$false;ClientType="'+$client+'";KioskUser="Fixture";HostName="Fixture"}',
         'param([switch]$PassThru) [pscustomobject]@{ChromeKioskSetupCompleted=$true;ClientType="WrongClient";KioskUser="Fixture";HostName="Fixture"}',
         'param([switch]$PassThru) 1;2'
     )) {
         Reset-Chrome
         $script:DeviceManagementMemoryBundle=@{Files=@{$resource=$badSource}}
         $result=@(& $handlerFixture -Context $context)
         Assert-Chrome ($result.Count -eq 1 -and $result[0].Status -eq 'Fail' -and $script:writes -eq 0) 'Handler accepted unverified Chrome completion.'
     }
     Reset-Chrome
     $script:DeviceManagementMemoryBundle=@{Files=@{}}
     $result=@(& $handlerFixture -Context $context)
     Assert-Chrome ($result.Count -eq 1 -and $result[0].Status -eq 'Fail' -and $script:writes -eq 0) 'Missing embedded Chrome script was accepted.'
     foreach($badSelection in @(@{Browser='Firefox'},@{Mode='Audit'},@{ClientType='ViCafe'},@{DeviceType='POS'})) {
         Reset-Chrome
         $script:DeviceManagementMemoryBundle=@{Files=@{$resource=$source}}
         $invalid=[pscustomobject]@{ClientType=$client;DeviceType='KIOSK';Operation='KioskInstallation';Mode='Apply';Browser='Chrome'}
         foreach($key in $badSelection.Keys){$invalid.$key=$badSelection[$key]}
         $result=@(& $handlerFixture -Context $invalid)
         Assert-Chrome ($result.Count -eq 1 -and $result[0].Status -eq 'Fail' -and $script:writes -eq 0 -and $script:prompts.Count -eq 0) 'Invalid browser/client/device/mode reached Chrome setup.'
     }
     Reset-Chrome
     $WhatIfPreference=$true
     try{$result=@(& $handlerFixture -Context $context)}finally{$WhatIfPreference=$false}
     Assert-Chrome ($result.Count -eq 1 -and $result[0].Status -eq 'Unavailable' -and $script:writes -eq 0 -and $script:prompts.Count -eq 0) 'Chrome handler WhatIf started setup.'
     $script:DeviceManagementMemoryBundle=$null
     Write-Output ('PASS: '+$client+' Chrome local/embedded handlers, verified completion, invalid context/resource/failure/WhatIf isolation.')
     Write-Output ('PASS: '+$client+' Chrome detection, inputs, launch arguments, policies, credentials, repeated setup, prerequisites, failure readback, rollback, and WhatIf. No live Windows changes.')
 }
} finally { $env:COMPUTERNAME=$oldComputer }