[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)][ValidateSet('KioskLauncherTask','ZabbixInstaller','NmapInstaller')][string]$ToolId,
    [switch]$MenuRun,
    [string]$ProjectRoot
)
$ErrorActionPreference='Stop'

function Get-KioskMaintenanceFunctionBlock {
    param([string]$Source,[string]$Tool)
    # Import only named definitions from the trusted shared engine. Never run its
    # top-level Audit/Apply statements or accept operator-supplied code/paths.
    $names=@('Test-CanApply','Get-ThoroughDeviceHostname')
    switch($Tool){
        'KioskLauncherTask' {$names+=@('New-CheckResult','Get-LocalAccount','Get-KioskProfilePath','ConvertTo-ReportDefinitionHtml','Get-KioskLaunchTaskHistory','Get-KioskLaunchTaskInventory','Get-KioskLaunchTaskContext','Test-KioskLaunchTaskIdentity','Read-KioskLaunchTaskArguments','Get-KioskLaunchTaskFields','Get-KioskLaunchTaskRequirements','Read-KioskLaunchTaskSnapshot','Open-KioskLaunchTaskScheduler','New-KioskLaunchTaskDefinition','Register-MissingKioskLaunchTask','Assert-KioskLaunchTaskBaseline','Get-KioskLaunchTaskCheck')}
        'ZabbixInstaller' {$names+=@('Get-ZabbixConfiguredHostname','New-ZabbixInstallCommand','Invoke-ZabbixAgentInstall')}
        'NmapInstaller' {$names+=@('Get-NmapExecutable','Get-NmapVersion','Get-LocalNmapInstaller')}
        default {throw 'Unknown maintenance tool.'}
    }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The shared maintenance implementation failed syntax validation.'}
    $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    $definitions=@(foreach($name in $names){
        $matches=@($functions | Where-Object Name -CEQ $name)
        if($matches.Count -ne 1){throw ('Shared maintenance function is missing or ambiguous: '+$name)}
        $matches[0].Extent.Text
    })
    [scriptblock]::Create(($definitions -join [Environment]::NewLine))
}

function Test-KioskMaintenanceAdministrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
}

function Read-KioskMaintenanceApproval {
    param([string]$Message)
    do{
        $answer=([string](Read-Host ($Message+' [y/N]'))).Trim()
        if($answer -in @('','n','N')){return $false}
        if($answer -in @('y','Y')){return $true}
        Write-Host 'Enter Y or N.' -ForegroundColor Yellow
    }while($true)
}

function New-KioskMaintenanceResult {
    param([string]$Status,[string]$Message,[bool]$ReturnToMenu=$false)
    Write-Host ('  '+$Message) -ForegroundColor $(if($Status -eq 'Fail'){'Yellow'}elseif($Status -eq 'Pass'){'Green'}else{'Gray'})
    [pscustomobject]@{Status=$Status;Message=$Message;ReturnToMenu=$ReturnToMenu}
}

function Get-KioskMaintenanceAccount {
    $candidates=@(foreach($user in @(Get-LocalUser -ErrorAction Stop | Where-Object Enabled)){
        $profile=Get-KioskProfilePath $user.Name
        if($profile -and (Test-Path -LiteralPath (Join-Path $profile 'Scripts\LaunchKiosk.ps1') -PathType Leaf -ErrorAction Stop)){$user}
    })
    if(-not $candidates.Count){throw 'No enabled local user with an existing Scripts\LaunchKiosk.ps1 was found. Install the kiosk launcher first.'}
    if($candidates.Count -eq 1){Write-Host ('  Kiosk user: '+$candidates[0].Name);return $candidates[0]}
    for($i=0;$i -lt $candidates.Count;$i++){Write-Host ('  [{0}] {1}' -f ($i+1),$candidates[$i].Name)}
    do{
        $choice=([string](Read-Host 'Select kiosk user (0 to cancel)')).Trim()
        if($choice -eq '0'){return $null}
        [int]$number=0
        if([int]::TryParse($choice,[ref]$number) -and $number -ge 1 -and $number -le $candidates.Count){return $candidates[$number-1]}
        Write-Host 'Select one of the listed users.' -ForegroundColor Yellow
    }while($true)
}

function Save-KioskMaintenanceTaskBackup {
    param([string]$Xml,[string]$Folder='C:\Thorough Check\Restore Points')
    [void][IO.Directory]::CreateDirectory($Folder)
    $path=Join-Path $Folder ('Launch-Kiosk-'+[guid]::NewGuid().ToString('N')+'.xml')
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Xml)
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($bytes)){throw 'Task backup readback failed; no task repair was started.'}
    $path
}

function Get-KioskMaintenanceZabbix {
    $services=@(Get-CimInstance -ClassName Win32_Service -Filter "Name='Zabbix Agent 2'" -ErrorAction Stop)
    if($services.Count -gt 1){throw 'Zabbix Agent 2 service identity is ambiguous.'}
    if($services.Count){return $services[0]}
    return $null
}

function Test-KioskMaintenanceZabbix {
    param($Service,[string]$Hostname)
    if(-not $Service){throw 'Zabbix installer returned but Zabbix Agent 2 service is missing.'}
    if($Service.State -ne 'Running' -or $Service.StartMode -ne 'Auto'){throw 'Zabbix is installed but Running / Automatic service settings were not verified. Use Thorough Check for service repairs.'}
    $configured=Get-ZabbixConfiguredHostname -CommandLine $Service.PathName
    if($configured -cne $Hostname){throw 'Zabbix is installed but its configured hostname does not match the Windows DNS hostname. Use Thorough Check for configuration repairs.'}
}

function Invoke-KioskMaintenanceTool {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Tool,[string]$Root)
    $script:ApplyChanges=$false
    try{
        if(-not [Environment]::Is64BitProcess -or -not (Test-KioskMaintenanceAdministrator)){throw 'Run Device Management in elevated 64-bit Windows PowerShell.'}
        switch($Tool){
            'KioskLauncherTask' {
                $account=Get-KioskMaintenanceAccount
                if(-not $account){return New-KioskMaintenanceResult 'Skipped' 'Cancelled; no task changed.' $true}
                $context=Get-KioskLaunchTaskContext $account.Name $account
                if(-not $context.Ready){throw $context.Reason}
                $tokens=$null;$parseErrors=$null
                [void][Management.Automation.Language.Parser]::ParseFile($context.ScriptPath,[ref]$tokens,[ref]$parseErrors)
                if($parseErrors.Count){throw 'The existing kiosk launcher has invalid PowerShell syntax; no task changed.'}
                $tasks=@(Get-KioskLaunchTaskInventory)
                if($tasks.Count -gt 1 -or ($tasks.Count -eq 1 -and $tasks[0].TaskPath -cne '\')){throw 'Multiple or non-root Launch Kiosk tasks require manual review; no task changed.'}
                $snapshot=Read-KioskLaunchTaskSnapshot $tasks $context
                if(-not $snapshot.Verified){throw $snapshot.Reason}
                if($snapshot.Passed){return New-KioskMaintenanceResult 'Pass' 'Launch Kiosk task already matches the required configuration; no changes needed.'}
                if($tasks.Count -eq 1 -and $snapshot.Fields['Run As'] -ine $context.UserId){throw 'The existing task belongs to another or unverified account; no task changed.'}
                Write-Host ('  Launcher: '+$context.ScriptPath)
                Write-Host '  Trigger: selected user logon; delay: 5 seconds; run level: Limited.'
                $xml=if($tasks.Count){[string](Export-ScheduledTask -TaskName 'Launch Kiosk' -TaskPath '\' -ErrorAction Stop)}else{''}
                if(-not $PSCmdlet.ShouldProcess('Launch Kiosk','Create or repair the selected user logon task')){return New-KioskMaintenanceResult 'Skipped' 'No task changes applied.' $true}
                if(-not (Read-KioskMaintenanceApproval 'Create or repair this Launch Kiosk task?')){return New-KioskMaintenanceResult 'Skipped' 'Cancelled; no task changed.' $true}
                $latest=@(Get-KioskLaunchTaskInventory)
                if($latest.Count -ne $tasks.Count -or ($latest.Count -eq 1 -and ([string]$latest[0].TaskPath -cne '\' -or [string](Export-ScheduledTask -TaskName 'Launch Kiosk' -TaskPath '\' -ErrorAction Stop) -cne $xml))){throw 'Task inventory changed during confirmation; no task changed.'}
                $backup=if($xml){Save-KioskMaintenanceTaskBackup $xml}else{''}
                if($backup){Write-Host ('  Task backup: '+$backup)}
                $script:ApplyChanges=$true
                $result=Get-KioskLaunchTaskCheck -UserName $account.Name -Account $account -ExpectedTaskXml $xml -RequireUnchangedTask
                if($result.Status -notin @('Pass','Remediated')){
                    $reason=$result.Action.Replace('Existing tasks were preserved.','Task state requires manual verification.').Replace('No existing task was replaced.','Task state could not be fully verified.')
                    throw ('Task creation/repair was not verified. '+$reason+$(if($backup){' Original task XML backup: '+$backup+'. Restore it manually if necessary; unknown task state was preserved.'}))
                }
                return New-KioskMaintenanceResult 'Pass' $result.Action
            }
            'ZabbixInstaller' {
                $hostname=Get-ThoroughDeviceHostname
                [void](New-ZabbixInstallCommand $hostname)
                Write-Host ('  Monitoring hostname: '+$hostname)
                $existing=Get-KioskMaintenanceZabbix
                if($existing){Test-KioskMaintenanceZabbix $existing $hostname;return New-KioskMaintenanceResult 'Pass' 'Existing Zabbix Agent 2 service and hostname verified; no reinstall or configuration change.'}
                if(-not $PSCmdlet.ShouldProcess('Zabbix Agent 2','Install the missing monitoring agent')){return New-KioskMaintenanceResult 'Skipped' 'No installation started.' $true}
                if(-not (Read-KioskMaintenanceApproval 'Install Zabbix Agent 2?')){return New-KioskMaintenanceResult 'Skipped' 'Cancelled; no installation started.' $true}
                if(Get-KioskMaintenanceZabbix){throw 'Zabbix appeared during confirmation; installation was not started. Run the tool again to inspect it.'}
                if((Get-ThoroughDeviceHostname) -cne $hostname){throw 'Windows DNS hostname changed during confirmation; installation was not started.'}
                $script:ApplyChanges=$true
                Invoke-ZabbixAgentInstall $hostname
                Test-KioskMaintenanceZabbix (Get-KioskMaintenanceZabbix) $hostname
                return New-KioskMaintenanceResult 'Pass' 'Zabbix Agent 2 installed; Running / Automatic service and configured hostname verified.'
            }
            'NmapInstaller' {
                $installed=Get-NmapExecutable
                if($installed){$version=Get-NmapVersion $installed;return New-KioskMaintenanceResult 'Pass' ('Existing Nmap '+$version.Version+' verified; no upgrade or reinstall.')}
                $windows10=(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption -match 'Windows 10'
                $installer=$null;$winget=$null
                if($windows10){
                    if(-not $Root){throw 'Windows 10 needs the verified local Packages\Nmap installer. Run the local DeviceManagement copy; this installer is not included in the CDN bundle.'}
                    $installer=Get-LocalNmapInstaller -ScriptDirectory $Root
                    $installerHash=(Get-FileHash -LiteralPath $installer -Algorithm SHA256 -ErrorAction Stop).Hash
                }
                else{
                    $winget=Get-Command winget.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
                    if(-not $winget){throw 'winget is unavailable; install Nmap manually from https://nmap.org/download.html'}
                }
                if(-not $PSCmdlet.ShouldProcess('Nmap','Install the missing network diagnostic tool')){return New-KioskMaintenanceResult 'Skipped' 'No installation started.' $true}
                if(-not (Read-KioskMaintenanceApproval 'Install Nmap?')){return New-KioskMaintenanceResult 'Skipped' 'Cancelled; no installation started.' $true}
                if(Get-NmapExecutable){throw 'Nmap appeared during confirmation; installation was not started. Run the tool again to verify it.'}
                if($windows10){
                    if((Get-LocalNmapInstaller -ScriptDirectory $Root) -cne $installer -or (Get-FileHash -LiteralPath $installer -Algorithm SHA256 -ErrorAction Stop).Hash -ine $installerHash){throw 'The verified Nmap package changed during confirmation.'}
                    Write-Host '  Complete the Nmap setup wizard to continue.' -ForegroundColor Cyan
                    $process=Start-Process -FilePath $installer -Wait -PassThru -ErrorAction Stop
                    if($process.ExitCode -ne 0){throw ('Nmap setup returned exit code '+$process.ExitCode)}
                }else{
                    & $winget.Source install --id Insecure.Nmap --exact --source winget --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --no-upgrade 2>&1 | Out-Null
                    if($LASTEXITCODE -ne 0){throw ('Nmap installer returned exit code '+$LASTEXITCODE)}
                }
                $installed=Get-NmapExecutable
                if(-not $installed){throw 'Installer returned but nmap.exe is still missing.'}
                $version=Get-NmapVersion $installed
                return New-KioskMaintenanceResult 'Pass' ('Nmap '+$version.Version+' installed and version verified. No network scan was run.')
            }
            default {throw 'Unknown maintenance tool.'}
        }
    }catch{return New-KioskMaintenanceResult 'Fail' $_.Exception.Message}
    finally{$script:ApplyChanges=$false}
}

$bundle=Get-Variable -Name DeviceManagementMemoryBundle -ValueOnly -ErrorAction SilentlyContinue
if($bundle){
    $resource='DeviceManagement/KioskThoroughCheck.ps1'
    if(-not $bundle.Files.ContainsKey($resource)){throw 'The embedded shared maintenance implementation is missing.'}
    $source=$bundle.Files[$resource]
    $ProjectRoot=''
}else{
    if(-not $ProjectRoot){$ProjectRoot=Split-Path $PSScriptRoot -Parent}
    $source=[IO.File]::ReadAllText((Join-Path $ProjectRoot 'KioskThoroughCheck.ps1'))
}
. (Get-KioskMaintenanceFunctionBlock -Source $source -Tool $ToolId)
$result=Invoke-KioskMaintenanceTool -Tool $ToolId -Root $ProjectRoot
if($MenuRun){return $result}
if($result.Status -eq 'Fail'){exit 1}
exit 0
