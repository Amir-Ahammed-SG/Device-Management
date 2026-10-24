# These tests load function definitions and selected source sections only.
# The production entry point is NEVER executed, and Windows operations are mocked.
$script:SubjectPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SaaSKioskThoroughCheckScript.ps1'
$script:SubjectText = [IO.File]::ReadAllText($script:SubjectPath)
$script:ParseTokens = $null
$script:ParseErrors = $null
$script:SubjectAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:SubjectPath, [ref]$script:ParseTokens, [ref]$script:ParseErrors)
$functionDefinitions = $script:SubjectAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Extent.Text }
. ([scriptblock]::Create($functionDefinitions -join "`r`n"))

function Get-SubjectBlock {
    param([string]$StartMarker, [string]$EndMarker)
    $start = $script:SubjectText.IndexOf($StartMarker, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "Missing source marker: $StartMarker" }
    $end = $script:SubjectText.IndexOf($EndMarker, $start + $StartMarker.Length, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw "Missing source marker: $EndMarker" }
    $block = [scriptblock]::Create($script:SubjectText.Substring($start, $end - $start))
    # Helpers were imported above. Do not redefine them and bypass Pester mocks.
    $statements = $block.Ast.EndBlock.Statements | Where-Object {
        $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
    } | ForEach-Object { $_.Extent.Text }
    [scriptblock]::Create($statements -join "`r`n")
}

function Reset-AuditFixture {
    $script:auditRows = [System.Collections.Generic.List[PSObject]]::new()
    $script:sec1Num = 1
    $script:sec1Title = 'Hardware & Peripherals'
    $script:sec3Num = 3
    $script:sec3Title = 'Core Background Services'
    $script:sec4Num = 4
    $script:sec4Title = 'Security, Network & System Integrity'
}

# Pester 3 retains native CIM parameter types in generated mocks. Untyped test
# boundaries allow in-memory fixtures without constructing or contacting CIM.
function Invoke-CimMethod { [CmdletBinding()]param($InputObject, $MethodName) throw 'Unmocked CIM mutation in test' }
function Get-ScheduledTask { [CmdletBinding()]param() throw 'Unmocked scheduled-task read in test' }
function Get-ScheduledTaskInfo { [CmdletBinding()]param($TaskName,$TaskPath) throw 'Unmocked scheduled-task history read in test' }
function Get-NetFirewallRule { [CmdletBinding()]param($AssociatedNetFirewallPortFilter, $PolicyStore) throw 'Unmocked firewall read in test' }
function Get-NetFirewallAddressFilter { [CmdletBinding()]param($AssociatedNetFirewallRule) throw 'Unmocked firewall read in test' }
function Get-NetFirewallApplicationFilter { [CmdletBinding()]param($AssociatedNetFirewallRule) throw 'Unmocked firewall read in test' }
function Get-NetFirewallServiceFilter { [CmdletBinding()]param($AssociatedNetFirewallRule) throw 'Unmocked firewall read in test' }
function Get-NetFirewallInterfaceFilter { [CmdletBinding()]param($AssociatedNetFirewallRule) throw 'Unmocked firewall read in test' }
function Get-NetFirewallInterfaceTypeFilter { [CmdletBinding()]param($AssociatedNetFirewallRule) throw 'Unmocked firewall read in test' }
function Get-NetFirewallSecurityFilter { [CmdletBinding()]param($AssociatedNetFirewallRule) throw 'Unmocked firewall read in test' }

Describe 'Readable account and launcher report' {
    BeforeEach { Reset-AuditFixture }
    It 'reports actual enabled and expiry flags without guessing a blank password' {
        Mock Get-LocalAccount { [pscustomobject]@{ Enabled = $true; PasswordRequired = $false } }
        Mock Test-AccountPasswordNeverExpires { $true }
        Add-ResultEntry 2 'Kiosk' 'User: SELISE-KIOSK' (New-CheckResult 'Pass' 'Existing password retained' 'Old state')
        $script:auditRows[-1].FoundStateHtml | Should Be 'User: Active'
        $script:auditRows[-1].ActionTaken | Should Be 'Password: Not verified<br>Password Never Expires: Enabled'
        $script:auditRows[-1].Shortcut | Should Match 'net user'
    }
    It 'reports disabled users' {
        Mock Get-LocalAccount { [pscustomobject]@{ Enabled = $false } }
        Mock Test-AccountPasswordNeverExpires { $true }
        Add-ResultEntry 2 'Kiosk' 'User: SELISE-KIOSK' (New-CheckResult 'Fail' 'Enable account separately' '')
        $script:auditRows[-1].FoundStateHtml | Should Be 'User: Deactive'
    }
    It 'extracts and escapes static launcher URL details without executing the launcher' {
        $path = Join-Path $TestDrive 'launcher.ps1'
        [IO.File]::WriteAllText($path, 'Start-Process msedge.exe -ArgumentList ''--kiosk "https://kiosk.ordermonkey.com/#/onboarding/login?restaurantId=R%26A&kioskId=K1&host=Front%20Desk"''')
        $result = Add-LauncherReportDetails (New-CheckResult 'Pass' '' '') $path
        $result.StateHtml | Should Match 'Restaurant ID:</span> R&amp;A'
        $result.StateHtml | Should Match 'Host name:</span> Front Desk'
        $result.StateHtml | Should Match 'Kiosk ID:</span> K1'
        $result.Shortcut | Should Match 'notepad'
    }
    It 'does not invent details for missing launchers' {
        $result = Add-LauncherReportDetails (New-CheckResult 'Fail' '' '') (Join-Path $TestDrive 'missing.ps1')
        $result.StateHtml | Should Match 'Restaurant ID:</span> Not detected'
    }
}

Describe 'Read-only launcher host and completion menu' {
    BeforeEach {
        $script:ApplyChanges = $true
        $script:LauncherFixture = Join-Path $TestDrive 'LaunchKiosk.ps1'
        [IO.File]::WriteAllText($script:LauncherFixture, 'Start-Process msedge.exe -ArgumentList ''--kiosk "https://kiosk.ordermonkey.com/#/onboarding/login?restaurantId=R1&kioskId=K1"''')
        Mock Read-Host { '' }
    }
    It 'records missing host and preserves existing IDs in Apply' {
        $before=[IO.File]::ReadAllText($script:LauncherFixture)
        $result=Repair-LauncherDetails -Path $script:LauncherFixture
        $result.Status | Should Be 'Fail'
        $result.LauncherValues['Restaurant ID'] | Should Be 'R1'
        $result.LauncherValues['KIOSK ID'] | Should Be 'K1'
        $result.LauncherValues['Host Name'] | Should Be 'Not detected'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $before
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
        @(Get-ChildItem $TestDrive -Filter '*.bak').Count | Should Be 0
    }
    It 'reports missing host in audit without prompting or changing the file' {
        $script:ApplyChanges=$false
        $before=[IO.File]::ReadAllText($script:LauncherFixture)
        (Repair-LauncherDetails -Path $script:LauncherFixture).Status | Should Be 'Fail'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $before
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'does not prompt or rewrite an already complete URL' {
        $before=[IO.File]::ReadAllText($script:LauncherFixture).Replace('kioskId=K1','kioskId=K1&host=HOST01')
        [IO.File]::WriteAllText($script:LauncherFixture,$before)
        (Repair-LauncherDetails -Path $script:LauncherFixture -Hostname 'HOST01').Status | Should Be 'Pass'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $before
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'records whitespace host without filling it in Apply' {
        $text=[IO.File]::ReadAllText($script:LauncherFixture).Replace('kioskId=K1','kioskId=K1&host=%20')
        [IO.File]::WriteAllText($script:LauncherFixture,$text)
        $result=Repair-LauncherDetails -Path $script:LauncherFixture
        $result.Status | Should Be 'Fail'
        $result.LauncherValues['Host Name'] | Should Be 'Not detected'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $text
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'preserves both obsolete hostname and current host for manual review' {
        $text=[IO.File]::ReadAllText($script:LauncherFixture).Replace('kioskId=K1','kioskId=K1&hostname=OLD&host=CONFIRMED')
        [IO.File]::WriteAllText($script:LauncherFixture,$text)
        $result=Repair-LauncherDetails -Path $script:LauncherFixture
        $result.Status | Should Be 'Fail'
        $result.LauncherValues['Host Name'] | Should Be 'CONFIRMED'
        $result.LauncherValues['URL'] | Should Match 'hostname=OLD&host=CONFIRMED'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $text
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'does not migrate hostname to host in Apply' {
        $text=[IO.File]::ReadAllText($script:LauncherFixture).Replace('kioskId=K1','kioskId=K1&hostname=EXISTING')
        [IO.File]::WriteAllText($script:LauncherFixture,$text)
        $result=Repair-LauncherDetails -Path $script:LauncherFixture
        $result.Status | Should Be 'Fail'
        $result.LauncherValues['URL'] | Should Match 'hostname=EXISTING'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $text
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'flags hostname in audit without changing the URL' {
        $script:ApplyChanges=$false
        $text=[IO.File]::ReadAllText($script:LauncherFixture).Replace('kioskId=K1','kioskId=K1&hostname=OLD&host=CONFIRMED')
        [IO.File]::WriteAllText($script:LauncherFixture,$text)
        (Repair-LauncherDetails -Path $script:LauncherFixture).Status | Should Be 'Fail'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $text
    }
    It 'reports missing host without using a supplied value or writing files' {
        $before=[IO.File]::ReadAllText($script:LauncherFixture)
        $result=Repair-LauncherDetails -Path $script:LauncherFixture -Hostname 'SUPPLIED'
        $result.Status | Should Be 'Fail'
        $result.LauncherValues['Host Name'] | Should Be 'Not detected'
        [IO.File]::ReadAllText($script:LauncherFixture) | Should Be $before
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'does not rewrite an invalid launcher through the full Apply flow' {
        $script:ProfileFixture=Join-Path $TestDrive 'profile'
        $scripts=Join-Path $script:ProfileFixture 'Scripts'
        $startup=Join-Path $script:ProfileFixture 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        $desktop=Join-Path $script:ProfileFixture 'Desktop'
        foreach ($folder in @($scripts,$startup,$desktop)) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
        $launch=Join-Path $scripts 'LaunchKiosk.ps1'
        $before=[IO.File]::ReadAllText($script:LauncherFixture)
        [IO.File]::WriteAllText($launch,$before)
        [IO.File]::WriteAllText((Join-Path $startup 'LaunchKiosk.bat'),'@echo off')
        [IO.File]::WriteAllText((Join-Path $desktop 'Launch Kiosk.lnk'),'fixture')
        Mock Get-KioskProfilePath { $script:ProfileFixture }
        $result=Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK'
        $result.Status | Should Be 'Fail'
        [IO.File]::ReadAllText($launch) | Should Be $before
        [IO.File]::ReadAllText((Join-Path $startup 'LaunchKiosk.bat')) | Should Be '@echo off'
        [IO.File]::ReadAllText((Join-Path $desktop 'Launch Kiosk.lnk')) | Should Be 'fixture'
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'offers main menu and exits the PowerShell session only after leaving the menu loop' {
        $exits=@($script:SubjectAst.FindAll({param($node) $node -is [Management.Automation.Language.ExitStatementAst]},$true))
        $exits.Count | Should Be 1
        $script:SubjectAst.EndBlock.Statements[-1].Extent.Text | Should Be 'exit $global:LASTEXITCODE'
        $script:SubjectText | Should Match '\[3\] Main Menu'
        $script:SubjectText | Should Match '\[0\] Exit'
        $script:SubjectText | Should Match 'while \(\$nextOption -eq ''3''\)'
    }
}

Describe 'Read-only required kiosk URL parameters' {
    BeforeEach { $script:ApplyChanges=$true; Mock Read-Host { throw 'Unexpected prompt' } }
    It 'records duplicate required parameters without deduplicating the URL' {
        foreach ($key in @('restaurantId','kioskId','host')) {
            $value=@{restaurantId='R';kioskId='K';host='H'}[$key]
            $url='https://kiosk.ordermonkey.com/#/onboarding/login?restaurantId=R&kioskId=K&host=H&'+$key+'='+$value
            $result=Resolve-KioskUrl $url
            $result.URL | Should Be $url
            $result.Issues.Count | Should BeGreaterThan 0
        }
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'records conflicts without choosing or asking for a replacement value' {
        foreach ($key in @('restaurantId','kioskId','host')) {
            $url='https://kiosk.ordermonkey.com/#/onboarding/login?restaurantId=R&kioskId=K&host=H&'+$key+'=OTHER'
            $result=Resolve-KioskUrl $url
            $result.URL | Should Be $url
            $result.Issues.Count | Should BeGreaterThan 0
        }
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'does not prompt for conflicts in audit' {
        $script:ApplyChanges=$false
        $url='https://kiosk.ordermonkey.com/#/onboarding/login?restaurantId=R&restaurantId=OTHER&kioskId=K&host=H'
        $result=Resolve-KioskUrl $url
        $result.URL | Should Be $url
        $result.Issues.Count | Should BeGreaterThan 0
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'records parameter spelling differences without normalizing customer data' {
        $url='https://kiosk.ordermonkey.com/#/onboarding/login?RestaurantId=R&KIOSKID=K&HOST=H'
        $result=Resolve-KioskUrl $url
        $result.URL | Should Be $url
        $result.Issues.Count | Should BeGreaterThan 0
    }
}

Describe 'Read-only Startup BAT and shortcut target verification' {
    BeforeEach {
        $script:ApplyChanges=$true
        $script:TargetBatch=Join-Path $TestDrive 'LaunchKiosk.bat'
        $script:TargetLink=Join-Path $TestDrive 'Launch Kiosk.lnk'
        $script:TargetLaunch=Join-Path $TestDrive 'LaunchKiosk.ps1'
        [IO.File]::WriteAllText($script:TargetBatch,'@echo off')
        $shell=New-Object -ComObject WScript.Shell
        $link=$shell.CreateShortcut($script:TargetLink)
        $link.TargetPath=Join-Path $TestDrive 'wrong.bat'
        $link.Arguments='/wrong'
        $link.Save()
    }
    It 'preserves incorrect BAT and desktop targets in Apply' {
        $before=(Get-FileHash -LiteralPath $script:TargetLink).Hash
        { Verify-KioskLaunchTargets $script:TargetBatch $script:TargetLink $script:TargetLaunch } | Should Throw
        [IO.File]::ReadAllText($script:TargetBatch) | Should Be '@echo off'
        (Get-FileHash -LiteralPath $script:TargetLink).Hash | Should Be $before
        @(Get-ChildItem $TestDrive -Filter '*.bak').Count | Should Be 0
    }
    It 'fails audit without rewriting wrong targets' {
        $script:ApplyChanges=$false
        { Verify-KioskLaunchTargets $script:TargetBatch $script:TargetLink $script:TargetLaunch } | Should Throw
        [IO.File]::ReadAllText($script:TargetBatch) | Should Be '@echo off'
    }
    It 'keeps target verification read-only when the desktop shortcut is missing' {
        $batch='powershell.exe -ExecutionPolicy Bypass -File "'+$script:TargetLaunch+'"'
        [IO.File]::WriteAllText($script:TargetBatch,$batch)
        Remove-Item -LiteralPath $script:TargetLink -Force
        { Verify-KioskLaunchTargets $script:TargetBatch $script:TargetLink $script:TargetLaunch } | Should Throw
        [IO.File]::ReadAllText($script:TargetBatch) | Should Be $batch
        Test-Path -LiteralPath $script:TargetLink | Should Be $false
        @(Get-ChildItem $TestDrive -Filter '*.bak').Count | Should Be 0
    }
}

Describe 'Zabbix configured hostname reporting' {
    It 'reads the service configuration rather than the Windows hostname' {
        $path = Join-Path $TestDrive 'agent.conf'
        [IO.File]::WriteAllText($path, "# Hostname=ignored`r`nHostname=OM-CONFIRMED-01")
        (Get-ZabbixConfiguredHostname ('"C:\Agent\agent.exe" --config "' + $path + '"')) | Should Be 'OM-CONFIRMED-01'
    }
    It 'reads hostname from an included configuration file' {
        $path = Join-Path $TestDrive 'agent.conf'
        [IO.File]::WriteAllText($path, 'Include=host.conf')
        [IO.File]::WriteAllText((Join-Path $TestDrive 'host.conf'), 'Hostname=INCLUDED-01')
        (Get-ZabbixConfiguredHostname ('agent.exe -c "' + $path + '"')) | Should Be 'INCLUDED-01'
    }
    It 'does not invent a hostname for a dynamic item' {
        $path = Join-Path $TestDrive 'agent.conf'
        [IO.File]::WriteAllText($path, 'HostnameItem=system.hostname')
        (Get-ZabbixConfiguredHostname ('agent.exe -c "' + $path + '"')) | Should Match 'Dynamic / not verified'
    }
}

Describe 'SELISE-KIOSK unchecked account options' {
    BeforeEach {
        $script:ApplyChanges = $true
        $script:OptionFixture = [ordered]@{ 'User must change password at next logon'=$true; 'User cannot change password'=$true; 'Password never expires'=$true; 'Account disabled'=$true; 'Account is locked out'=$true }
        Mock Get-KioskAccountOptions { $script:OptionFixture }
        Mock Clear-KioskAccountOptions { foreach ($key in @($script:OptionFixture.Keys)) { $script:OptionFixture[$key]=$false } }
    }
    It 'clears and verifies all five options in Apply' {
        $result = Set-KioskAccountOptions 'SELISE-KIOSK'
        $result.Status | Should Be 'Pass'
        @($script:OptionFixture.Values | Where-Object { $_ }).Count | Should Be 0
        Assert-MockCalled Clear-KioskAccountOptions -Scope It -Times 1 -Exactly
    }
    It 'reports checked options without clearing them in Audit' {
        $script:ApplyChanges = $false
        (Set-KioskAccountOptions 'SELISE-KIOSK').Status | Should Be 'Fail'
        Assert-MockCalled Clear-KioskAccountOptions -Scope It -Times 0 -Exactly
    }
    It 'fails if the settings remain checked after Apply' {
        Mock Clear-KioskAccountOptions { }
        (Set-KioskAccountOptions 'SELISE-KIOSK').Status | Should Be 'Fail'
    }
    It 'rejects Admin before the kiosk-only configuration function runs' {
        { Set-KioskAccountOptions 'Admin' } | Should Throw
        Assert-MockCalled Clear-KioskAccountOptions -Scope It -Times 0 -Exactly
    }
    It 'leaves all options unchanged when already unchecked' {
        foreach ($key in @($script:OptionFixture.Keys)) { $script:OptionFixture[$key] = $false }
        (Set-KioskAccountOptions 'SELISE-KIOSK').Status | Should Be 'Pass'
        Assert-MockCalled Clear-KioskAccountOptions -Scope It -Times 0 -Exactly
    }
    It 'reports the reread options and operation error after a partial failure' {
        Mock Clear-KioskAccountOptions {
            $script:OptionFixture['Password never expires'] = $false
            throw 'Unlock account failed'
        }
        $result = Set-KioskAccountOptions 'SELISE-KIOSK'
        $result.Status | Should Be 'Fail'
        $result.AccountOptionsHtml | Should Match 'Password never expires: Unchecked'
        $result.AccountOptionsHtml | Should Match 'Unlock account failed'
    }
}

Describe 'Source safety and parsing' {
    It 'keeps the hosted script free of a UTF-8 BOM for irm pipe iex' {
        $prefix = [IO.File]::ReadAllBytes($script:SubjectPath)
        ($prefix[0] -eq 239 -and $prefix[1] -eq 187 -and $prefix[2] -eq 191) | Should Be $false
    }
    It 'parses successfully in Windows PowerShell 5.1' {
        @($script:ParseErrors).Count | Should Be 0
    }
    It 'exposes explicit Apply and AuditOnly switches and WhatIf support' {
        $parameterNames = @($script:SubjectAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($parameterNames -contains 'Apply') | Should Be $true
        ($parameterNames -contains 'AuditOnly') | Should Be $true
        ($script:SubjectAst.ParamBlock.Attributes.Extent.Text -join ' ') | Should Match 'SupportsShouldProcess'
    }
    It 'never uses ADSI SetPassword to reset an existing password' {
        $passwordResets = @($script:SubjectAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Value -eq 'SetPassword'
        }, $true))
        $passwordResets.Count | Should Be 0
    }
    It 'never passes a Password argument to Set-LocalUser' {
        $passwordUpdates = @($script:SubjectAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Set-LocalUser' -and
            @($node.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -eq 'Password'
            }).Count -gt 0
        }, $true))
        $passwordUpdates.Count | Should Be 0
    }
    It 'does not call Resume-PrintJob without a job ID' {
        $calls = @($script:SubjectAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Resume-PrintJob'
        }, $true))
        foreach ($call in $calls) {
            @($call.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ID'
            }).Count | Should BeGreaterThan 0
        }
    }
}

Describe 'Visible progress and targeted service reads' {
    BeforeEach {
        Reset-AuditFixture
        Mock Write-Host { }
        Mock Write-Progress { }
    }
    It 'prints one aligned result without floating progress or timing noise' {
        Start-AuditStep -Number 1 -Name 'Printers and print queues'
        Add-AuditEntry -SectionNumber 1 -ItemTitle 'Receipt printer' -Status 'Pass'
        Assert-MockCalled Write-Progress -Scope It -Times 0 -Exactly
        Assert-MockCalled Write-Host -Scope It -Times 0 -Exactly -ParameterFilter { "$Object" -match 'elapsed|/14|Kiosk audit' }
        Assert-MockCalled Write-Host -Scope It -Times 1 -Exactly -ParameterFilter { "$Object" -match '\[01\]\s+PASS\s+Receipt printer' }
    }
    It 'queries only the named service instead of enumerating the entire service list' {
        Mock Get-CimInstance { [pscustomobject]@{Name='Zabbix Agent 2';State='Running';StartMode='Auto'} }
        (Get-AuditService -ServiceName 'Zabbix Agent 2').Name | Should Be 'Zabbix Agent 2'
        Assert-MockCalled Get-CimInstance -Scope It -Times 1 -Exactly -ParameterFilter {
            $ClassName -eq 'Win32_Service' -and $Filter -eq "Name='Zabbix Agent 2'" -and $OperationTimeoutSec -eq 30
        }
    }
}

Describe 'Entry mode gates and unsupported POS' {
    BeforeEach {
        Mock Read-Host { '1' }
        $parameterHeader = $script:SubjectText.Substring(0, $script:SubjectAst.ParamBlock.Extent.EndOffset)
        $validation = ($script:SubjectAst.EndBlock.Statements | Select-Object -First 2 | ForEach-Object { $_.Extent.Text }) -join "`r`n"
        $gateStart = $script:SubjectText.IndexOf('$script:ApplyChanges = $false')
        $gateEnd = $script:SubjectText.IndexOf('$runMode =', $gateStart)
        $script:ModeGate = [scriptblock]::Create($parameterHeader + "`r`n" + $validation + "`r`n" +
            $script:SubjectText.Substring($gateStart, $gateEnd - $gateStart) + "`r`nreturn [bool]`$script:ApplyChanges")
    }
    It 'uses audit mode when menu option 1 is selected' {
        (& $script:ModeGate) | Should Be $false
        Assert-MockCalled Read-Host -Scope It -Times 1 -Exactly
    }
    It 'uses apply mode when menu option 2 is selected' {
        Mock Read-Host { '2' }
        (& $script:ModeGate -Confirm:$false) | Should Be $true
    }
    It 'supports Apply selected through Invoke-Expression with no outer PSCmdlet' {
        Mock Read-Host { '2' }
        $PSCmdlet = $null
        (Invoke-Expression $script:ModeGate.ToString()) | Should Be $true
    }
    It 'supports Audit selected through Invoke-Expression' {
        Mock Read-Host { '1' }
        $PSCmdlet = $null
        (Invoke-Expression $script:ModeGate.ToString()) | Should Be $false
    }
    It 'keeps Invoke-Expression read only when WhatIf is enabled' {
        $WhatIfPreference = $true
        Mock Read-Host { throw 'WhatIf must not prompt' }
        (Invoke-Expression $script:ModeGate.ToString()) | Should Be $false
    }
    It 'repeats the menu for blank and invalid entries before accepting a choice' {
        $script:MenuReplies = [Collections.Generic.Queue[string]]::new()
        foreach ($reply in @('', '4', ' 1 ')) { $script:MenuReplies.Enqueue($reply) }
        Mock Read-Host { $script:MenuReplies.Dequeue() }
        (& $script:ModeGate) | Should Be $false
        Assert-MockCalled Read-Host -Scope It -Times 3 -Exactly
    }
    It 'bypasses the menu for explicit switches and WhatIf' {
        Mock Read-Host { throw 'Explicit modes must not prompt' }
        (& $script:ModeGate -AuditOnly) | Should Be $false
        (& $script:ModeGate -Apply -Confirm:$false) | Should Be $true
        (& $script:ModeGate -WhatIf) | Should Be $false
        (& $script:ModeGate -Apply -WhatIf) | Should Be $false
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'keeps explicit AuditOnly read only' { (& $script:ModeGate -AuditOnly) | Should Be $false }
    It 'keeps Apply WhatIf read only' { (& $script:ModeGate -Apply -WhatIf) | Should Be $false }
    It 'allows requested Apply mode' { (& $script:ModeGate -Apply -Confirm:$false) | Should Be $true }
    It 'rejects conflicting modes' { { & $script:ModeGate -Apply -AuditOnly } | Should Throw }
    It 'rejects POS before the apply gate' { { & $script:ModeGate -Apply -DeviceType POS } | Should Throw }
}

Describe 'Audit-only missing configuration never provisions resources' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $false
        Mock New-LocalUser { throw 'Unexpected account creation' }
        Mock Get-KioskProfilePath { $null }
        Mock Add-Type { throw 'Unexpected profile initialization' }
        Mock New-Item { throw 'Unexpected configuration creation' }
        Mock New-ItemProperty { throw 'Unexpected registry write' }
        Mock Remove-ItemProperty { throw 'Unexpected registry deletion' }
        Mock Test-Path { $false }
        Mock Read-Host { throw 'Unexpected configuration prompt' }
    }
    It 'does not create missing accounts in audit-only mode' {
        { New-KioskLocalAccount -UserName 'SELISE-KIOSK' } | Should Throw
        Assert-MockCalled New-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'does not initialize a missing profile or deploy a launcher' {
        { Invoke-KioskLauncherConfiguration -UserName 'SELISE-KIOSK' } | Should Throw
        Assert-MockCalled Add-Type -Scope It -Times 0 -Exactly
        Assert-MockCalled New-Item -Scope It -Times 0 -Exactly
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
    }
    It 'reports missing browser policies without registry writes' {
        (Invoke-BrowserPolicyCheck).Status | Should Be 'Fail'
        Assert-MockCalled New-Item -Scope It -Times 0 -Exactly
        Assert-MockCalled New-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Scope It -Times 0 -Exactly
    }
    It 'does not create a firewall rule during audit' {
        Mock Get-KioskFirewallState { [pscustomobject]@{HasAllow=$false; Verified=$false; Details='Missing allow'} }
        Mock New-NetFirewallRule { throw 'Unexpected firewall mutation' }
        & (Get-SubjectBlock '# 4.1 Inbound Port 5009 Firewall Rule' '# 4.2 Local Admin User Account')
        $script:auditRows[-1].Status | Should Be 'Fail'
        Assert-MockCalled New-NetFirewallRule -Scope It -Times 0 -Exactly
    }
    It 'does not enable a disabled event log during audit' {
        Mock Get-WinEvent { [pscustomobject]@{IsEnabled=$false} }
        & (Get-SubjectBlock '# 1.2 PrintService Event Log' '# GROUP 2:')
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
}

Describe 'Existing account password preservation' {
    BeforeEach {
        $script:ApplyChanges = $true
        $script:ExpiryEnabled = $false
        $script:AccountEnabled = $true
        Mock Get-LocalUser {
            [pscustomobject]@{ Name = $Name; PasswordExpires = $null; Enabled = $script:AccountEnabled }
        }
        Mock Test-AccountPasswordNeverExpires { $script:ExpiryEnabled }
        Mock Set-LocalUser { $script:ExpiryEnabled = $true }
        Mock Enable-LocalUser { throw 'Existing account must not be enabled as a side effect' }
        Mock Add-LocalGroupMember { throw 'Existing account privileges must not be changed as a side effect' }
    }
    It 'sets only PasswordNeverExpires for existing Admin' {
        $result = Set-ExistingAccountExpiry -UserName 'Admin'
        $script:ExpiryEnabled | Should Be $true
        $result.Status | Should Not Be 'Fail'
        Assert-MockCalled Set-LocalUser -Scope It -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Admin' -and $PasswordNeverExpires -eq $true -and $null -eq $Password
        }
        Assert-MockCalled Enable-LocalUser -Scope It -Times 0 -Exactly
        Assert-MockCalled Add-LocalGroupMember -Scope It -Times 0 -Exactly
    }
    It 'preserves the existing kiosk password and disabled state' {
        $script:AccountEnabled = $false
        Set-ExistingAccountExpiry -UserName 'SELISE-KIOSK' | Out-Null
        Assert-MockCalled Set-LocalUser -Scope It -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'SELISE-KIOSK' -and $PasswordNeverExpires -eq $true -and $null -eq $Password
        }
        Assert-MockCalled Enable-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'makes no account changes during an audit' {
        $script:ApplyChanges = $false
        Set-ExistingAccountExpiry -UserName 'Admin' | Out-Null
        Set-ExistingAccountExpiry -UserName 'SELISE-KIOSK' | Out-Null
        Assert-MockCalled Set-LocalUser -Scope It -Times 0 -Exactly
        Assert-MockCalled Enable-LocalUser -Scope It -Times 0 -Exactly
        Assert-MockCalled Add-LocalGroupMember -Scope It -Times 0 -Exactly
    }
    It 'does not rewrite an expiry setting that is already correct' {
        $script:ExpiryEnabled = $true
        $result = Set-ExistingAccountExpiry -UserName 'Admin'
        $result.Status | Should Be 'Pass'
        Assert-MockCalled Set-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'does not claim success if the setting fails to persist' {
        Mock Set-LocalUser { }
        $failed = $false
        try { $result = Set-ExistingAccountExpiry -UserName 'Admin'; $failed = $result.Status -eq 'Fail' }
        catch { $failed = $true }
        $failed | Should Be $true
    }
}

Describe 'Payment and Zabbix observed service outcomes' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $true
        $script:FixtureServiceState = 'Stopped'
        $script:FixtureServiceStart = 'Manual'
        Mock Get-AuditService {
            [pscustomobject]@{ Name = $ServiceName; State = $script:FixtureServiceState; StartMode = $script:FixtureServiceStart }
        }
        Mock Get-Service {
            $service = [pscustomobject]@{ Name = $Name; Status = $script:FixtureServiceState }
            $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status, $Timeout) }
            $service
        }
        Mock Set-Service { $script:FixtureServiceStart = 'Auto' }
        Mock Start-Service { $script:FixtureServiceState = 'Running' }
        Mock Read-ServiceRecoveryPolicy { $true }
        Mock Invoke-ServiceRecoveryRepair { $true }
        Mock Get-ServiceRecoveryDetails { [pscustomobject]@{ First='Restart the service'; Second='Restart the service'; Subsequent='Take No Action'; Verified=$true; Error='' } }
    }
    It 'reports Fail when payment cannot start' {
        Mock Start-Service { throw 'Fixture payment start failure' }
        Invoke-RequiredServiceCheck -ServiceName 'AspPayment' -ItemTitle 'Payment fixture' -ItemSub 'Payment' | Out-Null
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
    It 'reports Fail when Zabbix start returns but service remains stopped' {
        Mock Start-Service { }
        Invoke-RequiredServiceCheck -ServiceName 'Zabbix Agent 2' -ItemTitle 'Zabbix fixture' -ItemSub 'Monitoring' | Out-Null
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
    It 'reports Pass only after refreshed running and Automatic state is observed' {
        Invoke-RequiredServiceCheck -ServiceName 'AspPayment' -ItemTitle 'Payment fixture' -ItemSub 'Payment' | Out-Null
        $script:auditRows[-1].Status | Should Be 'Pass'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Running'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Auto'
    }
    It 'reports Fail when crash recovery repair fails' {
        $script:FixtureServiceState = 'Running'
        $script:FixtureServiceStart = 'Auto'
        Mock Read-ServiceRecoveryPolicy { $false }
        Mock Invoke-ServiceRecoveryRepair { $false }
        Invoke-RequiredServiceCheck -ServiceName 'AspPayment' -ItemTitle 'Payment fixture' -ItemSub 'Payment' | Out-Null
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
    It 'does not modify stopped services during an audit' {
        $script:ApplyChanges = $false
        Invoke-RequiredServiceCheck -ServiceName 'AspPayment' -ItemTitle 'Payment fixture' -ItemSub 'Payment' | Out-Null
        Invoke-RequiredServiceCheck -ServiceName 'Zabbix Agent 2' -ItemTitle 'Zabbix fixture' -ItemSub 'Monitoring' | Out-Null
        Assert-MockCalled Set-Service -Scope It -Times 0 -Exactly
        Assert-MockCalled Start-Service -Scope It -Times 0 -Exactly
        Assert-MockCalled Invoke-ServiceRecoveryRepair -Scope It -Times 0 -Exactly
    }
}

Describe 'Printer status without queue mutation' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges=$true
        $script:PrinterFixtureStatus='Paused'
        Mock Get-Printer { [pscustomobject]@{Name='Receipt';PrinterStatus=$script:PrinterFixtureStatus;WorkOffline=$false;KeepPrintedJobs=$true} }
        Mock Get-CimInstance { [pscustomobject]@{Name='Receipt';PrinterStatus=3;WorkOffline=$false} }
        Mock Invoke-CimMethod { throw 'Queue mutation is not allowed' }
    }
    It 'reports a paused printer without resuming it during Apply' {
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Fail'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Printer status:</span> Error'
        Assert-MockCalled Invoke-CimMethod -Scope It -Times 0 -Exactly
    }
    It 'does not invoke queue methods when the printer is paused' {
        Mock Invoke-CimMethod { [pscustomobject]@{ReturnValue=5} }
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Fail'
        $script:PrinterFixtureStatus | Should Be 'Paused'
        Assert-MockCalled Invoke-CimMethod -Scope It -Times 0 -Exactly
    }
    It 'repairs only document retention while preserving a paused status' {
        $script:KeepJobs=$false
        Mock Get-Printer { [pscustomobject]@{Name='Receipt';PrinterStatus='Paused';KeepPrintedJobs=$script:KeepJobs} }
        Mock Set-Printer { $script:KeepJobs=$true }
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Fail'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Printer status:</span> Error'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Keep printed documents:</span> Enabled'
        Assert-MockCalled Set-Printer -Scope It -Times 1 -Exactly
        Assert-MockCalled Invoke-CimMethod -Scope It -Times 0 -Exactly
    }
    It 'does not resume a paused printer during an audit' {
        $script:ApplyChanges=$false
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Fail'
        Assert-MockCalled Invoke-CimMethod -Scope It -Times 0 -Exactly
    }
    It 'treats a printer that is actively printing as healthy' {
        $script:PrinterFixtureStatus='Printing'
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Pass'
        Assert-MockCalled Invoke-CimMethod -Scope It -Times 0 -Exactly
    }
}

Describe 'Printer retention and readable reporting' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $true
        $script:KeepJobs = $false
        Mock Get-Printer { [pscustomobject]@{Name='BIXOLON BK5-3';PrinterStatus='Normal';KeepPrintedJobs=$script:KeepJobs} }
        Mock Get-CimInstance { [pscustomobject]@{Name='BIXOLON BK5-3';PrinterStatus=3;DetectedErrorState=0;WorkOffline=$false;KeepPrintedJobs=$script:KeepJobs} }
        Mock Set-Printer { $script:KeepJobs = $true }
    }
    It 'enables and verifies Keep printed documents in Apply Mode' {
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Pass'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Printer status:</span> Idle'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Keep printed documents:</span> Enabled'
        $script:auditRows[-1].ActionTaken | Should Be 'Enabled Keep printed documents'
        Assert-MockCalled Set-Printer -Scope It -Times 1 -Exactly -ParameterFilter { $Name -eq 'BIXOLON BK5-3' -and $KeepPrintedJobs }
    }
    It 'reports Disabled without changing settings in Audit Mode' {
        $script:ApplyChanges = $false
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Fail'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Keep printed documents:</span> Disabled'
        Assert-MockCalled Set-Printer -Scope It -Times 0 -Exactly
    }
    It 'reports Fail when the retention setting does not persist' {
        Mock Set-Printer { }
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].Status | Should Be 'Fail'
        $script:auditRows[-1].FoundStateHtml | Should Match 'Disabled'
    }
    It 'keeps an already enabled setting and removes technical fields from the report' {
        $script:KeepJobs = $true
        & (Get-SubjectBlock '# 1.1 Multi-Printer Discovery' '# 1.2 PrintService Event Log')
        $script:auditRows[-1].FoundStateHtml | Should Not Match 'WorkOffline|DetectedErrorState|Driver:'
        $script:auditRows[-1].ActionTaken | Should Be 'No changes needed'
        Assert-MockCalled Set-Printer -Scope It -Times 0 -Exactly
    }
    It 'maps printing, hardware errors, and offline states to readable labels' {
        (Get-PrinterHealth -Printer ([pscustomobject]@{PrinterStatus='Printing'}) -CimPrinter ([pscustomobject]@{PrinterStatus=4;DetectedErrorState=0})).State | Should Be 'Active'
        (Get-PrinterHealth -Printer ([pscustomobject]@{PrinterStatus='Normal'}) -CimPrinter ([pscustomobject]@{PrinterStatus=3;DetectedErrorState=4})).State | Should Be 'Error'
        (Get-PrinterHealth -Printer ([pscustomobject]@{PrinterStatus='Offline'}) -CimPrinter ([pscustomobject]@{PrinterStatus=7})).State | Should Be 'Offline'
        (Get-PrinterHealth -Printer ([pscustomobject]@{PrinterStatus=128}) -CimPrinter ([pscustomobject]@{})).State | Should Be 'Offline'
    }
}

Describe 'Simple inbound TCP firewall rule presence' {
    BeforeEach {
        $script:FirewallProtocol = 'TCP'
        $script:FirewallEnabled = 'True'
        $script:FirewallDirection = 'Inbound'
        $script:FirewallAction = 'Allow'
        $script:FirewallProfile = 'Any'
        $script:FirewallRemoteAddress = 'Any'
        Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' } }
        Mock Get-NetFirewallProfile {
            [pscustomobject]@{ Name = 'Private'; Enabled = 'True'; AllowInboundRules = 'True'; AllowLocalFirewallRules = 'True' }
        }
        Mock Get-NetFirewallPortFilter {
            [pscustomobject]@{ Protocol = $script:FirewallProtocol; LocalPort = '5009'; RemotePort = 'Any' }
        }
        Mock Get-NetFirewallRule {
            [pscustomobject]@{
                Name = 'Fixture'; DisplayName = 'Fixture'; Enabled = $script:FirewallEnabled
                Direction = $script:FirewallDirection; Action = $script:FirewallAction
                Profile = $script:FirewallProfile; PrimaryStatus = 'OK'; EnforcementStatus = 'Enforced'; PolicyStoreSourceType = 'Local'
            }
        }
        Mock Get-NetFirewallAddressFilter { [pscustomobject]@{ LocalAddress = 'Any'; RemoteAddress = $script:FirewallRemoteAddress } }
        Mock Get-NetFirewallApplicationFilter { [pscustomobject]@{ Program = 'Any'; Package = 'Any' } }
        Mock Get-NetFirewallServiceFilter { [pscustomobject]@{ Service = 'Any' } }
        Mock Get-NetFirewallInterfaceFilter { [pscustomobject]@{ InterfaceAlias = 'Any' } }
        Mock Get-NetFirewallInterfaceTypeFilter { [pscustomobject]@{ InterfaceType = 'Any' } }
        Mock Get-NetFirewallSecurityFilter {
            [pscustomobject]@{ Authentication = 'NotRequired'; Encryption = 'NotRequired'; LocalUser = 'Any'; RemoteUser = 'Any'; RemoteMachine = 'Any' }
        }
    }
    It 'accepts an effective unrestricted enabled inbound TCP allow rule' {
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $true
    }
    It 'rejects a disabled rule' {
        $script:FirewallEnabled = 'False'
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $false
    }
    It 'rejects an outbound rule' {
        $script:FirewallDirection = 'Outbound'
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $false
    }
    It 'rejects a UDP rule on the same port' {
        $script:FirewallProtocol = 'UDP'
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $false
    }
    It 'rejects a Block rule on the same port' {
        $script:FirewallAction = 'Block'
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $false
    }
    It 'checks rule presence without a profile applicability audit' {
        $script:FirewallProfile = 'Public'
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $true
        Assert-MockCalled Get-NetConnectionProfile -Scope It -Times 0 -Exactly
    }
    It 'checks rule presence without a remote address scope audit' {
        $script:FirewallRemoteAddress = '192.0.2.10'
        (Get-KioskFirewallState -Port 5009).Verified | Should Be $true
        Assert-MockCalled Get-NetFirewallAddressFilter -Scope It -Times 0 -Exactly
    }
    It 'recognizes a port within a configured range' {
        Test-FirewallPortMatch -Ports @('443', '5000-5010') -Port 5009 | Should Be $true
        Test-FirewallPortMatch -Ports @('443', '5000-5010') -Port 6000 | Should Be $false
    }
}

Describe 'Firewall apply create or skip' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $true
        $script:RulePresent = $false
        Mock Get-KioskFirewallState { [pscustomobject]@{HasAllow=$script:RulePresent; Verified=$script:RulePresent} }
        Mock Get-NetFirewallRule { @() }
        Mock New-NetFirewallRule { $script:RulePresent = $true }
        Mock Set-NetFirewallRule { $script:RulePresent = $true }
    }
    It 'creates and verifies a missing rule' {
        & (Get-SubjectBlock '# 4.1 Inbound Port 5009 Firewall Rule' '# 4.2 Local Admin User Account')
        Assert-MockCalled New-NetFirewallRule -Scope It -Times 1 -Exactly -ParameterFilter { $Protocol -eq 'TCP' -and $LocalPort -eq 5009 -and $Direction -eq 'Inbound' -and $Action -eq 'Allow' }
        $script:auditRows[-1].FoundStateHtml | Should Be 'Available'
        $script:auditRows[-1].Status | Should Be 'Pass'
    }
    It 'skips all mutations for an available rule' {
        $script:RulePresent = $true
        & (Get-SubjectBlock '# 4.1 Inbound Port 5009 Firewall Rule' '# 4.2 Local Admin User Account')
        Assert-MockCalled New-NetFirewallRule -Scope It -Times 0 -Exactly
        Assert-MockCalled Set-NetFirewallRule -Scope It -Times 0 -Exactly
    }
    It 'repairs the existing managed rule instead of adding a duplicate' {
        Mock Get-NetFirewallRule { [pscustomobject]@{Name='SELISE-Kiosk-TCP-5009-Inbound'} }
        & (Get-SubjectBlock '# 4.1 Inbound Port 5009 Firewall Rule' '# 4.2 Local Admin User Account')
        Assert-MockCalled Set-NetFirewallRule -Scope It -Times 1 -Exactly
        Assert-MockCalled New-NetFirewallRule -Scope It -Times 0 -Exactly
        $script:auditRows[-1].Status | Should Be 'Pass'
    }
    It 'fails when rule creation does not pass readback' {
        Mock New-NetFirewallRule { }
        & (Get-SubjectBlock '# 4.1 Inbound Port 5009 Firewall Rule' '# 4.2 Local Admin User Account')
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
}

Describe 'Windows Update requested disable and verified outcome' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $true
        $script:UpdateState = 'Running'
        $script:UpdateStartup = 'Auto'
        Mock Get-AuditService { [pscustomobject]@{ Name = 'wuauserv'; State = $script:UpdateState; StartMode = $script:UpdateStartup } }
        Mock Get-Service {
            $service = [pscustomobject]@{ Name = 'wuauserv' }
            $service | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($Status, $Timeout) }
            $service
        }
        Mock Set-Service { $script:UpdateStartup = 'Disabled' }
        Mock Stop-Service { $script:UpdateState = 'Stopped' }
    }
    It 'forcibly stops and disables the update service in apply mode' {
        & (Get-SubjectBlock '# 3.3 Windows Update Service' '# GROUP 4:')
        $script:auditRows[-1].Status | Should Be 'Pass'
        Assert-MockCalled Stop-Service -Scope It -Times 1 -Exactly -ParameterFilter { $Name -eq 'wuauserv' -and $Force }
        Assert-MockCalled Set-Service -Scope It -Times 1 -Exactly -ParameterFilter { $StartupType -eq 'Disabled' }
    }
    It 'reports Fail when the update service is still running' {
        Mock Stop-Service { }
        & (Get-SubjectBlock '# 3.3 Windows Update Service' '# GROUP 4:')
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
    It 'reports Fail if disabling startup throws' {
        Mock Set-Service { throw 'Fixture denied disable' }
        & (Get-SubjectBlock '# 3.3 Windows Update Service' '# GROUP 4:')
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
    It 'does not stop or disable updates during an audit' {
        $script:ApplyChanges = $false
        & (Get-SubjectBlock '# 3.3 Windows Update Service' '# GROUP 4:')
        Assert-MockCalled Stop-Service -Scope It -Times 0 -Exactly
        Assert-MockCalled Set-Service -Scope It -Times 0 -Exactly
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
}

Describe 'Auto-login transaction and password preservation' {
    BeforeEach {
        $script:ApplyChanges = $true
        $script:LoginFailOnce = $null
        $script:LoginValues = @{
            AutoAdminLogon = @{ Value = '1'; Kind = 'String' }
            DefaultUserName = @{ Value = 'PreviousUser'; Kind = 'String' }
            DefaultDomainName = @{ Value = 'PREVIOUS'; Kind = 'String' }
            DefaultPassword = @{ Value = 'fixture-old-password'; Kind = 'String' }
            AutoLogonCount = @{ Value = 7; Kind = 'DWord' }
        }
        $script:LoginFixtureKey = [pscustomobject]@{}
        $script:LoginFixtureKey | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @($script:LoginValues.Keys) }
        $script:LoginFixtureKey | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
            param($Name, $Default, $Options)
            if ($script:LoginValues.ContainsKey($Name)) { return $script:LoginValues[$Name].Value }
            return $Default
        }
        $script:LoginFixtureKey | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value {
            param($Name)
            [Microsoft.Win32.RegistryValueKind]$script:LoginValues[$Name].Kind
        }
        Mock Get-Item { $script:LoginFixtureKey }
        Mock Get-ItemProperty {
            $properties = @{}
            foreach ($key in $script:LoginValues.Keys) { $properties[$key] = $script:LoginValues[$key].Value }
            [pscustomobject]$properties
        }
        Mock Get-ItemPropertyValue { $script:LoginValues[$Name].Value }
        Mock New-ItemProperty {
            if ($Name -eq $script:LoginFailOnce) {
                $script:LoginFailOnce = $null
                throw 'Fixture registry write denied'
            }
            $script:LoginValues[$Name] = @{ Value = $Value; Kind = [string]$PropertyType }
        }
        Mock Remove-ItemProperty { foreach ($entryName in @($Name)) { $script:LoginValues.Remove($entryName) } }
        Mock Test-InteractiveCredentials { }
        Mock Set-LocalUser { throw 'An auto-login change must not change an account password' }
        Mock Get-LocalAccount { [pscustomobject]@{ Name = 'SELISE-KIOSK'; Enabled = $true } }
        Mock Read-Host { throw 'Audit must not prompt for a credential' }
        $script:FixturePassword = ConvertTo-SecureString 'fixture-current-password' -AsPlainText -Force
    }
    It 'checks credentials before changing any auto-login registry value' {
        Mock Test-InteractiveCredentials { throw 'Fixture invalid current credential' }
        { Set-VerifiedAutoLogin -Path 'FixtureRegistry' -UserName 'SELISE-KIOSK' -Password $script:FixturePassword } | Should Throw
        Assert-MockCalled New-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Scope It -Times 0 -Exactly
        $script:LoginValues.AutoAdminLogon.Value | Should Be '1'
    }
    It 'uses an empty password for existing kiosk accounts without prompting' {
        $result = Set-KioskAutoLogin -UserName 'SELISE-KIOSK'
        $result.Status | Should Be 'Pass'
        $script:LoginValues.DefaultPassword.Value | Should Be ''
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
        Assert-MockCalled Test-InteractiveCredentials -Scope It -Times 1 -Exactly -ParameterFilter { $Password.Length -eq 0 }
        Assert-MockCalled Set-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'allows only blank-password restriction 1327 to require manual verification' {
        $guard = $script:SubjectAst.Find({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -like 'if ($code -eq 1327*'
        }, $true)
        $block = [scriptblock]::Create($guard.Extent.Text)
        $Password = [Security.SecureString]::new()
        $code = 1327
        (& $block) | Should Be 'ManualVerificationRequired'
        $code = 1326
        (& $block) | Should BeNullOrEmpty
        $code = 1327
        $Password = $script:FixturePassword
        (& $block) | Should BeNullOrEmpty
    }
    It 'configures blank auto-login with explicit manual sign-in verification' {
        Mock Test-InteractiveCredentials { 'ManualVerificationRequired' }
        $result = Set-VerifiedAutoLogin -Path 'FixtureRegistry' -UserName 'SELISE-KIOSK' -Password ([Security.SecureString]::new())
        $result.Status | Should Be 'Pass'
        $result.Action | Should Match 'credentials were not validated'
        $result.Action | Should Match 'Manually verify sign-in after reboot'
        $script:LoginValues.DefaultPassword.Value | Should Be ''
        $script:LoginValues.AutoAdminLogon.Value | Should Be '1'
        Assert-MockCalled Set-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'restores the prior credentials, enable state and value types after a write failure' {
        $script:LoginFailOnce = 'DefaultPassword'
        { Set-VerifiedAutoLogin -Path 'FixtureRegistry' -UserName 'SELISE-KIOSK' -Password $script:FixturePassword } | Should Throw
        $script:LoginValues.DefaultUserName.Value | Should Be 'PreviousUser'
        $script:LoginValues.DefaultDomainName.Value | Should Be 'PREVIOUS'
        $script:LoginValues.DefaultPassword.Value | Should Be 'fixture-old-password'
        $script:LoginValues.AutoAdminLogon.Value | Should Be '1'
        $script:LoginValues.AutoLogonCount.Value | Should Be 7
        $script:LoginValues.AutoLogonCount.Kind | Should Be 'DWord'
        Assert-MockCalled Set-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'restores an absent password registry value as absent after partial failure' {
        $script:LoginValues.Remove('DefaultPassword')
        Mock Get-ItemPropertyValue { '0' }
        { Set-VerifiedAutoLogin -Path 'FixtureRegistry' -UserName 'SELISE-KIOSK' -Password $script:FixturePassword } | Should Throw
        $script:LoginValues.ContainsKey('DefaultPassword') | Should Be $false
        $script:LoginValues.AutoLogonCount.Value | Should Be 7
        $script:LoginValues.AutoAdminLogon.Value | Should Be '1'
    }
    It 'applies and verifies the current password without changing the account password' {
        $result = Set-VerifiedAutoLogin -Path 'FixtureRegistry' -UserName 'SELISE-KIOSK' -Password $script:FixturePassword
        $result.Status | Should Be 'Pass'
        $script:LoginValues.AutoAdminLogon.Value | Should Be '1'
        $script:LoginValues.DefaultUserName.Value | Should Be 'SELISE-KIOSK'
        $script:LoginValues.DefaultPassword.Value | Should Be 'fixture-current-password'
        $script:LoginValues.ContainsKey('AutoLogonCount') | Should Be $false
        Assert-MockCalled Test-InteractiveCredentials -Scope It -Times 1 -Exactly
        Assert-MockCalled Set-LocalUser -Scope It -Times 0 -Exactly
    }
    It 'preserves existing matching auto-login without asking for the password' {
        $script:LoginValues.DefaultPassword.Value = ''
        $script:LoginValues.Remove('AutoLogonCount')
        $script:LoginValues.DefaultUserName.Value = 'SELISE-KIOSK'
        $script:LoginValues.DefaultDomainName.Value = $env:COMPUTERNAME
        $result = Set-KioskAutoLogin -UserName 'SELISE-KIOSK'
        $result.Status | Should Be 'Pass'
        Assert-MockCalled New-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
        Assert-MockCalled Test-InteractiveCredentials -Scope It -Times 0 -Exactly
    }
    It 'preserves existing auto-login with configured password and missing domain' {
        $script:LoginValues.DefaultPassword.Value = 'ExistingSecret123'
        $script:LoginValues.Remove('AutoLogonCount')
        $script:LoginValues.Remove('DefaultDomainName')
        $script:LoginValues.DefaultUserName.Value = 'SELISE-KIOSK'
        $script:LoginValues.AutoAdminLogon.Value = '1'
        $result = Set-KioskAutoLogin -UserName 'SELISE-KIOSK'
        $result.Status | Should Be 'Pass'
        $result.Action | Should Match 'Existing auto-login preserved'
        Assert-MockCalled New-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Test-InteractiveCredentials -Scope It -Times 0 -Exactly
    }
    It 'does not prompt, validate credentials or write registry during an audit' {
        $script:ApplyChanges = $false
        Set-KioskAutoLogin -UserName 'SELISE-KIOSK' | Out-Null
        Assert-MockCalled Read-Host -Scope It -Times 0 -Exactly
        Assert-MockCalled Test-InteractiveCredentials -Scope It -Times 0 -Exactly
        Assert-MockCalled New-ItemProperty -Scope It -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Scope It -Times 0 -Exactly
    }
}

Describe 'Performance counter rebuild exit status' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $true
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'reports Pass for lodctr exit code zero' {
        & (Get-SubjectBlock '# 4.4 lodctr /R Performance Counter Rebuild' '# END COMPONENT CHECKS')
        $script:auditRows[-1].Status | Should Be 'Pass'
        Assert-MockCalled Start-Process -Scope It -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'lodctr.exe' -and $ArgumentList -eq '/R' }
    }
    It 'reports Fail for lodctr nonzero exit code' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } }
        & (Get-SubjectBlock '# 4.4 lodctr /R Performance Counter Rebuild' '# END COMPONENT CHECKS')
        $script:auditRows[-1].Status | Should Be 'Fail'
        $script:auditRows[-1].ActionTaken | Should Match '5'
    }
    It 'reports Fail if lodctr cannot launch' {
        Mock Start-Process { throw 'Fixture launch failure' }
        & (Get-SubjectBlock '# 4.4 lodctr /R Performance Counter Rebuild' '# END COMPONENT CHECKS')
        $script:auditRows[-1].Status | Should Be 'Fail'
    }
    It 'skips the rebuild without reporting a pass during an audit' {
        $script:ApplyChanges = $false
        & (Get-SubjectBlock '# 4.4 lodctr /R Performance Counter Rebuild' '# END COMPONENT CHECKS')
        $script:auditRows[-1].Status | Should Be 'Bypass'
        Assert-MockCalled Start-Process -Scope It -Times 0 -Exactly
    }
}

Describe 'Nmap executable reporting' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $false
        $script:NpcapPresent = $true
        $script:NpcapState = 'Running'
        Mock Get-NmapExecutable { 'FixtureNmap.exe' }
        Mock Get-NmapVersion { [pscustomobject]@{ Version = '7.fixture'; Output = 'Nmap version 7.fixture Npcap'; UsesNpcap = $true } }
        Mock Get-CimInstance {
            if ($ClassName -eq 'Win32_OperatingSystem') { [pscustomobject]@{ Caption = 'Windows 11' } }
            elseif ($ClassName -eq 'Win32_SystemDriver' -and $script:NpcapPresent) {
                [pscustomobject]@{ Name = 'npcap'; State = $script:NpcapState; StartMode = 'System' }
            }
        }
        Mock Test-Path { $true }
        Mock Start-Process { throw 'No installer should be launched in this fixture' }
        Mock Invoke-WebRequest { throw 'No installer should be downloaded in this fixture' }
    }
    It 'reports only Nmap and never queries a packet driver' {
        & (Get-SubjectBlock '# 4.3 Nmap Tool' '# 4.4 lodctr /R')
        $script:auditRows.Count | Should Be 1
        $script:auditRows[0].ItemTitle | Should Be 'Nmap Diagnostic Tool'
        $script:auditRows[0].Status | Should Be 'Pass'
        Assert-MockCalled Get-CimInstance -Scope It -Times 0 -Exactly -ParameterFilter { $ClassName -eq 'Win32_SystemDriver' }
    }
    It 'does not claim executable readiness after version command failure' {
        Mock Get-NmapVersion { throw 'Fixture invalid Nmap executable' }
        & (Get-SubjectBlock '# 4.3 Nmap Tool' '# 4.4 lodctr /R')
        ($script:auditRows | Where-Object { $_.ItemTitle -eq 'Nmap Diagnostic Tool' }).Status | Should Be 'Fail'
    }
    It 'does not install missing Nmap during an audit' {
        Mock Get-NmapExecutable { $null }
        & (Get-SubjectBlock '# 4.3 Nmap Tool' '# 4.4 lodctr /R')
        Assert-MockCalled Start-Process -Scope It -Times 0 -Exactly
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 0 -Exactly
        ($script:auditRows | Where-Object { $_.ItemTitle -eq 'Nmap Diagnostic Tool' }).Status | Should Be 'Fail'
    }
}

Describe 'Thorough Check Payment Service detail reporting' {
    It 'reads the Payment Service version and configuration fields shown by the dedicated audit' {
        $json = @'
{
  // Comments are accepted by the deployed Payment Service configuration.
  "ServicePort": 5009,
  "IPAddress": "127.0.0.1",
  "PaymentService": "SIX",
  "PaymentConfiguration": {
    "SixTerminals": [
      { "KioskId": "Kiosk-1", "TerminalId": "31396444", "Callback": "https://example.test/payment" }
    ]
  },
  "ScheduleConfiguration": {
    "Schedules": [
      { "Provider": "SendPing", "IsEnabled": false },
      { "Provider": "KitchenTicketPrint", "IsKioskPrintingEnabled": false }
    ]
  },
  "Print": {
    "PrinterName": "EPSON TM-m30 Receipt5",
    "KioskPrinterName": "EPSON TM-m30 Receipt"
  }
}
'@
        $configuration = ConvertFrom-ThoroughPaymentJson $json
        $lines = (Get-ThoroughPaymentConfigurationAuditLines $configuration) -join "`n"
        $lines | Should Match 'ServicePort: 5009'
        $lines | Should Match 'IPAddress: 127\.0\.0\.1'
        $lines | Should Match 'PaymentService: SIX'
        $lines | Should Match 'Terminal 1 KioskId: Kiosk-1'
        $lines | Should Match 'Terminal 1 TerminalId: 31396444'
        $lines | Should Match 'IsEnabled: False'
        $lines | Should Match 'IsKioskPrintingEnabled: False'
        $lines | Should Match 'PrinterName: EPSON TM-m30 Receipt5'
        $lines | Should Match 'KioskPrinterName: EPSON TM-m30 Receipt'
    }

    It 'HTML-encodes Payment Service configuration values before report output' {
        $html = ConvertTo-ThoroughPaymentReportHtml @('  PrinterName: Receipt <Primary> & Backup')
        $html | Should Match 'Receipt &lt;Primary&gt; &amp; Backup'
        $html | Should Not Match '<Primary>'
    }

    It 'adds the Payment Configuration row to both SaaS and Subway Thorough Check reports' {
        foreach ($name in @('SaaSKioskThoroughCheckScript.ps1', 'SubwayKioskThoroughCheck.ps1')) {
            $source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) $name))
            $source | Should Match "ItemTitle 'Payment Configuration'"
            $source | Should Match 'ConvertFrom-ThoroughPaymentJson'
            $source | Should Match 'Get-ThoroughPaymentVersionDetails'
            $source | Should Match 'no configuration values changed'
        }
    }
}

Describe 'Approved legacy payment selection' {
    BeforeEach {
        Reset-AuditFixture
        $script:ApplyChanges = $true
        $script:SelectedService = $null
        $script:PaymentFixtureRoot = Join-Path $TestDrive 'PaymentService'
        New-Item -ItemType Directory -Path $script:PaymentFixtureRoot -Force | Out-Null
        $script:PaymentFixtureExecutable = Join-Path $script:PaymentFixtureRoot 'KioskPaymentMiddleware.exe'
        [IO.File]::WriteAllText($script:PaymentFixtureExecutable, '')
        [IO.File]::WriteAllText((Join-Path $script:PaymentFixtureRoot 'version.txt'), '9.0.0.0')
        [IO.File]::WriteAllText((Join-Path $script:PaymentFixtureRoot 'appsettings.json'), '{"ServicePort":5009,"IPAddress":"127.0.0.1","PaymentService":"SIX","PaymentConfiguration":{"SixTerminals":[{"KioskId":"Kiosk-1","TerminalId":"31396444"}]},"ScheduleConfiguration":{"Schedules":[]},"Print":{}}')
        $fixtureCommandLine = '"' + $script:PaymentFixtureExecutable + '"'
        $script:PaymentFixtures = @(
            [pscustomobject]@{Name='AspPaymentOld';DisplayName='Old';PathName=$fixtureCommandLine;State='Stopped';StartMode='Disabled'},
            [pscustomobject]@{Name='AspPaymentCurrent';DisplayName='Current';PathName=$fixtureCommandLine;State='Running';StartMode='Auto'},
            [pscustomobject]@{Name='AspPaymentOther';DisplayName='Other';PathName=$fixtureCommandLine;State='Running';StartMode='Auto'}
        )
        Mock Get-CimInstance { $script:PaymentFixtures }
        Mock Get-AuditService { $script:PaymentFixtures | Where-Object { $_.Name -eq $ServiceName } }
        Mock Invoke-RequiredServiceCheck {
            $script:SelectedService = $ServiceName
            Add-AuditEntry 3 'Services' $ServiceName '' '' '' 'Pass' 'Verified'
        }
        Mock Get-PaymentExecutableVersion {
            if ($Service.Name -eq 'AspPaymentCurrent') { [version]'2.0.0.0' } else { [version]'1.0.0.0' }
        }
        Mock Stop-Service { ($script:PaymentFixtures | Where-Object { $_.Name -eq $Name }).State = 'Stopped' }
        Mock Get-Service {
            $service = [pscustomobject]@{ Name = $Name }
            $service | Add-Member ScriptMethod WaitForStatus { param($Status, $Timeout) }
            $service
        }
        Mock Set-Service { ($script:PaymentFixtures | Where-Object { $_.Name -eq $Name }).StartMode = 'Manual' }
    }
    It 'keeps latest running service and stops all others with Manual startup' {
        & (Get-SubjectBlock '# 3.1 Payment Middleware' '# 3.2 Zabbix Agent 2')
        $script:SelectedService | Should Be 'AspPaymentCurrent'
        $script:PaymentFixtures[0].StartMode | Should Be 'Manual'
        $script:PaymentFixtures[2].StartMode | Should Be 'Manual'
        Assert-MockCalled Set-Service -Scope It -Times 1 -Exactly -ParameterFilter { $Name -eq 'AspPaymentOther' }
        ($script:auditRows | Where-Object { $_.ItemTitle -like 'AspPaymentOther*' }).FoundStateHtml | Should Match 'Stopped'
        ($script:auditRows | Where-Object { $_.ItemTitle -like 'AspPaymentOther*' }).Status | Should Be 'Offline'
        ($script:auditRows | Where-Object ItemTitle -EQ 'AspPaymentCurrent').FoundStateHtml | Should Match 'Version:</span> 9\.0\.0\.0'
        ($script:auditRows | Where-Object ItemTitle -EQ 'Payment Configuration').Status | Should Be 'Pass'
        ($script:auditRows | Where-Object ItemTitle -EQ 'Payment Configuration').FoundStateHtml | Should Match 'Terminal 1 KioskId:</span> Kiosk-1'
        Assert-MockCalled Stop-Service -Scope It -Times 1 -Exactly -ParameterFilter { $Name -eq 'AspPaymentOther' }
    }
    It 'does not change legacy startup during audit' {
        $script:ApplyChanges = $false
        & (Get-SubjectBlock '# 3.1 Payment Middleware' '# 3.2 Zabbix Agent 2')
        Assert-MockCalled Set-Service -Scope It -Times 0 -Exactly
        Assert-MockCalled Stop-Service -Scope It -Times 0 -Exactly
        $script:PaymentFixtures[2].StartMode | Should Be 'Auto'
    }
    It 'preserves secondary services when primary verification fails' {
        Mock Invoke-RequiredServiceCheck { Add-AuditEntry 3 'Services' $ServiceName '' '' '' 'Fail' 'Start failed' }
        & (Get-SubjectBlock '# 3.1 Payment Middleware' '# 3.2 Zabbix Agent 2')
        Assert-MockCalled Stop-Service -Scope It -Times 0 -Exactly
        Assert-MockCalled Set-Service -Scope It -Times 0 -Exactly
    }
    It 'fails safely on equal executable versions without service changes' {
        Mock Get-PaymentExecutableVersion { [version]'2.0' }
        & (Get-SubjectBlock '# 3.1 Payment Middleware' '# 3.2 Zabbix Agent 2')
        $script:auditRows[-1].Status | Should Be 'Fail'
        Assert-MockCalled Invoke-RequiredServiceCheck -Scope It -Times 0 -Exactly
        Assert-MockCalled Stop-Service -Scope It -Times 0 -Exactly
    }
    It 'prefers a single running service even if a stopped service is newer' {
        $script:PaymentFixtures[2].State = 'Stopped'
        (Select-PaymentPrimary $script:PaymentFixtures).Name | Should Be 'AspPaymentCurrent'
        Assert-MockCalled Get-PaymentExecutableVersion -Scope It -Times 0 -Exactly
    }
    It 'selects the highest executable version when no service is running' {
        $script:PaymentFixtures | ForEach-Object { $_.State = 'Stopped' }
        (Select-PaymentPrimary $script:PaymentFixtures).Name | Should Be 'AspPaymentCurrent'
    }
    It 'reports stop failures with actual running state' {
        Mock Stop-Service { throw 'Stop denied' }
        & (Get-SubjectBlock '# 3.1 Payment Middleware' '# 3.2 Zabbix Agent 2')
        $row = $script:auditRows | Where-Object { $_.ItemTitle -like 'AspPaymentOther*' }
        $row.Status | Should Be 'Fail'
        $row.FoundStateHtml | Should Match 'Running'
    }
}

Describe 'Partial report and truthful summary' {
    BeforeEach {
        Reset-AuditFixture
        Mock Save-ThoroughReportBundle {
            $snapshot=@($Snapshots | Where-Object Mode -eq $PreferredMode)[0]
            $document=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($snapshot.HtmlBase64))
            [IO.File]::WriteAllText($Path,$document,(New-Object Text.UTF8Encoding($false)))
            $Path
        }
        $script:ApplyChanges = $true
        $outerTry = $script:SubjectAst.FindAll({ param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report' }, $true) | Select-Object -Last 1
        $script:RenderBlock = [scriptblock]::Create(($outerTry.Finally.Statements | ForEach-Object { $_.Extent.Text }) -join "`r`n")
        $script:outputFolder = $TestDrive
        $script:reportPath = Join-Path $TestDrive 'report.html'
        $script:runMode = 'AUDIT ONLY'
        $script:runId = 'fixture-run'
        $script:reportHostname = 'CONFIRMED-HOST'
        $script:clientLocation = '<fixture client>'
        $script:deviceType = 'KIOSK'
        Add-AuditEntry -SectionNumber 1 -SectionTitle 'Fixture' -ItemTitle '<printer>' -ItemSub 'Fixture' -Status 'Offline' -ActionTaken 'Check hardware'
        Add-AuditEntry -SectionNumber 4 -SectionTitle 'Fixture' -ItemTitle 'Counter' -ItemSub 'Fixture' -Status 'Bypass' -ActionTaken 'Not run'
    }
    It 'converts report HTML into readable terminal text' {
        Convert-ReportHtmlToTerminalText '<div><span class="kv-label">User:</span> Active</div><div>Password: No</div>' | Should Be 'User: Active; Password: No'
    }
    It 'accepts lowercase report choices and repeats invalid input' {
        $script:choices = [Collections.Queue]::new()
        $script:choices.Enqueue('maybe'); $script:choices.Enqueue('y')
        Mock Read-Host { $script:choices.Dequeue() }
        Read-AuditReportChoice | Should Be $true
        Assert-MockCalled Read-Host -Scope It -Times 2 -Exactly
    }
    It 'does not create an HTML report when audit report generation is declined' {
        $script:ApplyChanges = $false
        Mock Write-Host {}
        Mock Read-AuditReportChoice { $false }
        & $script:RenderBlock
        Test-Path -LiteralPath $script:reportPath | Should Be $false
        Assert-MockCalled Write-Host -Scope It -Times 0 -Exactly -ParameterFilter { "$Object" -match 'AUDIT RESULTS|Required Configuration|Findings' }
        Assert-MockCalled Read-AuditReportChoice -Scope It -Times 1 -Exactly
    }
    It 'writes report output even in WhatIf without reporting offline and skipped checks as passes' {
        $WhatIfPreference = $true
        & $script:RenderBlock
        $html = Get-Content -LiteralPath $script:reportPath -Raw
        $html | Should Not Match '<strong>Mode:</strong>'
        $html | Should Not Match '<strong>Run:</strong>'
        $html | Should Match '<th>Hostname</th><td>CONFIRMED-HOST</td>'
        $html | Should Match '&lt;fixture client&gt;'
        $html | Should Match '&lt;printer&gt;'
        $html | Should Match '<th>Component</th><th>Shortcut / Command</th><th>Findings</th><th>Applied</th>'
        $html | Should Match '<strong>Manual Action Required</strong><div>Check hardware</div>'
        $html | Should Match '<strong>Manual Action Required</strong><div>Not run</div>'
        $html | Should Not Match '<th>Status</th>|<th>Required Configuration</th>|>Pass</span>'
        $html | Should Match '<th>Report ID</th><td>OMK-[0-9]{6}</td>'
        $html | Should Match '<th>Findings</th>'
        $html | Should Not Match 'Overall result|VERIFICATION RECORD|summary-grid|stat-card'
    }
    It 'preserves partial results and records an unexpected exception' {
        $outerTry = $script:SubjectAst.FindAll({ param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Extent.Text -match 'Writing HTML report' }, $true) | Select-Object -Last 1
        $catchText = ($outerTry.CatchClauses[0].Body.Statements | ForEach-Object { $_.Extent.Text }) -join "`r`n"
        & ([scriptblock]::Create("try { throw 'Fixture interruption' } catch { $catchText }"))
        & $script:RenderBlock
        $html = Get-Content -LiteralPath $script:reportPath -Raw
        $html | Should Match 'Partial run; earlier changes may already have been applied'
        $html | Should Match 'Unexpected interruption'
        $html | Should Match '&lt;printer&gt;'
    }
}

