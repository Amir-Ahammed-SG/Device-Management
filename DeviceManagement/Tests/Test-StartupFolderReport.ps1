# Inspect fixture files only. Never execute a launcher or change a device profile.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$sourceRoot=Split-Path $projectRoot -Parent
$previewRoot=Join-Path $projectRoot 'output\startup-folder'
$fixtureRoot=Join-Path $previewRoot ('fixtures-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-Startup {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Get-StartupSnapshot {
    (@(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })) -join "`n"
}
$caseCount=0
foreach($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $sourceName),[ref]$tokens,[ref]$errors)
    Assert-Startup ($errors.Count -eq 0) 'Client source did not parse.'
    $definitions=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    . ([scriptblock]::Create(($definitions | ForEach-Object {$_.Extent.Text}) -join "`r`n"))
    $startupBlocks=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match '^\{\s*\$profile = Get-KioskProfilePath \$kioskUser' -and $n.Body.Extent.Text -match '\$startupPath ='},$true))
    Assert-Startup ($startupBlocks.Count -eq 1) 'Startup inspection boundary is ambiguous.'
    $inspect=[scriptblock]::Create($startupBlocks[0].Extent.Text)
    $finalizer=$ast.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Writing HTML report'},$true) | Select-Object -Last 1
    $render=[scriptblock]::Create(($finalizer.Finally.Statements | ForEach-Object {$_.Extent.Text}) -join "`r`n")
    function Get-KioskProfilePath {param($UserName) if($script:profileMissing){return $null}; return $script:fixtureProfile}
    function Test-Path {
        [CmdletBinding()]param([string]$LiteralPath,[string]$PathType)
        Assert-Startup ($LiteralPath.StartsWith($previewRoot,[StringComparison]::OrdinalIgnoreCase)) 'Inspection escaped fixture output.'
        if($PathType -eq 'Leaf'){
            if($script:readDenied){throw 'Fixture access denied'}
            return [IO.File]::Exists($LiteralPath)
        }
        if($PathType -eq 'Container'){return [IO.Directory]::Exists($LiteralPath)}
        Assert-Startup ($PathType -in @('','Any')) ('Unexpected path query: '+$PathType)
        return [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath)
    }
    function Add-AuditEntry {
        param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken)
        $script:startupRow=[pscustomobject]@{SectionNumber=$SectionNumber;SectionTitle=$SectionTitle;ItemTitle=$ItemTitle;ItemSub=$ItemSub;Shortcut=$Shortcut;FoundStateHtml=$FoundStateHtml;Status=$Status;ActionTaken=$ActionTaken}
    }
    function Read-AuditReportChoice {return $true}
    function Start-AuditStep {param($Number,$Name)}
    function Complete-ThoroughConsole {param($IsApply,$FailedCount)}
    $client=if($sourceName -like 'Subway*'){'Subway'}else{'SaaS'}
    foreach($isApply in @($false,$true)){
        $script:ApplyChanges=$isApply
        $mode=if($isApply){'Apply'}else{'Audit'}
        foreach($case in @('available','missing-bat','missing-shortcut','missing-both','metadata-only','unrelated-shortcut','bat-directory','missing-profile','unreadable')){
            $script:fixtureProfile=Join-Path $fixtureRoot ($client+'-'+$mode+'-'+$case+' & Device')
            $startup=Join-Path $script:fixtureProfile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
            $desktop=Join-Path $script:fixtureProfile 'Desktop'
            [void][IO.Directory]::CreateDirectory($startup)
            [void][IO.Directory]::CreateDirectory($desktop)
            if($case -notin @('missing-bat','missing-both','bat-directory')){[IO.File]::WriteAllText((Join-Path $startup 'LaunchKiosk.bat'),'@rem fixture only; never execute')}
            if($case -notin @('missing-shortcut','missing-both','metadata-only','unrelated-shortcut')){[IO.File]::WriteAllText((Join-Path $desktop 'Launch Kiosk.lnk'),'fixture only; never execute')}
            if($case -eq 'bat-directory'){[void][IO.Directory]::CreateDirectory((Join-Path $startup 'LaunchKiosk.bat'))}
            [IO.File]::WriteAllText((Join-Path $startup 'Customer Startup.bat'),'unrelated fixture BAT')
            [IO.File]::WriteAllText((Join-Path $desktop 'desktop.ini'),'fixture metadata')
            [IO.File]::WriteAllText((Join-Path $desktop 'Other.lnk'),'unrelated fixture shortcut')
            $script:profileMissing=$case -eq 'missing-profile'
            $script:readDenied=$case -eq 'unreadable'
            $script:startupRow=$null
            $sec2Num=2;$sec2Title='Kiosk Application & Policies';$kioskUser='SELISE-KIOSK'
            $before=Get-StartupSnapshot
            . $inspect
            Assert-Startup ((Get-StartupSnapshot) -ceq $before) 'Startup reporting changed fixture files.'
            $row=$script:startupRow
            Assert-Startup ($null -ne $row -and ($row.Status -eq 'Pass') -eq ($case -eq 'available')) ('Incorrect availability result: '+$client+'/'+$mode+'/'+$case)
            $requirement=Get-ReportRequirement $row
            Assert-Startup ($requirement -ceq (ConvertTo-ReportDefinitionHtml ([ordered]@{'Location'='Path';'Startup BAT'='Available';'Desktop Shortcut'='Available'}))) 'Startup requirements differ from the approved fields.'
            $labels=@([regex]::Matches($row.FoundStateHtml,'kv-label">([^<]+):') | ForEach-Object {$_.Groups[1].Value})
            Assert-Startup (($labels -join '|') -ceq 'Location|Startup BAT|Desktop Shortcut') 'Findings field order differs.'
            Assert-Startup ($row.FoundStateHtml -notmatch 'desktop\.ini|Customer Startup|Other\.lnk|Contents:|Folder:') 'Metadata or unrelated files were reported as kiosk files.'
            if($case -in @('missing-profile','unreadable')){
                Assert-Startup ($row.FoundStateHtml -match 'Not verified\. Please check manually\.' -and $row.Status -eq 'Fail') 'Unavailable evidence was reported as verified.'
            }else{
                Assert-Startup ($row.FoundStateHtml.Contains(('Location:</span> '+[Net.WebUtility]::HtmlEncode($startup)))) 'Actual location or HTML escaping is incorrect.'
                $batExpected=if($case -in @('missing-bat','missing-both','bat-directory')){'Missing. Manual action required.'}else{'LaunchKiosk.bat'}
                $shortcutExpected=if($case -in @('missing-shortcut','missing-both','metadata-only','unrelated-shortcut')){'Missing. Manual action required.'}else{'Launch Kiosk.lnk'}
                Assert-Startup ($row.FoundStateHtml.Contains(('Startup BAT:</span> '+$batExpected)) -and $row.FoundStateHtml.Contains(('Desktop Shortcut:</span> '+$shortcutExpected))) 'Reported filename or missing-file state is incorrect.'
            }
            if($case -eq 'available'){
                $auditRows=[Collections.Generic.List[psobject]]::new()
                $auditRows.Add($row)
                $outputFolder=$previewRoot
                $reportPath=Join-Path $previewRoot ($client+'-'+$mode+'-preview.html')
                $runId='SAMPLE-STARTUP';$clientLocation='Sample branch';$deviceType='KIOSK';$reportHostname='SAMPLE-KIOSK-01';$reportKioskId='Kiosk-1';$KioskId=$null
                . $render
                $html=[IO.File]::ReadAllText($reportPath)
                Assert-Startup ($html.Contains($row.FoundStateHtml) -and $html.Contains($requirement) -and $html.Contains('device-title">Startup Folder</div>')) 'Rendered report lost Startup fields.'
                Assert-Startup (($html -match '<th>Status</th>') -eq $isApply) 'Audit/Apply column layout changed.'
            }
            $caseCount++
        }
    }
    Remove-Item Function:\Test-Path
}
Write-Output ("Startup Folder checks passed: $caseCount isolated cases across both clients and modes; four real-renderer previews. No live device checks ran.")
