
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
. (Join-Path $PSScriptRoot 'SettingReportTestSupport.ps1')
# Render synthetic account observations only. Never execute device checks.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=$projectRoot
$outputRoot=Join-Path $projectRoot 'output\fix-account-records'
[void][IO.Directory]::CreateDirectory($outputRoot)
$restorePath=Join-Path $PSScriptRoot 'Fixtures\AccountFixLegacyRenderer.json'
$restorePoint=Get-Content -LiteralPath $restorePath -Raw | ConvertFrom-Json
$utf8=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'AuditColumnTestSupport.ps1')
function Assert-FixAccount {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Read-FixAccountSnapshot {param($Snapshot) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Snapshot.HtmlBase64))}
function Get-FixAccountCells {
    param([string]$Html,[string]$Title)
    $titlePattern='<div class="device-title">'+[regex]::Escape($Title)+'</div>'
    $rows=@([regex]::Matches($Html,'(?is)<tr\b[^>]*>.*?</tr>') | Where-Object {$_.Value -match $titlePattern})
    Assert-FixAccount ($rows.Count -le 1) ('Duplicate account component: '+$Title)
    if($rows.Count){@([regex]::Matches($rows[0].Value,'(?is)<td\b[^>]*>(.*?)</td>') | ForEach-Object {$_.Groups[1].Value})}
}
function Assert-FixAccountDivider {
    param([string]$Html,[int]$Count)
    Assert-FixAccount ([regex]::Matches($Html,'<hr class="block-divider">').Count -eq $Count) 'Account record dividers were not rebuilt after filtering.'
    Assert-FixAccount ($Html -notmatch '^\s*<hr\b|<hr\b[^>]*>\s*$|<hr\b[^>]*>\s*<hr\b') 'Filtered account records have a dangling or repeated divider.'
}

foreach($sourceName in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $sourceName
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $sourceRoot 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    Assert-FixAccount ($errors.Count -eq 0) 'Client source failed parsing.'
    $definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    Use-SettingLayoutRuleAssertions -SourceName $sourceName
    function Get-LocalUser {throw 'Report fixture queried accounts.'}
    function Get-CimInstance {throw 'Report fixture queried the device.'}
    function Set-LocalUser {throw 'Report fixture changed an account.'}
    function Set-Service {throw 'Report fixture changed a service.'}
    function Start-Process {throw 'Report fixture started a process.'}
    $script:ApplyChanges=$false
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    $identity=[pscustomobject]@{ReportId='OMK-230031';GeneratedAt='23 Oct 2026, 4:15 PM BST'}
    function New-FixAccountEntry {
        param([string]$Name,[string]$Status='Pass',[string]$CannotChange='Enabled',[string]$Action='Requested password settings are enabled; no changes needed',[string]$Privilege='Local Administrator',[switch]$OmitPasswordField,[Nullable[bool]]$PolicyChanged=$null)
        if($script:passwordLabel -eq 'User Cannot Change Password' -and -not $PSBoundParameters.ContainsKey('Privilege')){$Privilege='Standard Local User'}
        $values=[ordered]@{'Account Name'=$Name;'Account Privilege'=$Privilege;'Account Status'='Enabled';'Password Never Expires'='Enabled';'User Cannot Change Password'=$CannotChange}
        if($script:passwordLabel -eq 'Password Never Expires'){$values['Password Never Expires']=$CannotChange;$values.Remove('User Cannot Change Password')}
        if($OmitPasswordField){$values.Remove($script:passwordLabel)}
        $entry=[pscustomobject]@{AccountName=$Name;Status=$Status;Action=$Action;StateHtml=(ConvertTo-ReportDefinitionHtml $values)}
        if($null -ne $PolicyChanged){$entry | Add-Member NoteProperty AccountPolicyChanged ([bool]$PolicyChanged)}
        $entry
    }
    function New-FixAccountRow {
        param([string]$Title,[object[]]$Entries,[switch]$WithoutMetadata)
        $row=[pscustomobject]@{
            SectionNumber=$(if($Title -eq 'KIOSK Account'){2}else{4})
            SectionTitle=$(if($Title -eq 'KIOSK Account'){'Kiosk Application & Policies'}else{'Security, Network & System Integrity'})
            ItemTitle=$Title;ItemSub='Verified configuration'
            Shortcut=(New-AccountReportCommand -AccountNames @($Entries | ForEach-Object {$_.AccountName}))
            FoundStateHtml=('<div class="account-stack">'+(($Entries | ForEach-Object {$_.StateHtml}) -join '<hr>')+'</div>')
            Status=$(if(@($Entries | Where-Object {$_.Status -notin @('Pass','Remediated')}).Count){'Fail'}else{'Pass'})
            ActionTaken=(($Entries | ForEach-Object {$_.AccountName+': '+$_.Action}) -join '; ')
        }
        if(-not $WithoutMetadata){$row | Add-Member NoteProperty AccountResults @($Entries)}
        $row
    }
    foreach($title in @('KIOSK Account','Administrative Accounts')){
        $script:passwordLabel=if($title -eq 'Administrative Accounts'){'Password Never Expires'}else{'User Cannot Change Password'}
        $nameA=if($title -eq 'KIOSK Account'){'SELISE'}else{'Administrator'}
        $nameB=if($title -eq 'KIOSK Account'){'SELISE-KIOSK'}else{'Admin'}
        $healthy=New-FixAccountEntry $nameA -PolicyChanged $false
        $issue=New-FixAccountEntry $nameB Fail Disabled 'Audit only: required password property is disabled'
        $row=New-FixAccountRow $title @($healthy,$issue)
        $before=$row | ConvertTo-Json -Depth 12 -Compress
        $audit=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -AuditSource $identity
        $final=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Final -AuditSource $identity -KioskUserName $nameB
        $savedRenderer=@(@($restorePoint.Clients | Where-Object ClientType -EQ $sourceName)[0].Changes | Where-Object Name -EQ 'New-ThoroughReportSnapshot')[0]
        Assert-FixAccount (-not [string]::IsNullOrWhiteSpace($savedRenderer.Before)) 'Before renderer missing from restore point.'
        . ([scriptblock]::Create($savedRenderer.Before))
        $oldAudit=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Audit -AuditSource $identity
        $oldFinal=New-ThoroughReportSnapshot -Rows @(Get-ThoroughFinalReportRows -Rows @($row) -ConfirmedKioskUser $nameB -AfterApply $false) -DisplayMode Final -AuditSource $identity -KioskUserName $nameB
        # Header metadata and the five-column Audit presentation are approved changes.
        # Keep the historical Final configuration parity check and verify Audit data independently.
        $configPattern='(?is)<h2>CONFIGURATION CHECK</h2>(.*?)<p class="legend">'
        $oldConfig=[regex]::Match((Read-FixAccountSnapshot $oldFinal),$configPattern).Groups[1].Value
        $newConfig=[regex]::Match((Read-FixAccountSnapshot $final),$configPattern).Groups[1].Value
        Assert-FixAccount ($oldConfig.Length -gt 0 -and $oldConfig -ceq $newConfig) 'Account Fix filtering changed Final configuration output.'
        . ([scriptblock]::Create(($definitions | Where-Object Name -EQ 'New-ThoroughReportSnapshot').Extent.Text))
        Use-SettingLayoutRuleAssertions -SourceName $sourceName
        $component=Get-AuditRenderedComponent (Read-FixAccountSnapshot $audit) $title
        $accountNames=@($component.Fields|Where-Object Setting -EQ 'Account Name'|ForEach-Object {$_.Found})
        $legacyCells=@(Get-FixAccountCells (Read-FixAccountSnapshot $oldAudit) $title)
        $legacyFields=@([regex]::Matches($legacyCells[3],'(?is)<span class="kv-label">(?<Label>[^<]+):</span>\s*(?<Value>.*?)</div>')|ForEach-Object {
            ([Net.WebUtility]::HtmlDecode($_.Groups['Label'].Value).Trim())+'='+([Net.WebUtility]::HtmlDecode(([regex]::Replace($_.Groups['Value'].Value,'<[^>]*>',''))).Trim())
        })
        $currentFields=@($component.Fields|ForEach-Object {$_.Setting+'='+$_.Found})
        Assert-FixAccount ($legacyFields.Count -gt 0 -and ($legacyFields -join '|') -ceq ($currentFields -join '|')) 'Audit account fields changed during account Fix filtering.'
        Assert-FixAccount ($component.Count -eq 1 -and $component.Headings.Count -eq 2 -and $accountNames.Count -eq 2 -and $accountNames[0] -ceq $nameA -and $accountNames[1] -ceq $nameB) 'Audit lost an account record or identity.'
        $html=Read-FixAccountSnapshot $final
        if($title -eq 'KIOSK Account'){
            Assert-FixAccount (-not $html.Contains('Account Name:</span> '+$nameA+'</div>') -and $html.Contains('Account Name:</span> '+$nameB)) 'Final did not retain only the confirmed kiosk account.'
        }else{
            Assert-FixAccount (-not $html.Contains('Account Name:</span> '+$nameA+'</div>') -and $html.Contains('Account Name:</span> '+$nameB)) 'Final did not retain the priority administrative account.'
        }
        $fix=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AuditSource $identity
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $fix) $title)
        Assert-FixAccount ($cells.Count -eq 4) 'Mixed account component missing from Fix.'
        Assert-FixAccount ($cells[2] -notmatch '>Account 01</div>|No change needed for these values' -and $cells[2].Contains('>Account 02</div>')) 'A healthy sibling account is still shown or the retained ordinal changed.'
        Assert-FixAccount ($cells[2].Contains('Account Name:</span> '+$nameB) -and $cells[2] -match ('finding-mismatch[^>]*><span class="kv-label">'+[regex]::Escape($script:passwordLabel)+':</span> Disabled')) 'Fix lost the failing account identity or requirement.'
        Assert-FixAccount ($cells[1].Contains('net user &quot;'+$nameB+'&quot;') -and -not $cells[1].Contains('net user &quot;'+$nameA+'&quot;')) 'Fix commands include a healthy omitted account or omit the retained account.'
        Assert-FixAccount ($cells[3] -notmatch 'Completed' -and $cells[3] -match 'Not Applied') 'Audit-derived Fix fabricated an applied repair.'
        Assert-FixAccountDivider $cells[2] 0
        Assert-FixAccount (($row | ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'Account filtering mutated original observations.'

        $row=New-FixAccountRow $title @($issue,$healthy,$issue)
        # Distinct identities avoid deliberately ambiguous metadata here.
        $row.AccountResults[2]=New-FixAccountEntry ($nameB+'-Other') Unknown 'Not verified' 'Manual verification required'
        $row.FoundStateHtml='<div class="account-stack">'+(($row.AccountResults | ForEach-Object {$_.StateHtml}) -join '<hr>')+'</div>'
        $row.Shortcut=New-AccountReportCommand @($row.AccountResults | ForEach-Object {$_.AccountName})
        $row.ActionTaken=($row.AccountResults | ForEach-Object {$_.AccountName+': '+$_.Action}) -join '; '
        $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AuditSource $identity
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
        Assert-FixAccount ($cells[2].Contains('>Account 01</div>') -and $cells[2].Contains('>Account 03</div>') -and $cells[2] -notmatch '>Account 02</div>') 'Filtering inverse or multiple account records lost their original ordinal.'
        Assert-FixAccountDivider $cells[2] 1

        $allGood=New-FixAccountRow $title @((New-FixAccountEntry $nameA),(New-FixAccountEntry $nameB))
        foreach($afterApply in @($false,$true)){
            $parameters=@{Rows=@($allGood);DisplayMode='Fix';AfterApply=$afterApply}
            if(-not $afterApply){$parameters.AuditSource=$identity}
            $view=New-ThoroughReportSnapshot @parameters
            $html=Read-FixAccountSnapshot $view
            Assert-FixAccount ($html.Contains('No fixes required.') -and -not @(Get-FixAccountCells $html $title).Count) 'An all-healthy account component remains in Fix.'
        }
        $ownFailed=New-FixAccountEntry $nameA Fail Enabled 'Required account setting was not verified. Manual action required.'
        $row=New-FixAccountRow $title @($ownFailed,(New-FixAccountEntry $nameB))
        $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AuditSource $identity
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
        Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('Account Name:</span> '+$nameA) -and -not $cells[2].Contains('>Account 02</div>')) 'An account-specific failed result was hidden by all-green display fields.'

        foreach($manualAction in @('Required account setting was not verified. Please check manually.','Manual action required. Please inspect this account.')){
            $row=New-FixAccountRow $title @((New-FixAccountEntry $nameA Pass Enabled $manualAction),(New-FixAccountEntry $nameB))
            foreach($afterApply in @($false,$true)){
                $parameters=@{Rows=@($row);DisplayMode='Fix';AfterApply=$afterApply}
                if(-not $afterApply){$parameters.AuditSource=$identity}
                $view=New-ThoroughReportSnapshot @parameters
                $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
                Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('Account Name:</span> '+$nameA) -and $cells[2] -notmatch '>Account 02</div>') ('A manual or unverified action note was hidden: '+$client+'/'+$title+'/AfterApply='+$afterApply+'/'+$manualAction+'; cells='+$cells.Count)
                Assert-FixAccount ($cells[2] -notmatch 'No (?:further fix|change) needed' -and (Convert-ReportHtmlToTerminalText ($cells[2]+$cells[3])) -match '(?i)not verified|manual action required') 'An account requiring manual review was displayed as a healthy no-op.'
            }
        }

        foreach($metadataCase in @('wrong-name','null','duplicate','missing-status','malformed')){
            $row=New-FixAccountRow $title @((New-FixAccountEntry $nameA),(New-FixAccountEntry $nameB))
            $row.Status='Fail';$row.ActionTaken='Account verification was not completed. Manual review required.'
            switch($metadataCase){
                'wrong-name' {$row.AccountResults=@((New-FixAccountEntry 'UnrelatedAccount'))}
                'null' {$row.AccountResults=@($null)}
                'duplicate' {$row.AccountResults=@((New-FixAccountEntry $nameA),(New-FixAccountEntry $nameA))}
                'missing-status' {
                    $entry=New-FixAccountEntry $nameA
                    $entry.PSObject.Properties.Remove('Status')
                    $row.AccountResults=@($entry)
                }
                'malformed' {$row.AccountResults=@([pscustomobject]@{State='Unreadable'})}
            }
            $beforeMalformed=$row | ConvertTo-Json -Depth 12 -Compress
            foreach($afterApply in @($false,$true)){
                $parameters=@{Rows=@($row);DisplayMode='Fix';AfterApply=$afterApply}
                if(-not $afterApply){$parameters.AuditSource=$identity}
                $view=New-ThoroughReportSnapshot @parameters
                $html=Read-FixAccountSnapshot $view
                $cells=@(Get-FixAccountCells $html $title)
                Assert-FixAccount ($cells.Count -eq 4 -and -not $html.Contains('No fixes required.')) ('Malformed account metadata hid a failed aggregate: '+$metadataCase)
                Assert-FixAccount ((Convert-ReportHtmlToTerminalText ($cells[2]+$cells[3])) -match '(?i)not verified|manual') ('Malformed account metadata lost its verification warning: '+$metadataCase)
            }
            Assert-FixAccount (($row | ConvertTo-Json -Depth 12 -Compress) -ceq $beforeMalformed) 'Conservative metadata handling mutated recorded account observations.'
        }

        $repaired=New-FixAccountEntry $nameB Pass Enabled 'Enabled Password Never Expires; readback verified' -PolicyChanged $true
        $row=New-FixAccountRow $title @((New-FixAccountEntry $nameA -PolicyChanged $false),$repaired)
        $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AfterApply $true
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
        Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('>Account 02</div>') -and $cells[2] -notmatch '>Account 01</div>') 'Actual repair was omitted or another account repair retained a healthy sibling.'
        Assert-FixAccount ($cells[3].Contains('>Account 02</div>') -and $cells[3] -match '>Completed</strong>' -and $cells[3].Contains('Enabled Password Never Expires') -and $cells[3] -notmatch '>Account 01</div>') 'Applied lost account identity, actual repair or matching grouping.'
        Assert-FixAccountDivider $cells[2] 0
        Assert-FixAccountDivider $cells[3] 0
        # The same action text cannot be presented as an executed repair in an Audit-derived view.
        $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AuditSource $identity
        Assert-FixAccount ((Read-FixAccountSnapshot $view).Contains('No fixes required.')) 'Audit-derived filtering treated recorded action text as a new repair.'

        foreach($entry in @(
            (New-FixAccountEntry $nameB Fail Disabled 'Enabled Password Never Expires; required flag readback failed. Manual action required.'),
            (New-FixAccountEntry $nameB Unknown 'Not verified' 'Account properties could not be read. Manual action required.'),
            (New-FixAccountEntry $nameB Fail Enabled 'One account property is unavailable' -OmitPasswordField)
        )){
            $row=New-FixAccountRow $title @((New-FixAccountEntry $nameA),$entry)
            $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AfterApply $true
            $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
            Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('>Account 02</div>') -and $cells[2] -notmatch '>Account 01</div>') 'A partial repair, unreadable field or unknown account was hidden.'
        }
        # Historical rows lack AccountResults. Do not infer a successful no-op after Apply.
        $historical=New-FixAccountRow $title @((New-FixAccountEntry $nameA),$repaired) -WithoutMetadata
        $view=New-ThoroughReportSnapshot -Rows @($historical) -DisplayMode Fix -AfterApply $true
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
        Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('>Account 01</div>') -and $cells[2].Contains('>Account 02</div>')) 'Missing account result metadata silently discarded an account after Apply.'
        $historicalMismatch=New-FixAccountRow $title @((New-FixAccountEntry $nameA),(New-FixAccountEntry $nameB Fail Disabled 'Required password property remains disabled. Manual action required.')) -WithoutMetadata
        $view=New-ThoroughReportSnapshot -Rows @($historicalMismatch) -DisplayMode Fix -AfterApply $true
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
        Assert-FixAccount ($cells.Count -eq 4 -and $cells[2] -match ('finding-mismatch[^>]*><span class="kv-label">'+[regex]::Escape($script:passwordLabel)+':</span> Disabled') -and $cells[2].Contains('Required: Enabled')) 'Missing action metadata discarded a known account mismatch or its required value.'
        Assert-FixAccount ($cells[2] -match 'finding-unverified' -and $cells[3] -match '>Not Verified</strong>') 'Missing action metadata did not retain a verification warning alongside known mismatch fields.'
        $ambiguous=New-FixAccountRow $title @((New-FixAccountEntry $nameA),$repaired)
        $ambiguous.AccountResults=@($ambiguous.AccountResults)+@((New-FixAccountEntry $nameA Pass Enabled 'Enabled User Cannot Change Password; readback verified'))
        $view=New-ThoroughReportSnapshot -Rows @($ambiguous) -DisplayMode Fix -AfterApply $true
        $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
        Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('>Account 01</div>')) 'Ambiguous per-account metadata silently hid the account after Apply.'

        foreach($raw in @('Account Missing. Please create manually.','Not verified. Account properties could not be read. Please check manually.')){
            $row=New-FixAccountRow $title @() -WithoutMetadata
            $row.Status='Fail';$row.FoundStateHtml=$raw;$row.ActionTaken='Manual action required'
            $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AuditSource $identity
            $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) $title)
            Assert-FixAccount ($cells.Count -eq 4 -and (Convert-ReportHtmlToTerminalText $cells[2]) -match '(?i)missing|not verified') 'Missing or unreadable account observations were hidden.'
        }
        Assert-FixAccount (-not (Test-CanApply)) 'Account presentation filtering enabled repairs.'
    }
    # Match metadata case-insensitively while preserving escaped device-reported names.
    $script:passwordLabel='User Cannot Change Password'
    $escaped=New-FixAccountEntry 'Desk & O''Brien <East>' Fail 'Not verified' 'Manual verification required'
    $escaped.AccountName='DESK & O''BRIEN <EAST>'
    $row=New-FixAccountRow 'KIOSK Account' @((New-FixAccountEntry 'SELISE'),$escaped)
    $view=New-ThoroughReportSnapshot -Rows @($row) -DisplayMode Fix -AuditSource $identity
    $cells=@(Get-FixAccountCells (Read-FixAccountSnapshot $view) 'KIOSK Account')
    Assert-FixAccount ($cells.Count -eq 4 -and $cells[2].Contains('Desk &amp; O&#39;Brien &lt;East&gt;') -and $cells[2] -notmatch '>Account 01</div>') 'Escaping or case-insensitive account metadata matching failed.'

    $script:passwordLabel='Password Never Expires'
    $sampleRow=New-FixAccountRow 'Administrative Accounts' @((New-FixAccountEntry 'Administrator'),(New-FixAccountEntry 'Admin' Fail 'Not verified' 'Manual verification required'))
    $reports=[pscustomobject]@{
        Audit=(New-ThoroughReportSnapshot -Rows @($sampleRow) -DisplayMode Audit -AuditSource $identity -ClientLocation 'Sample branch' -DeviceType KIOSK -Hostname 'SAMPLE-DEVICE')
        Fix=(New-ThoroughReportSnapshot -Rows @($sampleRow) -DisplayMode Fix -AuditSource $identity -ClientLocation 'Sample branch' -DeviceType KIOSK -Hostname 'SAMPLE-DEVICE')
        Final=(New-ThoroughReportSnapshot -Rows @($sampleRow) -DisplayMode Final -AuditSource $identity -ClientLocation 'Sample branch' -DeviceType KIOSK -Hostname 'SAMPLE-DEVICE')
    }
    $bundle=[pscustomobject]@{Version=1;TestOnly=$true;ClientType=$client;ComputerName='SAMPLE-DEVICE';BundleId='OMK-230032';CreatedAt=$identity.GeneratedAt;UpdatedAt=$identity.GeneratedAt;LatestMode='Fix';Reports=$reports}
    [IO.File]::WriteAllText((Join-Path $outputRoot ($client+'-Fix-Account-Preview.html')),(New-ThoroughReportBundleHtml $bundle),$utf8)
    Write-Output ('PASS: '+$client+' account records filtered independently; unresolved and actual repairs retained; original ordinals, commands/dividers/grouping, escaped identities and conservative history handling; Audit values and Final configuration preserved; observations and repair gate unchanged.')
}
