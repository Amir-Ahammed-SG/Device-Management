$projectRoot = Split-Path $PSScriptRoot -Parent
# Exercise definitions and selected guarded blocks only, with in-memory accounts.
# Never run either production script or contact a Windows account/service API.
$ErrorActionPreference = 'Stop'
$root = Split-Path $projectRoot -Parent
function Assert-Check { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1', 'SubwayKioskThoroughCheck.ps1')) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $sourceName), [ref]$tokens, [ref]$parseErrors)
    $sourceText=[IO.File]::ReadAllText((Join-Path $root $sourceName))
    Assert-Check ($parseErrors.Count -eq 0) 'PowerShell parsing failed'
    $definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
    . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
    $script:fixtureUsers = @()
    $script:fixtureProperties = @{}
    $script:fixtureWrites = [Collections.Generic.List[string]]::new()
    function Get-LocalUser { [CmdletBinding()]param() $script:fixtureUsers }
    function Get-LocalAdministratorSidSet {
        $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @('Admin', 'Administrator', 'SupportOperator')) { [void]$set.Add($name) }
        return ,$set
    }
    function Get-LocalAccountProperties { param($UserName) $script:fixtureProperties[$UserName] }
    function Set-LocalUser {
        [CmdletBinding()]param($Name, $PasswordNeverExpires, $UserMayChangePassword)
        $script:fixtureWrites.Add($Name)
        $script:fixtureProperties[$Name].PasswordNeverExpires = $PasswordNeverExpires
        $script:fixtureProperties[$Name].UserCannotChangePassword = -not $UserMayChangePassword
    }
    # Route the new narrow writer through this fixture's existing mock; never bind ADSI.
    function Open-ThoroughLocalAccount {throw 'Live Windows account access is forbidden in this fixture.'}
    function Enable-LocalAccountPasswordFlags {
        param([string]$UserName,[bool]$PasswordNeverExpires,[bool]$UserCannotChangePassword)
        $settings=@{Name=$UserName}
        if($PasswordNeverExpires){$settings.PasswordNeverExpires=$true}
        if($UserCannotChangePassword){$settings.UserMayChangePassword=$false}
        Set-LocalUser @settings
        [pscustomobject]@{Changed=$true}
    }

    foreach ($applyMode in @($false, $true)) {
        $script:ApplyChanges = $applyMode
        function Get-KioskAutoLoginUserName {return $null}
        function Get-KioskProfilePath {param($UserName) return $null}
        $script:fixtureUsers = @()
        $missing = Get-KioskAccountCheck
        Assert-Check ($null -eq $missing.Account -and $missing.Result.Status -eq 'Fail') 'Missing kiosk account not reported as failure'
        Assert-Check ($missing.Result.StateHtml -match 'Missing') 'Missing account finding absent'
        $missingView=Get-AccountReportView ([pscustomobject]@{ ItemTitle='KIOSK Account'; FoundStateHtml=$missing.Result.StateHtml })
        Assert-Check ($missingView.FindingsHtml -ceq 'Account Missing. Please create manually.') 'Missing account Findings does not request manual creation'
        Assert-Check ($missingView.ExpectedHtml -match 'Account Name:</span> SELISE or SELISE-KIOSK' -and $missingView.ExpectedHtml -match 'Account Privilege:') 'Missing account identity absent from Expected'
        $missingAdmin = Get-AdministrativeAccountCheck
        Assert-Check ($missingAdmin.Status -eq 'Fail' -and $missingAdmin.StateHtml -match 'Missing') 'Missing administrator account finding absent'
        Assert-Check ($script:fixtureWrites.Count -eq 0) 'Missing account triggered a mutation'

        $script:fixtureUsers = @(foreach ($name in @('sElIsE', 'SeLiSe-KiOsK', 'SELISE-POS', 'Admin', 'Administrator', 'SupportOperator')) {
            $script:fixtureProperties[$name] = [pscustomobject]@{ PasswordNeverExpires=$false; UserCannotChangePassword=$false }
            [pscustomobject]@{ Name=$name; Enabled=$true; SID=[pscustomobject]@{ Value=$name } }
        })
        $grouped = Get-KioskAccountCheck
        Assert-Check ($grouped.Account.Name -ieq 'SELISE-KIOSK') 'Preferred case-insensitive kiosk account not selected'
        Assert-Check ($grouped.Result.StateHtml -match 'sElIsE' -and $grouped.Result.StateHtml -match 'SeLiSe-KiOsK') 'Grouped account properties lost'
        Assert-Check ($grouped.Result.StateHtml -notmatch 'SELISE-POS') 'Unrelated device account included in KIOSK group'
        $availableView=Get-AccountReportView ([pscustomobject]@{ ItemTitle='KIOSK Account'; FoundStateHtml=$grouped.Result.StateHtml })
        Assert-Check ($availableView.FindingsHtml -match 'Account Name:</span> sElIsE' -and $availableView.FindingsHtml -match 'Account Name:</span> SeLiSe-KiOsK') 'Grouped kiosk Findings lost an account name'
        Assert-Check ($availableView.ExpectedHtml -notmatch 'config-item-title|<hr>' -and [regex]::Matches($availableView.ExpectedHtml,'class="kv-label"').Count -eq 5) 'Kiosk requirements were repeated or numbered'
        Assert-Check ($availableView.ExpectedHtml -match 'sElIsE' -and $availableView.ExpectedHtml -match 'SeLiSe-KiOsK' -and $availableView.ExpectedHtml -match 'Account Privilege:') 'Account identity lost from Expected'
        Assert-Check ($availableView.FindingsHtml -match 'Account Status:</span> Active' -and $availableView.FindingsHtml -match 'Account Privilege:' -and $availableView.ExpectedHtml -match 'Account Privilege:</span> Standard or Administrator') 'Kiosk report privilege or status missing'
        foreach ($label in @('Password Never Expires','User Cannot Change Password')) {Assert-Check ($availableView.ExpectedHtml -match ($label+':</span> Enabled') -and $availableView.FindingsHtml -match ($label+':</span> '+$(if ($applyMode) {'Enabled'} else {'Disabled'}))) 'Kiosk property reference or actual value missing'}
        Assert-Check (($grouped.Result.Status -eq 'Pass') -eq $applyMode) 'Kiosk account status does not reflect the required properties'
        Assert-Check ($script:fixtureWrites.Count -eq $(if ($applyMode) {2} else {0})) 'Kiosk property writes do not match the selected mode'
        $admins = Get-AdministrativeAccountCheck
        Assert-Check ($admins.StateHtml -match 'Admin' -and $admins.StateHtml -match 'Administrator' -and $admins.StateHtml -match 'SupportOperator') 'Grouped admin properties lost'
        $adminView=Get-AccountReportView ([pscustomobject]@{ ItemTitle='Administrative Accounts'; FoundStateHtml=$admins.StateHtml })
        Assert-Check ($adminView.ExpectedHtml -notmatch 'config-item-title|<hr>' -and [regex]::Matches($adminView.ExpectedHtml,'class="kv-label"').Count -eq 5) 'Administrative requirements were repeated or numbered'
        $adminFields=@([regex]::Matches($adminView.FindingsHtml,'<span class="kv-label">([^<]+):</span>') | ForEach-Object { $_.Groups[1].Value })
        $oneAdminFields='Account Name|Account Privilege|Account Status|Password Never Expires|User Cannot Change Password'
        Assert-Check (($adminFields -join '|') -ceq (@($oneAdminFields,$oneAdminFields,$oneAdminFields) -join '|')) 'Administrative Findings field order incorrect'
        Assert-Check ($adminView.FindingsHtml -match 'Account Name:</span> Administrator' -and $adminView.FindingsHtml -match 'Account Privilege:</span> Administrator' -and $adminView.FindingsHtml -match 'Account Status:</span> Active') 'Administrative identity or status missing'
        if ($applyMode) {
            Assert-Check ($script:fixtureWrites.Count -eq 5 -and $script:fixtureWrites -notcontains 'SELISE-POS' -and $script:fixtureWrites -contains 'sElIsE' -and $script:fixtureWrites -contains 'SeLiSe-KiOsK') 'Apply modified incorrect accounts'
        } else { Assert-Check ($script:fixtureWrites.Count -eq 0) 'Audit changed an account' }
        $script:fixtureUsers = @($script:fixtureUsers | Where-Object { $_.Name -ieq 'SELISE' })
        $alias = Get-KioskAccountCheck
        Assert-Check ($alias.Account.Name -ieq 'SELISE') 'SELISE fallback account not selected'
        $script:fixtureWrites.Clear()

        # Execute the actual dependency guard, with traps at every operation.
        $guard = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($null -ne $kioskAccount) {') -and $node.Extent.Text.Contains("Start-AuditStep 4 'Kiosk profile and launcher'") }, $true) | Select-Object -First 1
        Assert-Check ($null -ne $guard) 'Kiosk dependency guard missing'
        $script:dependentCalls = [Collections.Generic.List[string]]::new()
        function Start-AuditStep { param($Number, $Name) $script:dependentCalls.Add($Name) }
        function Invoke-KioskLauncherConfiguration { param($UserName, $Restaurant, $Kiosk, $Hostname) $script:dependentCalls.Add('launcher'); throw 'Test trap' }
        function Get-KioskProfilePath { param($UserName) $script:dependentCalls.Add('startup'); throw 'Test trap' }
        function Test-KioskAutoLogin { param($UserName) $script:dependentCalls.Add('auto-login'); throw 'Test trap' }
        function Invoke-BrowserPolicyCheck { $script:dependentCalls.Add('policy'); throw 'Test trap' }
        function Add-ResultEntry { param($Section, $Title, $Item, $Result) $script:dependentCalls.Add($Item) }
        function Add-AuditEntry { param($SectionNumber, $SectionTitle, $ItemTitle, $ItemSub, $Shortcut, $FoundStateHtml, $Status, $ActionTaken) $script:dependentCalls.Add($ItemTitle) }
        $kioskAccount = $null
        & ([scriptblock]::Create($guard.Extent.Text))
        Assert-Check ($script:dependentCalls.Count -eq 0) 'Missing kiosk user triggered a dependent check or report row'
        $kioskAccount = [pscustomobject]@{ Name='SELISE-KIOSK' }
        $kioskUser = $kioskAccount.Name
        & ([scriptblock]::Create($guard.Extent.Text))
        foreach ($operation in @('launcher','startup','auto-login','policy')) { Assert-Check ($script:dependentCalls -contains $operation) "Existing kiosk user did not run $operation check" }
    }

    # Exercise the actual provider guard while trapping all firewall operations.
    $start=$sourceText.IndexOf("Start-AuditStep 10 'Required inbound firewall rules'",[StringComparison]::Ordinal)
    $end=$sourceText.IndexOf('# 4.2 Local Administrative Accounts',$start,[StringComparison]::Ordinal)
    Assert-Check ($start -ge 0 -and $end -gt $start) 'Firewall provider guard boundary missing'
    $firewallBlock=[scriptblock]::Create($sourceText.Substring($start,$end-$start))
    function Start-AuditStep { param($Number,$Name) }
    function Invoke-KioskFirewallPortCheck { param($Port,$RulePurpose) $script:checkedPorts.Add([int]$Port) }
    function Add-AuditEntry { throw 'Non-applicable firewall placeholder was generated' }
    foreach ($mode in @($false,$true)) {
        $script:ApplyChanges=$mode
        foreach ($provider in @('NETS','NEXIDE','SIX','PRINT','Not detected','Not configured')) {
            $script:checkedPorts=[Collections.Generic.List[int]]::new()
            $detectedPaymentProvider=$provider
            & $firewallBlock
            $ports=if ($provider -in @('NETS','NEXIDE')) { '5009,4100,4101,4102,4103' } else { '5009' }
            Assert-Check (($script:checkedPorts -join ',') -eq $ports) "Wrong firewall check scope for provider $provider"
        }
    }

    # Provider-specific data must survive in the exact point-7 groups, including
    # explicit false values, empty terminal IDs and URLs containing colons.
    foreach ($provider in @('SIX', 'NETS', 'NEXIDE', 'PRINT')) {
        foreach ($scheduleShape in @('Nested', 'Direct', 'Array')) {
            $schedule = [pscustomobject]@{ Provider='KitchenTicketPrint'; IsKioskPrintingEnabled=$false; IsEnabled=$false }
            $allSchedules=@($schedule)
            if($provider -in @('SIX','NETS','NEXIDE')){$allSchedules+=@([pscustomobject]@{Provider=$provider;IsEnabled=$false})}
            $scheduleConfig = switch ($scheduleShape) { 'Nested' { [pscustomobject]@{ Schedules=$allSchedules } } 'Direct' { $schedule } 'Array' { ,$allSchedules } }
            $config = [pscustomobject]@{
                PaymentService=$provider
                PaymentConfiguration=[pscustomobject]@{
                    SixTerminals=@([pscustomobject]@{ KioskId='SIX-KIOSK'; TerminalId='12345'; Currency='CHF'; LogDirectory='C:\Sample\Logs'; IsDeferredInitiation=$false })
                    NetsTerminals=@([pscustomobject]@{ PosId='POS'; KioskId='NETS-KIOSK'; TerminalIPAddress='192.0.2.43'; TerminalId=''; Currency='CHF'; Language='en'; IsSetupEnabled=$false })
                }
                ScheduleConfiguration=$scheduleConfig
                Print=[pscustomobject]@{ PrinterName='Kitchen <Printer>'; KioskPrinterName='Receipt' }
                MonitoringServiceBaseUrl='https://example.test/monitor'; CmsGatewayBaseUrl='https://example.test/cms'; OrderServiceBaseUrl='https://example.test/orders'
            }
            $lines = @(Get-ThoroughPaymentConfigurationAuditLines -Configuration $config -ServiceName 'FixturePayment' -ConfigurationPath 'C:\Fixture\appsettings.json')
            $text = $lines -join "`n"
            Assert-Check ($text -match 'IsKioskPrintingEnabled: False' -and $text -match 'IsEnabled: False') "Schedule values lost for $scheduleShape"
            if ($provider -eq 'SIX') { Assert-Check ($text -match 'SixTerminals:' -and $text -notmatch 'NetsTerminals:|NETS-KIOSK') 'SIX included unrelated terminals' }
            if ($provider -in @('NETS','NEXIDE')) { Assert-Check ($text -match 'NetsTerminals:' -and $text -notmatch 'SixTerminals:|SIX-KIOSK') 'NETS/NEXIDE included unrelated terminals' }
            if ($provider -eq 'PRINT') { Assert-Check ($text -notmatch 'SixTerminals:|NetsTerminals:|SIX-KIOSK|NETS-KIOSK') 'PRINT leaked terminal sections' }
            $display = @(Get-ThoroughReportDisplayRows @([pscustomobject]@{ SectionNumber=4; SectionTitle='AppSettings Check'; Shortcut='<code>appsettings.json</code>'; ConfigurationSnapshot=$config; ConfigurationServiceName='FixturePayment'; ConfigurationPath='C:\Fixture\appsettings.json' }))
            Assert-Check ($display.Count -eq $(if ($provider -eq 'PRINT') { 7 } else { 9 })) 'Incorrect point-7 AppSettings group count'
            $actualPayment = $display | Where-Object ItemTitle -eq 'PaymentConfiguration'
            if ($provider -eq 'PRINT') { Assert-Check ($null -eq $actualPayment) 'PRINT included PaymentConfiguration terminals' }
            else {
                $fields = if ($provider -eq 'SIX') { @('KioskId','TerminalId','Currency','LogDirectory','IsDeferredInitiation') } else { @('PosId','KioskId','TerminalIPAddress','TerminalId','Currency','Language','IsSetupEnabled') }
                $labels = @([regex]::Matches($actualPayment.FoundStateHtml, '<span class="kv-label">([^<]+):</span>') | ForEach-Object { $_.Groups[1].Value })
                Assert-Check (($labels -join ',') -ceq ($fields -join ',')) 'PaymentConfiguration keys do not match point 7'
                $otherCollection = if ($provider -eq 'SIX') { 'NetsTerminals' } else { 'SixTerminals' }
                Assert-Check ($actualPayment.FoundStateHtml -notmatch $otherCollection) 'Unrelated terminal section rendered'
            }
            foreach ($groupName in @('PaymentService','ScheduleConfiguration','Print','MonitoringServiceBaseUrl','CmsGatewayBaseUrl','OrderServiceBaseUrl')) {
                Assert-Check (@($display | Where-Object ItemTitle -eq $groupName).Count -eq 1) "Missing or duplicate point-7 group: $groupName"
            }
            $scheduleRow = $display | Where-Object ItemTitle -eq 'ScheduleConfiguration'
            Assert-Check ($scheduleRow.FoundStateHtml -match 'Provider:</span> KitchenTicketPrint' -and $scheduleRow.FoundStateHtml -match 'IsKioskPrintingEnabled:</span> False' -and $scheduleRow.FoundStateHtml -match 'IsEnabled:</span> False') 'ScheduleConfiguration values lost or mislabelled'
            Assert-Check (@($display | Where-Object { $_.FoundStateHtml -match 'https://example.test/orders' }).Count -eq 1) 'Endpoint value changed'
            Assert-Check (@($display | Where-Object { $_.FoundStateHtml -match 'Kitchen &lt;Printer&gt;' }).Count -eq 1) 'AppSettings HTML escaping failed'
            $expectedFailures=if($provider -ne 'PRINT' -and $scheduleShape -eq 'Direct'){1}else{0}
            Assert-Check (@($display | Where-Object { $_.Status -ne 'Pass' }).Count -eq $expectedFailures) 'False values or optional empty terminal ID reported as missing, or a missing payout was ignored'
            if($expectedFailures){Assert-Check (($display | Where-Object ItemTitle -eq 'Payout Scheduler').Status -eq 'Fail') 'Missing payout schedule was incorrectly verified'}
        }
    }
    $config.Print.PrinterName = ''
    $config.OrderServiceBaseUrl = $null
    $incomplete = @(Get-ThoroughReportDisplayRows @([pscustomobject]@{ SectionNumber=4; SectionTitle='AppSettings Check'; Shortcut=''; ConfigurationSnapshot=$config }))
    Assert-Check (($incomplete | Where-Object ItemTitle -eq 'Print').Status -eq 'Fail') 'Empty printer name was promoted to Pass'
    Assert-Check (($incomplete | Where-Object ItemTitle -eq 'OrderServiceBaseUrl').Status -eq 'Fail') 'Missing endpoint was promoted to Pass'
    Write-Host "PASS: $sourceName account grouping, Audit/Apply safety, missing-user guards, provider filtering and schedule shapes"
}
