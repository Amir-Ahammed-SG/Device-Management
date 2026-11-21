# Shared kiosk common functions. Dot-sourced into the engine's scope.

function Confirm-KioskApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param ()
    # Invoke-Expression does not provide a script-level PSCmdlet. This advanced
    # function owns its PSCmdlet and honors inherited WhatIf/Confirm preferences.
    $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Apply kiosk configuration and repair settings')
}

function Test-CanApply { return [bool]$script:ApplyChanges }

function Write-ThoroughConsoleLine {
    param ([string]$Text, [string]$Indent='', [ConsoleColor]$Color='Gray', [int]$Width=0)
    if ($Width -le 0) {
        try { $Width=[int]$Host.UI.RawUI.WindowSize.Width-1 } catch { $Width=100 }
        if ($Width -lt 24) { $Width=100 }
    }
    $Width=[Math]::Max(24,[Math]::Min(100,$Width))
    $remaining=($Text -replace '[\x00-\x1f\x7f]+',' ').Trim()
    $available=[Math]::Max(1,$Width-$Indent.Length)
    do {
        if ($remaining.Length -le $available) { Write-Host ($Indent+$remaining) -ForegroundColor $Color; break }
        $split=$remaining.LastIndexOf(' ',$available)
        if ($split -le 0) { $split=$available }
        Write-Host ($Indent+$remaining.Substring(0,$split).TrimEnd()) -ForegroundColor $Color
        $remaining=$remaining.Substring($split).TrimStart()
    } while ($remaining.Length -gt 0)
}

function Get-ThoroughAuditClientLocation {
    param([string]$Path,[string]$ClientType,[string]$ComputerName)
    # Report filenames may use the launcher hostname. Match saved Audit identity,
    # in this report folder only, without changing files or guessing conflicts.
    $paths=New-Object 'Collections.Generic.List[string]'
    if([IO.File]::Exists($Path)){[void]$paths.Add($Path)}
    try {
        $folder=[IO.Path]::GetDirectoryName($Path)
        if($ClientType -cin @('SaaS','Subway') -and [IO.Directory]::Exists($folder)){
            foreach($candidate in [IO.Directory]::GetFiles($folder,('Thorough Check Reports - '+$ClientType+' - *.html'))){
                if(-not $paths.Contains($candidate)){[void]$paths.Add($candidate)}
            }
        }
    } catch { return $null }
    $branches=New-Object 'Collections.Generic.List[string]'
    foreach($candidate in $paths){
        try {
            $state=Read-ThoroughReportBundleState ([IO.File]::ReadAllText($candidate))
            if($state.ClientType -cne $ClientType -or $state.ComputerName -ine $ComputerName){continue}
            $audit=$state.Reports.Audit
            if($null -eq $audit){continue}
            $html=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($audit.HtmlBase64))
            $match=[regex]::Match($html,'(?is)(?:<th>\s*Branch\s*</th>\s*<td\b[^>]*>(?<Branch>.*?)</td>|<dt>\s*Branch\s*</dt>\s*<dd\b[^>]*>(?<Branch>.*?)</dd>)')
            if(-not $match.Success){continue}
            $branch=[Net.WebUtility]::HtmlDecode(($match.Groups['Branch'].Value -replace '<[^>]+>',''))
            if([string]::IsNullOrWhiteSpace($branch) -or $branch.Trim() -in @('Not provided','Not verified')){continue}
            if(-not $branches.Contains($branch)){[void]$branches.Add($branch)}
            if($branches.Count -gt 1){return $null}
        } catch {
            # Preserve unreadable/unsupported reports. Their data is not trusted.
            continue
        }
    }
    if($branches.Count -eq 1){return $branches[0]}
    return $null
}

function Get-ThoroughAuditAgentName {
    param([string]$Path,[string]$ClientType,[string]$ComputerName)
    # Reuse only a uniquely identified saved Audit. Never guess a Windows user
    # or attribute a legacy report to the person running Apply.
    try {
        $existing=Find-ThoroughExistingBundle -Path $Path -ClientType $ClientType -ComputerName $ComputerName
        if($existing -and $existing.State.Reports.Audit){
            $audit=$existing.State.Reports.Audit
            if($audit.PSObject.Properties['AgentName'] -and -not [string]::IsNullOrWhiteSpace([string]$audit.AgentName) -and $audit.AgentName -ne 'Not provided'){
                return [string]$audit.AgentName
            }
        }
    } catch { return $null }
    return $null
}

function Get-ThoroughConsoleKioskId {
    # Read existing profiles and literal launcher URLs only. Never run setup,
    # account policy checks, launcher repair, or the launcher itself for a header.
    try {
        $users=@(Get-LocalUser -ErrorAction Stop)
        $active=@($users | Where-Object {$_.Enabled})
        if($active.Count){$users=$active}
        $autoUser=try {Get-KioskAutoLoginUserName} catch {''}
        $selected=@($users | Where-Object {$_.Name -ieq $autoUser})
        $paths=@()
        if($selected.Count -eq 1){
            $profilePath=Get-KioskProfilePath -UserName $selected[0].Name
            if(-not $profilePath){return 'Not verified'}
            $paths=@(Join-Path $profilePath 'Scripts\LaunchKiosk.ps1')
        }else{
            $paths=@(foreach($user in $users){
                $profilePath=Get-KioskProfilePath -UserName $user.Name
                if($profilePath){
                    $candidatePath=Join-Path $profilePath 'Scripts\LaunchKiosk.ps1'
                    if(Test-Path -LiteralPath $candidatePath -PathType Leaf -ErrorAction Stop){$candidatePath}
                }
            })
        }
        if($paths.Count -ne 1 -or -not (Test-Path -LiteralPath $paths[0] -PathType Leaf -ErrorAction Stop)){return 'Not verified'}
        $tokens=$null;$parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($paths[0],[ref]$tokens,[ref]$parseErrors)
        if($parseErrors.Count){return 'Not verified'}
        $inspection=Add-LauncherReportDetails (New-CheckResult 'Pass' '' '') $paths[0] ''
        $url=[string]$inspection.LauncherValues['URL']
        $id=[string]$inspection.LauncherValues['KIOSK ID']
        if($url -eq 'Not detected' -or $id -in @('','Not detected','Not verified')){return 'Not verified'}
        $resolved=Resolve-KioskUrl -Url $url
        if(@($resolved.BlockedIssues).Count){return 'Not verified'}
        return $id
    }catch{return 'Not verified'}
}

function Write-ThoroughConsoleHeader {
    param ([string]$Client, [string]$Device, [string]$Branch, [bool]$IsApply, [bool]$IsFinal=$false, [string]$KioskId)
    $mode=if ($IsFinal) { 'Thorough Check Report' } elseif ($IsApply) { 'Apply Fix' } else { 'Audit' }
    Write-Host ''
    Write-Host ('-'*60) -ForegroundColor DarkGray
    Write-ThoroughConsoleLine ('SELISE | '+(Get-ThoroughReportTitle -IsApply $IsApply -IsFinal $IsFinal).ToUpperInvariant()) -Indent ' ' -Color Cyan
    Write-Host ('-'*60) -ForegroundColor DarkGray
    Write-ThoroughConsoleLine ('Client : '+$Client) -Indent ' '
    Write-ThoroughConsoleLine ('Device : '+(Get-ThoroughReportDeviceLabel -DeviceType $Device -LauncherKioskId $KioskId)) -Indent ' '
    Write-ThoroughConsoleLine ('Mode   : '+$mode) -Indent ' '
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch -ne 'Not provided') {
        Write-ThoroughConsoleLine ('Branch : '+$Branch) -Indent ' '
    }
    Write-Host ('-'*60) -ForegroundColor DarkGray
}

function Start-AuditStep {
    param ([int]$Number, [string]$Name)
    # Retain timing for diagnostics without overlaying the menu or result log.
    if ($null -eq $script:AuditRunTimer) { $script:AuditRunTimer = [Diagnostics.Stopwatch]::StartNew() }
    $script:AuditStepTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-Verbose ('Step {0}: {1}' -f $Number,$Name)
}

function Write-AuditOperation {
    param ([string]$Message)
    Write-Verbose $Message
}

function Get-ThoroughConsoleNote {
    param ([string]$ItemTitle, [string]$FoundStateHtml, [string]$Status, [string]$ActionTaken)
    if ($ItemTitle -eq 'KIOSK Account' -and $FoundStateHtml -match '(?i)Missing') {
        return 'Account Missing. Please create manually. Dependent kiosk checks skipped.'
    }
    if ($ItemTitle -eq 'Administrative Accounts' -and $FoundStateHtml -match '(?is)Account Status:</span>\s*Missing\s*</div>|^\s*Account Missing(?:[.\s]|$)') { return 'Account Missing. Please create manually.' }
    if ($Status -eq 'Bypass' -and $ItemTitle -like 'lodctr /R*') { return 'Not performed in Audit mode; health not verified.' }
    if ($ItemTitle -eq 'Payment Gateway Middleware' -and $ActionTaken -match 'Payment Service version could not be detected') { return 'Payment Service version could not be detected.' }
    if ($ItemTitle -eq 'Payment Gateway Middleware' -and $ActionTaken -match 'Payment Service details not verified') { return 'Payment Service details could not be verified. See HTML report for details.' }
    if ($ItemTitle -eq 'Zabbix Agent 2' -and $ActionTaken -match 'hostname was not verified') { return 'Monitoring hostname could not be verified.' }
    if ($ItemTitle -eq 'Administrative Accounts') { return 'Account settings were not verified. See HTML report for details.' }
    if ($ItemTitle -like 'Windows Update*') { return 'Required service settings were not verified. See HTML report for details.' }
    $text=Convert-ReportHtmlToTerminalText $ActionTaken
    $text=($text -split ';\s*',2)[0]
    $text=($text -split '(?<=\.)\s+(?=[A-Z])',2)[0]
    if ($text -eq '-') { return 'Check not verified. See HTML report for details.' }
    if ($text.Length -gt 140) {
        $cut=$text.LastIndexOf(' ',110)
        if ($cut -le 0) { $cut=110 }
        $text=$text.Substring(0,$cut).TrimEnd()+ '... See HTML report for details.'
    }
    $text
}

function Add-AuditEntry {
    param ([int]$SectionNumber, [string]$SectionTitle, [string]$ItemTitle, [string]$ItemSub,
        [string]$Shortcut, [string]$FoundStateHtml, [string]$Status, [string]$ActionTaken, [switch]$DeferConsole)
    $auditRows.Add([PSCustomObject]@{
        SectionNumber = $SectionNumber; SectionTitle = $SectionTitle; ItemTitle = $ItemTitle
        ItemSub = $ItemSub; Shortcut = $Shortcut; FoundStateHtml = $FoundStateHtml
        Status = $Status; ActionTaken = $ActionTaken
    })
    if (-not $DeferConsole) { Write-ThoroughConsoleEntry -Row $auditRows[$auditRows.Count-1] -Number $auditRows.Count }
}

function Write-ThoroughConsoleEntry {
    param ($Row, [int]$Number)
    if((Get-Variable -Name BeforeApplyInspection -Scope Script -ErrorAction SilentlyContinue) -and $script:BeforeApplyInspection){return}
    $ItemTitle=$Row.ItemTitle; $ItemSub=$Row.ItemSub; $Status=$Row.Status
    $FoundStateHtml=$Row.FoundStateHtml; $ActionTaken=$Row.ActionTaken
    $legacyStopped=$Status -eq 'Offline' -and $ItemSub -eq 'Type: Old Payment Service'
    $label=if ($legacyStopped) { 'STOPPED' } else {
        switch ($Status) {
            'Pass' { 'PASS' }
            'Online' { 'ONLINE' }
            'Remediated' { 'FIXED' }
            'Fail' { 'FAIL' }
            'Offline' { 'OFFLINE' }
            'Bypass' { 'SKIP' }
            default { 'UNKNOWN' }
        }
    }
    $color=if ($legacyStopped -or $Status -eq 'Bypass') { 'DarkGray' } elseif ($Status -in @('Fail','Offline')) { 'Red' } elseif ($Status -in @('Pass','Online','Remediated')) { 'Green' } else { 'Yellow' }
    Write-Host ''
    Write-ThoroughConsoleLine ('[{0:D2}] {1,-7} {2}' -f $Number,$label,(Get-ThoroughReportComponentName $ItemTitle)) -Indent ' ' -Color $color
    if (-not $legacyStopped -and $Status -notin @('Pass','Online','Remediated')) {
        $note=Get-ThoroughConsoleNote -ItemTitle $ItemTitle -FoundStateHtml $FoundStateHtml -Status $Status -ActionTaken $ActionTaken
        Write-ThoroughConsoleLine $note -Indent (' '*14) -Color $color
    }
}

function Complete-ThoroughConsole {
    param ([bool]$IsApply, [int]$FailedCount, [bool]$IsFinal=$false)
    $mode=if ($IsFinal) { 'Thorough Check Report' } elseif ($IsApply) { 'Apply Fix' } else { 'Audit' }
    Write-Host ''
    Write-Host ('-'*60) -ForegroundColor DarkGray
    $message=if ($FailedCount -gt 0) { '{0} completed. {1} check(s) require attention.' -f $mode,$FailedCount } else { $mode+' completed.' }
    Write-ThoroughConsoleLine $message -Indent ' ' -Color $(if ($FailedCount -gt 0) { 'Yellow' } else { 'Gray' })
    Write-Host ''
}

function New-CheckResult {
    param ([string]$Status, [string]$Action, [string]$State)
    [pscustomobject]@{ Status = $Status; Action = $Action; State = $State }
}

function Get-ThoroughPayoutSchedules {
    param($Schedules,[string]$Provider)
    $selected=$Provider.Trim().ToUpperInvariant()
    if($selected -notin @('SIX','NETS','NEXIDE')){return}
    foreach($schedule in @($Schedules)){
        $scheduleProvider=([string](Get-ThoroughPaymentConfigValue $schedule 'Provider')).Trim().ToUpperInvariant()
        if($scheduleProvider -ceq $selected){$schedule}
    }
}

function New-ThoroughAppSettingsGroupRow {
    param ($Source, [string]$Name, [string]$ExpectedHtml, [string]$ObservedHtml, [bool]$Missing)
    [pscustomobject]@{
        SectionNumber=$Source.SectionNumber; SectionTitle=$Source.SectionTitle
        ItemTitle=$Name; ItemSub='appsettings.json'
        Shortcut=$Source.Shortcut; FoundStateHtml=$ObservedHtml; ExpectedHtml=$ExpectedHtml
        Status=$(if ($Missing) { 'Fail' } else { 'Pass' })
        ActionTaken=$(if ($Missing) { 'One or more values could not be collected; no configuration values changed' } else { 'Read only; no configuration values changed' })
    }
}

function Get-ThoroughFinalPrinterRow {
    param($Row,[bool]$AfterApply)
    $records=@(Get-ThoroughSettingRecords $Row.FoundStateHtml)
    $names=@($records | Where-Object {$_.Identity -and $_.Identity.Label -eq 'Printer Name'} | ForEach-Object {[regex]::Escape($_.Identity.Text)})
    $action=Convert-ReportHtmlToTerminalText ([string]$Row.ActionTaken)
    $markers=if($names.Count){@([regex]::Matches($action,'(?<Name>'+($names -join '|')+'):\s*'))}else{@()}
    $printers=@(foreach($record in $records){
        $status=@($record.Fields | Where-Object {$_.Kind -eq 'Field' -and $_.Label -eq 'Printer status'})
        if(-not $record.Identity -or $record.Identity.Label -ne 'Printer Name' -or $status.Count -ne 1 -or $status[0].Text -notin @('Active','Idle') -or $status[0].State -eq 'unverified'){continue}
        $name=[string]$record.Identity.Text
        if([string]::IsNullOrWhiteSpace($name) -or $name -match '(?i)^(?:Not verified|Not detected|Not recorded|Unknown)(?:[.!](?:\s.*)?)?$'){continue}
        $own=@(for($i=0;$i -lt $markers.Count;$i++){if($markers[$i].Groups['Name'].Value -ieq $name){$i}})
        $note=''
        if($own.Count -eq 1){
            $start=$markers[$own[0]].Index+$markers[$own[0]].Length
            $end=if($own[0]+1 -lt $markers.Count){$markers[$own[0]+1].Index}else{$action.Length}
            $note=$action.Substring($start,$end-$start).Trim(' ',';')
        }elseif($records.Count -eq 1){$note=$action}
        if($AfterApply -and ($own.Count -gt 1 -or [string]::IsNullOrWhiteSpace($note) -or $note -match '(?i)\bnot\s+verified\b|\breadback\b[^.;]*(?:fail|could not|unavailable)|(?:fail|could not)[^.;]*\breadback\b|\bnot reverified\b')){continue}
        $body=@($record.Fields | ForEach-Object {
            if($_.Kind -eq 'Field'){'<div><span class="kv-label">'+[Net.WebUtility]::HtmlEncode($_.Label)+':</span> '+$_.Html+'</div>'}else{$_.Html}
        }) -join ''
        [pscustomobject]@{SectionNumber=$Row.SectionNumber;SectionTitle=$Row.SectionTitle;ItemTitle=$name;ItemSub='Type: Receipt / POS Printer';Shortcut='';FoundStateHtml=('<div class="kv-block">'+$body+'</div>');Status=$Row.Status;ActionTaken=[Net.WebUtility]::HtmlEncode($note)}
    })
    if($printers.Count){New-ThoroughPrinterReportRow -Rows $printers}
}

function Add-ResultEntry {
    param ([int]$Section, [string]$Title, [string]$Item, [object]$Result)
    $shortcut = ''
    $stateHtml = [Net.WebUtility]::HtmlEncode($Result.State)
    $actionHtml = [Net.WebUtility]::HtmlEncode($Result.Action)
    if ($Result.PSObject.Properties['StateHtml']) { $stateHtml = $Result.StateHtml }
    if ($Result.PSObject.Properties['Shortcut']) { $shortcut = $Result.Shortcut }
    if ($Item -in @('Kiosk Auto-Login', 'System & Browser Policies')) { $shortcut = '<code>regedit</code>' }
    if ($Item -eq 'Kiosk Auto-Login') {
        $shortcut = New-ReportCommand @('regedit', 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon', 'reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName')
    }
    if ($Item -eq 'System & Browser Policies') {
        $shortcut = New-ReportCommand @('regedit', 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Edge" /s', 'reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" /v AllowEdgeSwipe')
    }
    if ($Result.PSObject.Properties['DetectedAccountNames'] -or $Result.PSObject.Properties['AccountName']) {
        $names=if ($Result.PSObject.Properties['DetectedAccountNames']) { @($Result.DetectedAccountNames) } else { @([string]$Result.AccountName) }
        $shortcut=New-AccountReportCommand -AccountNames $names
        if ($Result.PSObject.Properties['StateHtml']) { $stateHtml = $Result.StateHtml }
        $actionHtml = [Net.WebUtility]::HtmlEncode($Result.Action)
    }
    $rowCountBefore = if ($Result.PSObject.Properties['AccountResults']) { $auditRows.Count } else { -1 }
    Add-AuditEntry -SectionNumber $Section -SectionTitle $Title -ItemTitle $Item -ItemSub 'Verified configuration' `
        -Shortcut $shortcut -FoundStateHtml $stateHtml `
        -Status $Result.Status -ActionTaken $actionHtml
    # Attach metadata only to the row just created for this exact component.
    if ($Result.PSObject.Properties['AccountResults'] -and $auditRows.Count -eq ($rowCountBefore + 1)) {
        $row = $auditRows[$rowCountBefore]
        if ($row.SectionNumber -eq $Section -and $row.SectionTitle -eq $Title -and $row.ItemTitle -eq $Item) {
            $row | Add-Member -NotePropertyName AccountResults -NotePropertyValue @($Result.AccountResults)
        }
    }
}

function Set-ThoroughUrlParameter {
    param([string]$Url,[string]$Name,[string]$Value)
    $match=[regex]::Match($Url,'[?&]'+[regex]::Escape($Name)+'=(?<Value>[^&#]*)')
    if($match.Success){
        if([uri]::UnescapeDataString($match.Groups['Value'].Value.Replace('+',' ')) -ceq $Value){return $Url}
        return $Url.Remove($match.Groups['Value'].Index,$match.Groups['Value'].Length).Insert($match.Groups['Value'].Index,[uri]::EscapeDataString($Value))
    }
    # A bare key (restaurantId&) is a missing value, not a second parameter.
    $bare=[regex]::Match($Url,'(?<Prefix>[?&])'+[regex]::Escape($Name)+'(?=&|$)')
    if($bare.Success){return $Url.Insert($bare.Index+$bare.Length,'='+[uri]::EscapeDataString($Value))}
    return $Url+$(if($Url.Contains('?')){'&'}else{'?'})+$Name+'='+[uri]::EscapeDataString($Value)
}

function Get-PrinterHealth {
    param ($Printer, $CimPrinter)
    $state = [string]$Printer.PrinterStatus
    [uint32]$statusBits = 0
    $numericStatus = [uint32]::TryParse($state, [ref]$statusBits)
    $paused = ($CimPrinter.ExtendedPrinterStatus -eq 7) -or $(if ($numericStatus) { ($statusBits -band 1) -ne 0 } else { $state -match '(^|,\s*)Paused($|,)' })
    $offline = ($Printer.WorkOffline -eq $true -or $CimPrinter.WorkOffline -eq $true -or $CimPrinter.PrinterStatus -eq 7 -or $CimPrinter.ExtendedPrinterStatus -eq 8 -or $state -match 'Offline' -or ($numericStatus -and ($statusBits -band 128) -ne 0))
    # MSFT_Printer uses a bit mask; Win32_Printer ExtendedPrinterStatus uses
    # separate enum values. Preserve unavailable information before generic error.
    $unavailable = ($state -match '(?i)(^|,\s*)Not\s*Available($|,)' -or ($numericStatus -and ($statusBits -band 4096) -ne 0) -or $CimPrinter.ExtendedPrinterStatus -eq 11)
    $reportedError = ($CimPrinter.DetectedErrorState -ge 3 -or $CimPrinter.ExtendedPrinterStatus -eq 9)
    # Busy / Printing / Processing are working states, not an offline printer.
    if ($numericStatus) {
        [uint32]$workingBits = 256 + 512 + 1024 + 8192 + 16384 + 32768 + 65536 + 16777216
        $healthy = ($statusBits -band (-bnot $workingBits)) -eq 0
    } else {
        $badStates = @($state -split ',\s*' | Where-Object { $_ -notmatch '^(Normal|Printing|Busy|Processing|Initializing|WarmingUp|IOActive|Waiting|PowerSave)$' })
        $healthy = (-not [string]::IsNullOrWhiteSpace($state)) -and $badStates.Count -eq 0
    }
    $active = ($state -match 'Printing|Busy|Processing|Initializing|WarmingUp|IOActive' -or
        ($numericStatus -and ($statusBits -band (256 + 512 + 1024 + 16384 + 32768)) -ne 0) -or $CimPrinter.PrinterStatus -in @(4, 5))
    $displayState = if ($unavailable) { 'Not available' } elseif ($offline) { 'Offline' } elseif ($paused) { 'Paused' } elseif (-not $healthy -or $reportedError) { 'Error' } elseif ($active) { 'Active' } else { 'Idle' }
    [PSCustomObject]@{ Paused = [bool]$paused; Healthy = [bool]($displayState -in @('Idle','Active')); State = $displayState }
}

function ConvertFrom-KioskEdgeArguments {
    param([string]$Text)
    $arguments=[Collections.Generic.List[string]]::new()
    $token=[Text.StringBuilder]::new()
    $quoted=$false; $started=$false
    for($index=0;$index -lt $Text.Length;$index++){
        $character=$Text[$index]
        if($character -eq '\'){
            $slashes=0
            while($index -lt $Text.Length -and $Text[$index] -eq '\'){$slashes++;$index++}
            if($index -lt $Text.Length -and $Text[$index] -eq '"'){
                [void]$token.Append(('\' * [int][Math]::Floor($slashes/2)))
                if($slashes % 2){[void]$token.Append('"')}else{$quoted=-not $quoted}
                $started=$true
            }else{
                [void]$token.Append(('\' * $slashes));$started=$true;$index--
            }
        }elseif($character -eq '"'){
            $quoted=-not $quoted;$started=$true
        }elseif([char]::IsWhiteSpace($character) -and -not $quoted){
            if($started){$arguments.Add($token.ToString());[void]$token.Clear();$started=$false}
        }else{[void]$token.Append($character);$started=$true}
    }
    if($quoted){throw 'Edge arguments contain unmatched quotes.'}
    if($started){$arguments.Add($token.ToString())}
    return ,$arguments.ToArray()
}

function Set-KioskMainAllowlistOrigin {
    if(-not (Test-CanApply)){throw 'Allowlist URL repair requires Apply Fix.'}
    $path='HKLM:\SOFTWARE\Policies\Microsoft\Edge\LocalNetworkAccessAllowedForUrls'
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    if($key.GetValueNames() -notcontains '1' -or $key.GetValueKind('1').ToString() -ne 'String'){throw 'The main allowlist entry type is not verified.'}
    $old=[string]$key.GetValue('1')
    $expected=[string]$script:KioskClientSettings.Origin
    if($old -ieq $expected){return $false}
    if(-not (Test-KioskKnownWrongOrigin $old)){throw 'An unknown allowlist origin requires manual review.'}
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    if($key.GetValueKind('1').ToString() -ne 'String' -or $key.GetValue('1') -cne $old){throw 'The allowlist changed during inspection.'}
    $started=$false
    try{
        $started=$true
        Set-ItemProperty -LiteralPath $path -Name '1' -Value $expected -ErrorAction Stop
        $key=Get-Item -LiteralPath $path -ErrorAction Stop
        if($key.GetValueKind('1').ToString() -ne 'String' -or $key.GetValue('1') -cne $expected){throw 'Allowlist URL readback failed.'}
    }catch{
        $reason=$_.Exception.Message
        if($started){
            try{
                $key=Get-Item -LiteralPath $path -ErrorAction Stop
                $value=$key.GetValue('1')
                if($key.GetValueKind('1').ToString() -ne 'String' -or $value -cnotin @($old,$expected)){throw 'Allowlist changed again; automatic restoration stopped.'}
                if($value -cne $old){Set-ItemProperty -LiteralPath $path -Name '1' -Value $old -ErrorAction Stop}
                $key=Get-Item -LiteralPath $path -ErrorAction Stop
                if($key.GetValueKind('1').ToString() -ne 'String' -or $key.GetValue('1') -cne $old){throw 'Allowlist restoration readback failed.'}
                $reason+=' Original allowlist entry restored.'
            }catch{$reason+=' Allowlist restoration could not be verified: '+$_.Exception.Message}
        }
        throw $reason
    }
    return $true
}
