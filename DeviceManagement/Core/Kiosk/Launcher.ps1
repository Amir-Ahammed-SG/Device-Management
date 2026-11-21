# Shared kiosk launcher functions. Dot-sourced into the engine's scope.

function Get-ThoroughDeviceHostname {
    # Keep unavailable detection explicit; never substitute a shortened environment name.
    try {
        $systems=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property DNSHostName -ErrorAction Stop)
        if($systems.Count -ne 1) { return 'Not detected' }
        $name=([string]$systems[0].DNSHostName).Trim()
        if($name.Length -lt 1 -or $name.Length -gt 63 -or $name -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$') { return 'Not detected' }
        return $name
    } catch { return 'Not detected' }
}

function Get-KioskLaunchTaskHistory {
    param([object[]]$Tasks)
    $fields=[ordered]@{'Last Run'='Not recorded'}
    if($Tasks.Count -eq 1){
        try{
            if(-not [string]$Tasks[0].TaskPath){throw 'Task path unavailable'}
            $info=Get-ScheduledTaskInfo -TaskName 'Launch Kiosk' -TaskPath ([string]$Tasks[0].TaskPath) -ErrorAction Stop
            foreach($label in @('Last Run')){
                $property='LastRunTime'
                $value=$info.$property
                $notRun=$label -eq 'Last Run' -and $info.PSObject.Properties['LastTaskResult'] -and [int64]$info.LastTaskResult -eq 267011
                if($notRun -or ($value -is [datetime] -and ($value.Year -le 1900 -or $value -eq [datetime]::new(1999,11,30)))){$fields[$label]='Not recorded';continue}
                $fields[$label]=if($value -is [datetime] -and $value.Year -gt 1900){$value.ToString('dd-MMM-yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)}elseif($value -is [datetime]){'Not recorded'}else{'Not verified'}
            }
        }catch{$fields['Last Run']='Not verified'}
    }elseif($Tasks.Count -gt 1){$fields['Last Run']='Not verified'}
    $fields
}

function Test-ThoroughHostname {
    param([string]$Value)
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253){return $false}
    foreach($label in $Value.Split('.')){
        if($label.Length -lt 1 -or $label.Length -gt 63 -or $label -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$'){return $false}
    }
    return $true
}

function Read-ThoroughFixHostname {
    param([string]$SuggestedName,[string]$SuppliedName)
    if(-not (Test-CanApply)){throw 'Hostname input is available only during Apply Fix.'}
    if(-not [string]::IsNullOrWhiteSpace($SuppliedName)){
        $name=$SuppliedName.Trim()
        if(-not (Test-ThoroughHostname $name)){throw 'The supplied hostname is invalid.'}
        return $name
    }
    do {
        $prompt=if(Test-ThoroughHostname $SuggestedName){
            Write-Host 'Press Enter to keep it, or type a different hostname.' -ForegroundColor Gray
            'Hostname ['+$SuggestedName+']'
        }else{'Hostname'}
        $name=([string](Read-Host $prompt)).Trim()
        if(-not $name -and (Test-ThoroughHostname $SuggestedName)){$name=$SuggestedName}
        if(Test-ThoroughHostname $name){return $name}
        Write-Host 'Enter a valid hostname, or press Enter to confirm the suggested name.' -ForegroundColor Yellow
    } while($true)
}

function Read-ThoroughTextFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    foreach($entry in @($full,[IO.Path]::GetDirectoryName($full))){
        if(([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked configuration path requires manual review.'}
    }
    $bytes=[IO.File]::ReadAllBytes($full)
    $encoding=[Text.UTF8Encoding]::new($false,$true);$offset=0
    if($bytes.Length -ge 4 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0){$encoding=[Text.UTF32Encoding]::new($false,$true,$true);$offset=4}
    elseif($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255){$encoding=[Text.UTF32Encoding]::new($true,$true,$true);$offset=4}
    elseif($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){$offset=3}
    elseif($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254){$encoding=[Text.UnicodeEncoding]::new($false,$true,$true);$offset=2}
    elseif($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255){$encoding=[Text.UnicodeEncoding]::new($true,$true,$true);$offset=2}
    [pscustomobject]@{Path=$full;Bytes=$bytes;Encoding=$encoding;PreambleLength=$offset;Text=$encoding.GetString($bytes,$offset,$bytes.Length-$offset)}
}

function Write-ThoroughTextChange {
    param([Parameter(Mandatory=$true)]$Original,[Parameter(Mandatory=$true)][string]$Text,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'Configuration writes are disabled outside Apply Fix.'}
    if($Text -ceq $Original.Text){return [pscustomobject]@{Changed=$false;BackupPath=$null}}
    if([string]::IsNullOrWhiteSpace($BackupFolder)){
        $BackupFolder='C:\Thorough Check\Restore Points'
    }
    $body=$Original.Encoding.GetBytes($Text)
    $candidate=[byte[]]::new($Original.PreambleLength+$body.Length)
    if($Original.PreambleLength){[Buffer]::BlockCopy($Original.Bytes,0,$candidate,0,$Original.PreambleLength)}
    [Buffer]::BlockCopy($body,0,$candidate,$Original.PreambleLength,$body.Length)
    $stream=$null;$started=$false;$backup=$null
    try {
        $stream=[IO.File]::Open($Original.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $current=Read-KioskPinchStream $stream
        if([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($Original.Bytes)){throw 'The configuration changed during inspection; no changes were made.'}
        [void][IO.Directory]::CreateDirectory($BackupFolder)
        $backup=Join-Path $BackupFolder ([IO.Path]::GetFileName($Original.Path)+'.'+[guid]::NewGuid().ToString('N')+'.bak')
        $backupStream=[IO.File]::Open($backup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$backupStream.Write($Original.Bytes,0,$Original.Bytes.Length);$backupStream.Flush($true)}finally{$backupStream.Dispose()}
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -cne [Convert]::ToBase64String($Original.Bytes)){throw 'Configuration backup verification failed.'}
        $started=$true
        Write-KioskPinchStream -Stream $stream -Bytes $candidate
        if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($candidate)){throw 'Configuration write readback failed.'}
    } catch {
        $reason=$_.Exception.Message
        if($started){
            try {
                Write-KioskPinchStream -Stream $stream -Bytes $Original.Bytes
                if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($Original.Bytes)){throw 'Restore readback failed.'}
                $reason+=' Original configuration restored.'
            } catch {$reason+=' Original configuration restoration could not be verified. Please check manually.'}
        }
        throw $reason
    } finally {if($stream){$stream.Dispose()}}
    [pscustomobject]@{Changed=$true;BackupPath=$backup;Path=$Original.Path;BeforeBytes=$Original.Bytes;AfterBytes=$candidate}
}

function Restore-ThoroughTextChange {
    param([Parameter(Mandatory=$true)]$Change)
    if(-not (Test-CanApply)){throw 'Configuration restoration requires Apply Fix.'}
    $stream=[IO.File]::Open($Change.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($Change.AfterBytes)){throw 'The configuration changed again; automatic restoration was stopped.'}
        Write-KioskPinchStream -Stream $stream -Bytes $Change.BeforeBytes
        if([Convert]::ToBase64String((Read-KioskPinchStream $stream)) -cne [Convert]::ToBase64String($Change.BeforeBytes)){throw 'Restoration readback failed.'}
    } finally {$stream.Dispose()}
}

function Test-KioskKnownWrongOrigin {
    param([string]$Origin)
    if($Origin -ieq $script:KioskClientSettings.Origin -or -not $script:KioskClientSettings.ContainsKey('ClientOrigins')){return $false}
    return @($script:KioskClientSettings.ClientOrigins.Values | Where-Object {$_ -ieq $Origin}).Count -gt 0
}

function Set-KioskLauncherOrigin {
    param([Parameter(Mandatory=$true)][string]$Path,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'Launcher URL repair requires Apply Fix.'}
    $original=Read-ThoroughTextFile $Path
    if($original.Text -match '(?im)^# SIG # Begin signature block'){throw 'The launcher is signed; URL repair requires manual review.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($original.Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The launcher has invalid syntax.'}
    $strings=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -or ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $node.NestedExpressions.Count -eq 0)},$true))
    $targets=@(foreach($literal in $strings){foreach($url in [regex]::Matches($literal.Value,'https://[A-Za-z0-9.-]+/[^\s"'']*')){[pscustomobject]@{Literal=$literal;Url=$url.Value}}})
    if($targets.Count -ne 1){throw 'A single static launcher URL could not be verified.'}
    $target=$targets[0]
    $uri=$null
    if(-not [uri]::TryCreate($target.Url,[UriKind]::Absolute,[ref]$uri)){throw 'The launcher URL is invalid.'}
    $oldOrigin=$uri.GetLeftPart([UriPartial]::Authority)
    if($oldOrigin -ieq $script:KioskClientSettings.Origin){return [pscustomobject]@{Changed=$false;BackupPath=$null}}
    if(-not (Test-KioskKnownWrongOrigin $oldOrigin)){throw 'An unknown launcher origin requires manual review.'}
    $url=$script:KioskClientSettings.Origin+$target.Url.Substring($oldOrigin.Length)
    $inspection=Resolve-KioskUrl -Url $url
    if(@($inspection.Issues | Where-Object {$_ -ne 'Missing host'}).Count){throw 'The onboarding route or URL parameters require manual review.'}
    $raw=$target.Literal.Extent.Text
    if([regex]::Matches($raw,[regex]::Escape($target.Url)).Count -ne 1){throw 'An escaped or ambiguous URL requires manual review.'}
    $replacement=$raw.Replace($target.Url,$url)
    $updated=$original.Text.Remove($target.Literal.Extent.StartOffset,$raw.Length).Insert($target.Literal.Extent.StartOffset,$replacement)
    [void][Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The proposed launcher failed syntax validation.'}
    $change=Write-ThoroughTextChange -Original $original -Text $updated -BackupFolder $BackupFolder
    try{
        $verified=Add-LauncherReportDetails (New-CheckResult 'Fail' '' '') $Path ''
        if($verified.LauncherValues['URL'] -cne $url){throw 'Launcher URL readback failed.'}
    }catch{
        $reason=$_.Exception.Message
        try{Restore-ThoroughTextChange $change;$reason+=' Original launcher restored.'}catch{$reason+=' Launcher restoration could not be verified.'}
        throw $reason
    }
    return $change
}

function Set-KioskLauncherHostname {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Hostname,[string]$BackupFolder)
    if(-not (Test-CanApply)){throw 'Launcher repair is disabled outside Apply Fix.'}
    if(-not (Test-ThoroughHostname $Hostname)){throw 'The confirmed launcher hostname is invalid.'}
    $original=Read-ThoroughTextFile $Path
    if($original.Text -match '(?im)^# SIG # Begin signature block'){throw 'The launcher is signed; hostname changes require manual review.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($original.Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The launcher has invalid syntax; no changes made.'}
    $strings=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -or ($node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $node.NestedExpressions.Count -eq 0)},$true))
    $targets=@(foreach($literal in $strings){foreach($url in [regex]::Matches($literal.Value,'https://[A-Za-z0-9.-]+/[^\s"'']*')){[pscustomobject]@{Literal=$literal;Url=$url.Value}}})
    if($targets.Count -ne 1){throw 'A single static launcher URL could not be verified; no hostname changed.'}
    $target=$targets[0]
    $inspection=Resolve-KioskUrl -Url $target.Url
    $blockedIssues=@($inspection.Issues | Where-Object { $_ -ne 'Missing host' })
    if($blockedIssues.Count){throw (($blockedIssues -join '; ')+'. No hostname changed.')}
    $match=[regex]::Match($target.Url,'[?&]host=(?<Value>[^&#]*)')
    if($match.Success){
        $old=[uri]::UnescapeDataString($match.Groups['Value'].Value.Replace('+',' '))
        if($old -ieq $Hostname){return [pscustomobject]@{Changed=$false;BackupPath=$null;PreviousHostname=$old;Hostname=$Hostname}}
        $url=$target.Url.Remove($match.Groups['Value'].Index,$match.Groups['Value'].Length).Insert($match.Groups['Value'].Index,[uri]::EscapeDataString($Hostname))
    } else {
        $old='(missing)'
        $separator=if($target.Url.Contains('?')){'&'}else{'?'}
        $hashIndex=$target.Url.IndexOf('#',[Math]::Max(0,$target.Url.IndexOf('?')))
        if($hashIndex -ge 0){
            $url=$target.Url.Insert($hashIndex,$separator+'host='+[uri]::EscapeDataString($Hostname))
        } else {
            $url=$target.Url+$separator+'host='+[uri]::EscapeDataString($Hostname)
        }
    }
    $raw=$target.Literal.Extent.Text
    if([regex]::Matches($raw,[regex]::Escape($target.Url)).Count -ne 1){throw 'An escaped or ambiguous launcher URL requires manual review.'}
    $replacement=$raw.Replace($target.Url,$url)
    $updated=$original.Text.Remove($target.Literal.Extent.StartOffset,$raw.Length).Insert($target.Literal.Extent.StartOffset,$replacement)
    $null=[Management.Automation.Language.Parser]::ParseInput($updated,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The proposed launcher failed syntax validation.'}
    $change=Write-ThoroughTextChange -Original $original -Text $updated -BackupFolder $BackupFolder
    $change|Add-Member NoteProperty PreviousHostname $old
    $change|Add-Member NoteProperty Hostname $Hostname
    return $change
}

function Resolve-KioskUrl {
    param([string]$Url,[string]$Restaurant,[string]$Kiosk,[string]$Hostname)
    $issues=[Collections.Generic.List[string]]::new()
    $blocked=[Collections.Generic.List[string]]::new()
    $missing=[Collections.Generic.List[string]]::new()
    $parameters=@{}
    $queryStart=$Url.IndexOf('?')
    $prefix=if ($queryStart -ge 0) {$Url.Substring(0,$queryStart)} else {$Url}
    if ($prefix -ine ($script:KioskClientSettings.Origin+$script:KioskClientSettings.OnboardingPath)) {$blocked.Add(('Unexpected '+$script:KioskClientSettings.ClientType+' kiosk URL path'))}
    if (-not $Url.StartsWith(($script:KioskClientSettings.Origin+'/'),[StringComparison]::OrdinalIgnoreCase)) {$blocked.Add('Unexpected kiosk URL origin')}
    if ($queryStart -ge 0) {
        foreach ($part in $Url.Substring($queryStart+1).Split('&')) {
            if (-not $part) {continue}
            $pair=$part -split '=',2
            $key=[uri]::UnescapeDataString($pair[0]).ToLowerInvariant()
            if ($key -notin @('restaurantid','kioskid','host','hostname')) {continue}
            if (-not $parameters.ContainsKey($key)) {$parameters[$key]=@()}
            $parameters[$key]+=$(if ($pair.Count -eq 2) {[uri]::UnescapeDataString($pair[1].Replace('+',' ')).Trim()} else {''})
            $canonical=@{restaurantid='restaurantId';kioskid='kioskId';host='host';hostname='hostname'}[$key]
            if ($pair[0] -cne $canonical) {$blocked.Add("Noncanonical $canonical parameter")}
        }
    }
    if ($parameters.ContainsKey('hostname')) {$blocked.Add('Unsupported hostname parameter requires manual review')}
    foreach ($key in @('restaurantId','kioskId','host')) {
        $values=@($parameters[$key.ToLowerInvariant()])
        if ($values.Count -gt 1) {$blocked.Add("Duplicate or conflicting $key")}
        elseif (-not $values.Count -or [string]::IsNullOrWhiteSpace([string]$values[0])) {$missing.Add($key)}
    }
    foreach ($issue in $blocked) {$issues.Add($issue)}
    foreach ($key in $missing) {$issues.Add('Missing '+$key)}
    [pscustomobject]@{URL=$Url;Issues=@($issues);BlockedIssues=@($blocked);Missing=@($missing)}
}

function Get-ThoroughLauncherEdit {
    param([string]$Path)
    $original=Read-ThoroughTextFile $Path
    if($original.Text -match '(?im)^# SIG # Begin signature block'){throw 'A signed launcher requires manual review.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($original.Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The launcher has invalid syntax.'}
    $literals=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -or ($n -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $n.NestedExpressions.Count -eq 0)},$true))
    $targets=@(foreach($literal in $literals){foreach($match in [regex]::Matches($literal.Value,$script:KioskClientSettings.LauncherUrlPattern)){[pscustomobject]@{Literal=$literal;Url=$match.Value}}})
    if($targets.Count -ne 1){throw 'A single static launcher URL is required. Manual action required.'}
    $target=$targets[0];$uri=$null
    if(-not [uri]::TryCreate($target.Url,[UriKind]::Absolute,[ref]$uri)){throw 'The launcher URL is invalid.'}
    $origin=$uri.GetLeftPart([UriPartial]::Authority)
    if($origin -ine $script:KioskClientSettings.Origin -and -not (Test-KioskKnownWrongOrigin $origin)){throw 'An unknown launcher origin requires manual review.'}
    $candidate=$script:KioskClientSettings.Origin+$target.Url.Substring($origin.Length)
    $queryIndex=$candidate.IndexOf('?')
    if($queryIndex -ge 0 -and $candidate.IndexOf('#',$queryIndex) -ge 0){throw 'An additional URL fragment requires manual review.'}
    $resolved=Resolve-KioskUrl -Url $candidate
    if(@($resolved.BlockedIssues).Count){throw ($resolved.BlockedIssues -join '; ')}
    if([regex]::Matches($target.Literal.Extent.Text,[regex]::Escape($target.Url)).Count -ne 1){throw 'An escaped launcher URL requires manual review.'}
    [pscustomobject]@{Original=$original;Literal=$target.Literal;Url=$target.Url;Candidate=$candidate;OriginChanged=($origin -ine $script:KioskClientSettings.Origin)}
}

function Read-ThoroughLauncherId {
    param([string]$Label,[string]$Current,[string]$Supplied)
    if(-not (Test-CanApply)){throw 'Launcher input requires Apply Fix.'}
    do{
        $value=if($Supplied){$Supplied.Trim()}else{
            $prompt=if($Current -and $Current -ne 'Not detected'){'Verify '+$Label+' ['+$Current+'] (Enter to keep, or enter a new value)'}else{$Label+' (required)'}
            ([string](Read-Host $prompt)).Trim()
        }
        if(-not $value -and $Current -and $Current -ne 'Not detected'){$value=$Current}
        if($value.Length -gt 0 -and $value.Length -le 256 -and $value -notmatch '[\x00-\x1f\x7f]'){return $value}
        if($Supplied){throw ('The supplied '+$Label+' is invalid.')}
        Write-Host ('Enter a non-empty '+$Label+' (maximum 256 characters).') -ForegroundColor Yellow
    }while($true)
}

function New-ThoroughLauncherPlan {
    param([string]$Path,[string]$Restaurant,[string]$Kiosk,[string]$Hostname)
    if(-not (Test-CanApply)){throw 'Launcher planning requires Apply Fix.'}
    $edit=Get-ThoroughLauncherEdit $Path
    $values=(Add-LauncherReportDetails (New-CheckResult 'Fail' '' '') $Path '').LauncherValues
    Write-Host ('URL Origin: '+$script:KioskClientSettings.Origin) -ForegroundColor Cyan
    if($edit.OriginChanged){Write-Host ('The URL origin will change to '+$script:KioskClientSettings.ClientType+'. Verify the Restaurant ID for this client and branch; it may differ from the current value.') -ForegroundColor Yellow}
    $restaurantValue=Read-ThoroughLauncherId -Label 'Restaurant ID' -Current $values['Restaurant ID'] -Supplied $Restaurant
    $kioskValue=Read-ThoroughLauncherId -Label 'Kiosk ID' -Current $values['KIOSK ID'] -Supplied $Kiosk
    $hostnameValue=Read-ThoroughFixHostname -SuggestedName (Get-ThoroughDeviceHostname) -SuppliedName $Hostname
    $url=Set-ThoroughUrlParameter $edit.Candidate 'restaurantId' $restaurantValue
    $url=Set-ThoroughUrlParameter $url 'kioskId' $kioskValue
    $url=Set-ThoroughUrlParameter $url 'host' $hostnameValue
    if(@((Resolve-KioskUrl $url).Issues).Count){throw 'The proposed launcher URL failed validation.'}
    $raw=$edit.Literal.Extent.Text
    $text=$edit.Original.Text.Remove($edit.Literal.Extent.StartOffset,$raw.Length).Insert($edit.Literal.Extent.StartOffset,$raw.Replace($edit.Url,$url))
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'The proposed launcher failed syntax validation.'}
    [pscustomobject]@{Path=$Path;Original=$edit.Original;Text=$text;Url=$url;Restaurant=$restaurantValue;Kiosk=$kioskValue;Hostname=$hostnameValue;Change=$null;Verified=$false}
}

function Invoke-ThoroughLauncherPlan {
    param($Plan,[string]$Path,[string]$ShortcutPath)
    if(-not (Test-CanApply)){throw 'Launcher changes require Apply Fix.'}
    if([IO.Path]::GetFullPath($Path) -ine [IO.Path]::GetFullPath($Plan.Path)){throw 'The kiosk launcher selection changed after preflight.'}
    try{
        $current=Read-ThoroughTextFile $Path
        if([Convert]::ToBase64String($current.Bytes) -cne [Convert]::ToBase64String($Plan.Original.Bytes)){throw 'The launcher changed after preflight; no values were overwritten.'}
        $Plan.Change=Write-ThoroughTextChange -Original $Plan.Original -Text $Plan.Text
        $result=Add-LauncherReportDetails (New-CheckResult 'Pass' 'Launcher URL, Restaurant ID, Kiosk ID and hostname verified. Restart Edge to load any launcher changes.' '') $Path $ShortcutPath
        if($result.LauncherValues['URL'] -cne $Plan.Url){throw 'Launcher URL readback failed.'}
        $Plan.Verified=$true
        if($Plan.Change.Changed){$result.Action='Updated launcher settings; readback verified. Backup: '+$Plan.Change.BackupPath+'. Restart Edge to load the updated launcher.'}
        else{$result.Action='Existing launcher values verified without changes.'}
        return $result
    }catch{
        $Plan.Verified=$false;$reason=$_.Exception.Message
        if($Plan.Change -and $Plan.Change.Changed){try{Restore-ThoroughTextChange $Plan.Change}catch{$reason+=' Launcher restoration could not be verified.'}}
        return Add-LauncherReportDetails (New-CheckResult 'Fail' ('Launcher update failed: '+$reason+' Manual action required.') '') $Path $ShortcutPath
    }
}

function Repair-LauncherDetails {
    param([string]$Path,[string]$ShortcutPath,[string]$Restaurant,[string]$Kiosk,[string]$Hostname)
    if((Test-CanApply) -and (Get-Variable -Name ConfirmedLauncherPlan -Scope Script -ErrorAction SilentlyContinue) -and $script:ConfirmedLauncherPlan){
        return Invoke-ThoroughLauncherPlan -Plan $script:ConfirmedLauncherPlan -Path $Path -ShortcutPath $ShortcutPath
    }
    # Inspect existing values; Apply may repair a known client origin and confirmed host.
    $result=Add-LauncherReportDetails (New-CheckResult 'Fail' 'Launcher inspected; existing values preserved.' '') $Path $ShortcutPath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {$result.Action='Launcher script is missing. Manual action required.';return $result}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) {$result.Action='Launcher syntax is invalid. Manual action required.';return $result}
    $url=$result.LauncherValues['URL']
    if ($url -eq 'Not detected') {$result.Action='A single supported static URL was not identified. Manual action required.';return $result}
    $originChange=$null;$originAction=''
    $currentUri=$null
    if((Test-CanApply) -and [uri]::TryCreate($url,[UriKind]::Absolute,[ref]$currentUri) -and (Test-KioskKnownWrongOrigin ($currentUri.GetLeftPart([UriPartial]::Authority)))){
        if(-not (Test-ThoroughHostname $Hostname)){$result.Action='The confirmed hostname is not verified; no launcher values changed.';return $result}
        try{
            $originChange=Set-KioskLauncherOrigin -Path $Path
            $result=Add-LauncherReportDetails $result $Path $ShortcutPath
            $url=$result.LauncherValues['URL']
            $originAction='Updated launcher URL origin for '+$script:KioskClientSettings.ClientType+'; readback verified. Backup: '+$originChange.BackupPath+'. Restart Edge to load the updated launcher. '
        }catch{
            $reason=$_.Exception.Message
            if($originChange -and $originChange.Changed){try{Restore-ThoroughTextChange $originChange}catch{$reason+=' Launcher restoration could not be verified.'}}
            $result=Add-LauncherReportDetails $result $Path $ShortcutPath
            $result.Action='Launcher URL repair failed: '+$reason+' Manual action required.';return $result
        }
    }
    $inspection=Resolve-KioskUrl -Url $url
    $blockedIssues=if(Test-CanApply){@($inspection.Issues | Where-Object { $_ -ne 'Missing host' })}else{@($inspection.Issues)}
    if ($blockedIssues.Count) {$result.Action=($blockedIssues -join '; ')+'. Manual action required. No launcher values changed.';return $result}
    $expected=if(Test-CanApply){$Hostname}else{Get-ThoroughDeviceHostname}
    if(-not (Test-ThoroughHostname $expected)){$result.Action='The expected device/launcher hostname is not verified. Manual action required.';return $result}
    if($result.LauncherValues['Host Name'] -ine $expected -or $inspection.Missing -contains 'host'){
        if(-not (Test-CanApply)){$result.Action='Launcher hostname differs from the Windows device hostname. Apply Fix can update the host parameter.';return $result}
        $change=$null
        try {
            $change=Set-KioskLauncherHostname -Path $Path -Hostname $expected
            $result=Add-LauncherReportDetails $result $Path $ShortcutPath
            if($result.LauncherValues['Host Name'] -ine $expected){throw 'Launcher hostname readback failed.'}
            $result.Action='Updated launcher hostname from '+$change.PreviousHostname+' to '+$expected+'; readback verified. Backup: '+$change.BackupPath+'. Restart Edge to load the updated launcher.'
        } catch {
            $reason=$_.Exception.Message
            foreach($repair in @($change,$originChange)){
                if($repair -and $repair.Changed){try{Restore-ThoroughTextChange $repair}catch{$reason+=' Launcher restoration could not be verified: '+$_.Exception.Message}}
            }
            $result=Add-LauncherReportDetails $result $Path $ShortcutPath
            $result.Action='Launcher hostname could not be fully verified: '+$reason+' Manual action required.';return $result
        }
    }else{$result.Action=if($originChange -and $originChange.Changed){'Launcher parameters and confirmed hostname verified.'}else{'Existing launcher values verified without changes. Verify operation after sign-in.'}}
    $result.Action=$originAction+$result.Action
    $result.Status='Pass'
    return $result
}

function Test-KioskStartupBatch {
    param ([string]$Batch, [string]$LaunchPath)
    if (-not (Test-Path -LiteralPath $Batch -PathType Leaf)) { return $false }
    $content = [IO.File]::ReadAllText($Batch)
    $matches = [regex]::Matches($content, '(?im)\bpowershell(?:\.exe)?\b[^\r\n]*?\s-File\s+"([^"]+)"')
    if ($matches.Count -ne 1) { return $false }
    $target = $matches[0].Groups[1].Value
    if ($target.StartsWith('%USERPROFILE%', [StringComparison]::OrdinalIgnoreCase)) {
        $profile = Split-Path (Split-Path $LaunchPath -Parent) -Parent
        $target = $profile + $target.Substring('%USERPROFILE%'.Length)
    }
    if (-not [IO.Path]::IsPathRooted($target) -or $target -match '%') { return $false }
    return [IO.Path]::GetFullPath($target).Equals([IO.Path]::GetFullPath($LaunchPath),[StringComparison]::OrdinalIgnoreCase)
}

function Test-KioskDesktopShortcut {
    param ([string]$Batch, [string]$LaunchPath, [string]$Shortcut)
    if (-not (Test-Path -LiteralPath $Shortcut -PathType Leaf)) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Shortcut)
    if ($link.TargetPath -ieq $Batch -and [string]::IsNullOrWhiteSpace($link.Arguments)) { return $true }
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $LaunchPath
    return ($link.TargetPath -ieq $powerShell -and $link.Arguments -ceq $arguments)
}

function Verify-KioskLaunchTargets {
    param ([string]$Batch, [string]$Shortcut, [string]$LaunchPath)
    if ([string]::IsNullOrWhiteSpace($LaunchPath)) {
        throw 'Launcher path is required for read-only target verification; no files changed.'
    }
    if (-not (Test-KioskStartupBatch -Batch $Batch -LaunchPath $LaunchPath)) { throw 'Startup BAT is missing or its launcher target could not be verified; no Startup files changed.' }
    if (-not (Test-KioskDesktopShortcut -Batch $Batch -LaunchPath $LaunchPath -Shortcut $Shortcut)) { throw 'Desktop shortcut is missing or its target differs; existing shortcut preserved.' }
    return 'Startup BAT and desktop shortcut targets inspected; existing files preserved.'
}

function Invoke-KioskLauncherConfiguration {
    param ([string]$UserName, [string]$Restaurant, [string]$Kiosk, [string]$Hostname)
    $base = Initialize-KioskProfile $UserName
    $launch = Join-Path $base 'Scripts\LaunchKiosk.ps1'
    $batch = Join-Path $base 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
    $desktop = Join-Path $base 'Desktop'
    $shortcut = Join-Path $desktop 'Launch Kiosk.lnk'
    $result = Repair-LauncherDetails -Path $launch -ShortcutPath $shortcut -Restaurant $Restaurant -Kiosk $Kiosk -Hostname $Hostname
    $result = Add-LauncherReportDetails $result $launch $shortcut $batch
    if (-not (Test-Path -LiteralPath $batch -PathType Leaf)) {
        $result.Status = 'Fail'
        $result.Action += ' Startup BAT is missing. Manual action required. Desktop shortcut was not created.'
        return $result
    }
    if ($result.Status -ne 'Pass') { return $result }
    $notes = [Collections.Generic.List[string]]::new()
    $notes.Add($result.Action)
    if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf) -and (Test-CanApply)) {
        $createdShortcut = $false
        try {
            if (-not (Test-Path -LiteralPath $desktop -PathType Container)) { throw 'Desktop folder is missing; no folders were created.' }
            if (-not (Test-KioskStartupBatch -Batch $batch -LaunchPath $launch)) { throw 'Existing Startup BAT target is not verified; desktop shortcut was not created.' }
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($shortcut)
            $link.TargetPath=$batch; $link.Arguments=''
            $link.WorkingDirectory = Split-Path $launch -Parent
            $link.Description = 'Launch existing Kiosk Front-End'
            if (Test-Path -LiteralPath $shortcut) { throw 'Desktop shortcut appeared during inspection; existing file preserved.' }
            $createdShortcut = $true
            $link.Save()
            if (-not (Test-KioskDesktopShortcut -Batch $batch -LaunchPath $launch -Shortcut $shortcut)) { throw 'Created desktop shortcut target could not be verified.' }
            $notes.Add('Created missing desktop shortcut to the existing launcher; target readback verified.')
        } catch {
            if ($createdShortcut -and (Test-Path -LiteralPath $shortcut -PathType Leaf)) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction Stop }
            $result.Status='Fail'
            $notes.Add($_.Exception.Message)
        }
    }
    try { $notes.Add((Verify-KioskLaunchTargets -Batch $batch -Shortcut $shortcut -LaunchPath $launch)) }
    catch { $result.Status='Fail'; $notes.Add($_.Exception.Message) }
    $result = Add-LauncherReportDetails $result $launch $shortcut $batch
    $result.Action = $notes -join ' '
    return $result
}

function Resolve-KioskPinchLiteral {
    param($Expression,$Ast,$Command,[switch]$Argument)
    if($Expression -is [Management.Automation.Language.VariableExpressionAst]){
        $name=$Expression.VariablePath.UserPath
        if($name -match ':' -or $name -in @('args','input','PSItem','_')){throw 'An automatic or scoped launcher variable requires manual review.'}
        $assignments=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ieq $name},$true))
        if($assignments.Count -ne 1 -or $assignments[0].Parent -ne $Ast.EndBlock -or $assignments[0].Operator.ToString() -ne 'Equals' -or $assignments[0].Extent.EndOffset -ge $Command.Extent.StartOffset){throw 'A unique preceding literal launcher assignment could not be verified.'}
        # No executable prefix may change the meaning of an inferred variable.
        foreach($statement in $Ast.EndBlock.Statements){
            if($statement.Extent.StartOffset -ge $Command.Extent.StartOffset){break}
            if($statement -isnot [Management.Automation.Language.AssignmentStatementAst] -or $statement.Operator.ToString() -ne 'Equals'){throw 'Launcher variable inference requires a static literal prefix.'}
            $right=$statement.Right
            if($right -is [Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1){$right=$right.PipelineElements[0]}
            if($right -isnot [Management.Automation.Language.CommandExpressionAst] -or $right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'Launcher variable inference requires a static literal prefix.'}
        }
        if($Argument){
            $references=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ieq $name},$true))
            if($references.Count -ne 2){throw 'Shared launcher arguments require manual review before editing.'}
        }
        $right=$assignments[0].Right
        if($right -is [Management.Automation.Language.PipelineAst]){$right=$right.PipelineElements[0]}
        $Expression=$right.Expression
    }
    if($Expression -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'Launcher value is dynamic or uses an unsupported format.'}
    if($Argument -and $Expression.StringConstantType.ToString() -notin @('SingleQuoted','DoubleQuoted')){throw 'Launcher arguments must be a quoted literal.'}
    $Expression
}

function Get-KioskPinchLaunchState {
    param([string]$Text)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Launcher syntax is invalid.'}
    $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match '^(?:Microsoft\.PowerShell\.Management\\)?Start-Process$'},$true))
    if($commands.Count -ne 1){throw 'A single static Edge launch command could not be verified.'}
    $command=$commands[0]
    if($command.Parent -isnot [Management.Automation.Language.PipelineAst] -or $command.Parent.PipelineElements.Count -ne 1 -or $command.Parent.Parent -ne $ast.EndBlock){throw 'The Edge launch command is conditional or indirect; manual review is required.'}
    $elements=$command.CommandElements
    $fileExpression=$null;$argumentExpression=$null
    for($index=1;$index -lt $elements.Count;$index++){
        $element=$elements[$index]
        if($element -is [Management.Automation.Language.CommandParameterAst]){
            if($element.ParameterName -in @('FilePath','ArgumentList','WindowStyle','WorkingDirectory')){
                $expression=$element.Argument
                if($null -eq $expression){
                    if($index+1 -ge $elements.Count){throw 'An Edge launch parameter has no value.'}
                    $index++;$expression=$elements[$index]
                }
                if($expression -is [Management.Automation.Language.CommandParameterAst]){throw 'An Edge launch parameter has no value.'}
                if($element.ParameterName -eq 'FilePath'){
                    if($null -ne $fileExpression){throw 'Duplicate Edge executable parameter.'}
                    $fileExpression=$expression
                }elseif($element.ParameterName -eq 'ArgumentList'){
                    if($null -ne $argumentExpression){throw 'Duplicate Edge arguments parameter.'}
                    $argumentExpression=$expression
                }
            }elseif($element.ParameterName -notin @('Wait','PassThru')){throw 'An unsupported Edge launch parameter needs manual review.'}
        }elseif($index -eq 1 -and $null -eq $fileExpression){$fileExpression=$element}
        else{throw 'An unbound or splatted Edge launch argument needs manual review.'}
    }
    $fileExpression=Resolve-KioskPinchLiteral $fileExpression $ast $command
    $argumentExpression=Resolve-KioskPinchLiteral $argumentExpression $ast $command -Argument
    if($fileExpression -isnot [Management.Automation.Language.StringConstantExpressionAst] -or [IO.Path]::GetFileName($fileExpression.Value) -notin @('msedge','msedge.exe')){throw 'The Edge executable is not a verified literal path.'}
    if($argumentExpression -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $argumentExpression.StringConstantType.ToString() -notin @('SingleQuoted','DoubleQuoted')){throw 'Edge arguments are dynamic or use an unsupported format.'}
    $arguments=ConvertFrom-KioskEdgeArguments $argumentExpression.Value
    if($arguments -ccontains '--'){throw 'An Edge argument terminator prevents safe pinch configuration.'}
    $kioskPositions=@(for($index=0;$index -lt $arguments.Count;$index++){if($arguments[$index] -ceq '--kiosk'){$index}})
    if($kioskPositions.Count -ne 1 -or $kioskPositions[0]+1 -ge $arguments.Count){throw 'The kiosk URL argument could not be verified.'}
    $url=$arguments[$kioskPositions[0]+1]
    if([string]::IsNullOrWhiteSpace($url) -or $url.StartsWith('--')){throw 'A kiosk URL argument is required.'}
    $pinchArguments=@($arguments | Where-Object {$_ -match '^--(?:disable|enable)-pinch(?:=|$)'})
    if($pinchArguments.Count -gt 1 -or ($pinchArguments.Count -eq 1 -and $pinchArguments[0] -cne '--disable-pinch')){throw 'A nonstandard or conflicting pinch argument needs manual review.'}
    [pscustomobject]@{Disabled=($pinchArguments.Count -eq 1);InsertOffset=($argumentExpression.Extent.EndOffset-1)}
}

function Read-KioskPinchStream {
    param([IO.Stream]$Stream)
    $copy=[IO.MemoryStream]::new()
    try{$Stream.Position=0;$Stream.CopyTo($copy);return ,$copy.ToArray()}finally{$copy.Dispose()}
}

function Write-KioskPinchStream {
    param([IO.FileStream]$Stream,[byte[]]$Bytes)
    $Stream.Position=0;$Stream.Write($Bytes,0,$Bytes.Length);$Stream.SetLength($Bytes.Length);$Stream.Flush($true)
}

function Invoke-KioskPinchZoomCheck {
    param([string]$UserName)
    $result=New-CheckResult 'Fail' 'Pinch-to-zoom configuration was not verified. Manual action required.' 'Not verified. Please check manually.'
    try{
        if([string]::IsNullOrWhiteSpace($UserName)){throw 'The selected kiosk account is unavailable.'}
        $profile=Get-KioskProfilePath $UserName
        if(-not $profile){throw 'The selected kiosk profile is unavailable.'}
        $launch=Join-Path $profile 'Scripts\LaunchKiosk.ps1'
        $batch=Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
        if(-not (Test-Path -LiteralPath $launch -PathType Leaf)){throw 'The kiosk launcher is missing.'}
        $original=[IO.File]::ReadAllBytes($launch)
        $encoding=[Text.UTF8Encoding]::new($false,$true);$preambleLength=0
        if($original.Length -ge 4 -and $original[0] -eq 255 -and $original[1] -eq 254 -and $original[2] -eq 0 -and $original[3] -eq 0){$encoding=[Text.UTF32Encoding]::new($false,$true,$true);$preambleLength=4}
        elseif($original.Length -ge 4 -and $original[0] -eq 0 -and $original[1] -eq 0 -and $original[2] -eq 254 -and $original[3] -eq 255){$encoding=[Text.UTF32Encoding]::new($true,$true,$true);$preambleLength=4}
        elseif($original.Length -ge 3 -and $original[0] -eq 239 -and $original[1] -eq 187 -and $original[2] -eq 191){$preambleLength=3}
        elseif($original.Length -ge 2 -and $original[0] -eq 255 -and $original[1] -eq 254){$encoding=[Text.UnicodeEncoding]::new($false,$true,$true);$preambleLength=2}
        elseif($original.Length -ge 2 -and $original[0] -eq 254 -and $original[1] -eq 255){$encoding=[Text.UnicodeEncoding]::new($true,$true,$true);$preambleLength=2}
        $text=$encoding.GetString($original,$preambleLength,$original.Length-$preambleLength)
        $state=Get-KioskPinchLaunchState $text
        if($state.Disabled){return New-CheckResult 'Pass' 'Touchscreen pinch-to-zoom disabling argument is configured. Verify touch behavior after restarting Edge.' 'Disabled'}
        $result.State='Not configured'
        $result.Action='The verified Edge launch command is missing --disable-pinch. Apply Fix can add this argument; touchscreen verification requires restarting Edge.'
        if(-not (Test-CanApply)){return $result}
        if($text -match '(?im)^# SIG # Begin signature block'){throw 'The launcher is signed and must be updated manually.'}
        foreach($path in @($launch,(Split-Path $launch -Parent))){if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked launcher path requires manual review.'}}
        if(-not (Test-KioskStartupBatch -Batch $batch -LaunchPath $launch)){throw 'The Startup BAT is missing or does not target this launcher.'}
        $updated=$text.Insert($state.InsertOffset,' --disable-pinch')
        if(-not (Get-KioskPinchLaunchState $updated).Disabled){throw 'The proposed pinch argument could not be verified.'}
        $body=$encoding.GetBytes($updated)
        $candidate=[byte[]]::new($preambleLength+$body.Length)
        if($preambleLength){[Buffer]::BlockCopy($original,0,$candidate,0,$preambleLength)}
        [Buffer]::BlockCopy($body,0,$candidate,$preambleLength,$body.Length)
        $stream=$null;$writeStarted=$false
        try{
            $stream=[IO.File]::Open($launch,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $lockedBytes=Read-KioskPinchStream $stream
            if([Convert]::ToBase64String($lockedBytes) -cne [Convert]::ToBase64String($original)){throw 'The launcher changed during inspection; existing content preserved.'}
            $writeStarted=$true
            Write-KioskPinchStream -Stream $stream -Bytes $candidate
            $readback=Read-KioskPinchStream $stream
            if([Convert]::ToBase64String($readback) -cne [Convert]::ToBase64String($candidate)){throw 'Launcher content readback did not match the single authorized change.'}
            $readbackText=$encoding.GetString($readback,$preambleLength,$readback.Length-$preambleLength)
            if(-not (Get-KioskPinchLaunchState $readbackText).Disabled){throw 'The pinch argument was not verified after writing.'}
        }catch{
            $failure=$_.Exception.Message
            if($writeStarted){
                try{
                    $stream.Position=0;$stream.Write($original,0,$original.Length);$stream.SetLength($original.Length);$stream.Flush($true)
                    $restored=Read-KioskPinchStream $stream
                    if([Convert]::ToBase64String($restored) -cne [Convert]::ToBase64String($original)){throw 'Restore readback mismatch.'}
                    $failure+=' Previous launcher bytes restored.'
                }catch{$failure+=' Launcher restoration could not be verified. Inspect the launcher manually.'}
            }
            throw $failure
        }finally{if($null -ne $stream){$stream.Dispose()}}
        return New-CheckResult 'Pass' 'Added only --disable-pinch to the verified Edge argument string; content readback verified. Restart Edge and verify touchscreen zoom. No backup or temporary files were created.' 'Disabled'
    }catch{
        $result.Status='Fail';$result.Action=$_.Exception.Message+' Manual action required. The launcher was not run.'
        return $result
    }
}

function Invoke-BrowserPolicyCheck {
    param([string]$UserName)
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $allow = "$edge\LocalNetworkAccessAllowedForUrls"
    $gestures = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI'
    $settings = @(
        @{Path=$allow; Name='1'; Value=$script:KioskClientSettings.Origin; Type='String'},
        @{Path=$edge; Name='TranslateEnabled'; Value=0; Type='DWord'},
        @{Path=$edge; Name='VisualSearchEnabled'; Value=0; Type='DWord'},
        @{Path=$gestures; Name='AllowEdgeSwipe'; Value=0; Type='DWord'}
    )
    $issues = [Collections.Generic.List[string]]::new()
    $changes = [Collections.Generic.List[string]]::new()
    $policyStates = [Collections.Generic.List[string]]::new()
    $labels = @{ '1'='Local Network Allowlist'; TranslateEnabled='Translation'; VisualSearchEnabled='Visual Search'; AllowEdgeSwipe='Edge Gestures' }
    foreach ($setting in $settings) {
        $keyExists = Test-Path -LiteralPath $setting.Path
        $key = if ($keyExists) { Get-Item -LiteralPath $setting.Path -ErrorAction Stop } else { $null }
        $valueExists = $null -ne $key -and $key.GetValueNames() -contains $setting.Name
        # Preserve existing values except the approved main allowlist client-origin repair.
        if (-not $valueExists -and (Test-CanApply)) {
            if (-not $keyExists) {
                $missingKeys = [Collections.Generic.Stack[string]]::new()
                $candidate = $setting.Path
                while (-not (Test-Path -LiteralPath $candidate)) {
                    $missingKeys.Push($candidate)
                    $candidate = Split-Path $candidate -Parent
                    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'Cannot locate an existing policy registry parent.' }
                }
                foreach ($missingKey in $missingKeys) { New-Item -Path $missingKey -ErrorAction Stop | Out-Null }
            }
            New-ItemProperty -LiteralPath $setting.Path -Name $setting.Name -Value $setting.Value -PropertyType $setting.Type -ErrorAction Stop | Out-Null
            $changes.Add('Added '+$labels[$setting.Name])
            $key = Get-Item -LiteralPath $setting.Path -ErrorAction Stop
            $valueExists = $key.GetValueNames() -contains $setting.Name
        }
        $value = if ($valueExists) { $key.GetValue($setting.Name) } else { $null }
        if($setting.Name -eq '1' -and $valueExists -and $key.GetValueKind('1').ToString() -eq 'String' -and (Test-CanApply) -and (Test-KioskKnownWrongOrigin ([string]$value))){
            try{if(Set-KioskMainAllowlistOrigin){$changes.Add('Updated Local Network Allowlist')}}catch{$issues.Add('Local Network Allowlist repair failed: '+$_.Exception.Message)}
            $key=Get-Item -LiteralPath $setting.Path -ErrorAction Stop
            $valueExists=$key.GetValueNames() -contains '1'
            $value=if($valueExists){$key.GetValue('1')}else{$null}
        }
        $display = if (-not $valueExists) { 'Not configured' } elseif ($setting.Type -eq 'String') { [string]$value } elseif ($value -eq 0) { 'Disabled' } elseif ($value -eq 1) { 'Enabled' } else { 'Unrecognized value' }
        $policyStates.Add($labels[$setting.Name]+': '+[Net.WebUtility]::HtmlEncode($display))
        if (-not $valueExists -or $value -cne $setting.Value -or $key.GetValueKind($setting.Name).ToString() -ne $setting.Type) { $issues.Add($labels[$setting.Name]) }
    }
    if (Test-Path -LiteralPath $allow) {
        $allowKey=Get-Item -LiteralPath $allow -ErrorAction Stop
        # Extra list values are customer permissions, not evidence of a fault.
        # Report their actual content without deleting or rewriting any value.
        foreach($entryName in @($allowKey.GetValueNames() | Where-Object {$_ -ne '1'} | Sort-Object)){
            $entryValue=[string]$allowKey.GetValue($entryName)
            $policyStates.Add('Additional allowlist entry '+[Net.WebUtility]::HtmlEncode($entryName)+': '+[Net.WebUtility]::HtmlEncode($entryValue)+' (preserved)')
        }
    }
    $pinch=Invoke-KioskPinchZoomCheck -UserName $UserName
    $policyStates.Add('Pinch-to-Zoom: '+[Net.WebUtility]::HtmlEncode($pinch.State))
    if($pinch.Status -ne 'Pass'){$issues.Add('Pinch-to-Zoom')}
    $action = if ($changes.Count) { ($changes -join '; ')+'. Other existing policy values preserved.' } else { 'Existing policy values preserved; no changes made.' }
    if ($issues.Count) { $action += ' Manual review required: '+($issues -join ', ')+'.' }
    else { $action += ' Required policy values verified.' }
    $action += ' '+$pinch.Action
    $result = New-CheckResult $(if ($issues.Count) { 'Fail' } else { 'Pass' }) $action 'Browser policies inspected'
    $result | Add-Member -NotePropertyName StateHtml -NotePropertyValue ($policyStates -join '<br>')
    return $result
}

function Get-KioskLaunchTaskInventory {
    # A failed enumeration is not evidence that a task is missing.
    @(Get-ScheduledTask -ErrorAction Stop | Where-Object {[string]$_.TaskName -ieq 'Launch Kiosk'})
}

function Get-KioskLaunchTaskContext {
    param([string]$UserName,$Account)
    $issues=[Collections.Generic.List[string]]::new()
    $context=[pscustomobject]@{UserName=$UserName;UserId='Not verified';Sid='';ScriptPath='Not verified';ProgramPath=(Join-Path $PSHOME 'powershell.exe');WorkingDirectory='';LauncherFile='Not verified';StartupBat='Not verified';Ready=$false;Reason=''}
    try{
        if($null -eq $Account -or [string]$Account.Name -ine $UserName){throw 'The selected kiosk account was not verified.'}
        $fresh=Get-LocalAccount $UserName
        if($null -eq $fresh -or $null -eq $fresh.SID -or -not [string]$fresh.SID.Value){throw 'The selected local account SID is unavailable.'}
        if($null -eq $Account.SID -or [string]$Account.SID.Value -cne [string]$fresh.SID.Value){throw 'The selected local account identity changed; no task was created.'}
        $context.Sid=[string]$fresh.SID.Value
        if([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)){throw 'The local computer name is unavailable.'}
        $context.UserId=$env:COMPUTERNAME+'\'+$UserName
        if($fresh.Enabled -isnot [bool] -or -not $fresh.Enabled){$issues.Add('The selected kiosk account is disabled or its enabled state is unverified.')}
        $profile=Get-KioskProfilePath $UserName
        if([string]::IsNullOrWhiteSpace($profile)){throw 'The selected kiosk user profile is unavailable.'}
        $profile=[IO.Path]::GetFullPath($profile).TrimEnd('\')
        if($profile -notmatch '^[A-Za-z]:\\'){throw 'The kiosk profile must be a verified local Windows path.'}
        $context.ScriptPath=[IO.Path]::GetFullPath((Join-Path $profile 'Scripts\LaunchKiosk.ps1'))
        $context.WorkingDirectory=[IO.Path]::GetDirectoryName($context.ScriptPath)
        $startup=Join-Path $profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\LaunchKiosk.bat'
        $context.StartupBat=if(Test-Path -LiteralPath $startup -PathType Leaf -ErrorAction Stop){'Also present (unchanged)'}else{'Not present'}
        $context.LauncherFile=if(Test-Path -LiteralPath $context.ScriptPath -PathType Leaf -ErrorAction Stop){'Available'}else{'Missing'}
        if($context.LauncherFile -ne 'Available'){$issues.Add('The existing LaunchKiosk.ps1 file is missing.')}
        if(-not (Test-Path -LiteralPath $context.ProgramPath -PathType Leaf -ErrorAction Stop)){$issues.Add('Windows PowerShell executable is unavailable.')}
        foreach($target in @($context.ScriptPath,$context.ProgramPath)){
            if(-not (Test-Path -LiteralPath $target -PathType Leaf -ErrorAction Stop)){continue}
            $current=$target
            while($current){
                $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'A linked launcher or executable path requires manual review.'}
                $parent=[IO.Path]::GetDirectoryName($current)
                if($parent -eq $current){break};$current=$parent
            }
        }
    }catch{$issues.Add($_.Exception.Message)}
    $context.Ready=$issues.Count -eq 0
    $context.Reason=$issues -join ' '
    $context
}

function Test-KioskLaunchTaskIdentity {
    param([string]$Identity,$Context)
    if(-not $Context.Sid){return $false}
    $Identity -ieq $Context.Sid -or $Identity -ieq $Context.UserId -or $Identity -ieq ('.\'+$Context.UserName)
}

function Read-KioskLaunchTaskArguments {
    param([string]$Arguments)
    # Inspect native argument tokens only. Never evaluate a task command line.
    $result=[pscustomobject]@{Known=$false;ScriptPath='Not verified';ProfileLoading='Not verified';ExecutionPolicy='Not verified';WindowStyle='Not verified'}
    $tokens=[Collections.Generic.List[string]]::new();$end=0
    foreach($match in [regex]::Matches($Arguments,'"(?<Quoted>[^"]*)"|(?<Bare>[^\s"]+)')){
        if(($tokens.Count -gt 0 -and $match.Index -eq $end) -or $Arguments.Substring($end,$match.Index-$end).Trim()){return $result}
        $tokens.Add($(if($match.Groups['Quoted'].Success){$match.Groups['Quoted'].Value}else{$match.Groups['Bare'].Value}))
        $end=$match.Index+$match.Length
    }
    if($Arguments.Substring($end).Trim()){return $result}
    $seen=@{}
    for($i=0;$i -lt $tokens.Count;$i++){
        $key=$tokens[$i].ToLowerInvariant()
        if($seen.ContainsKey($key)){return $result};$seen[$key]=$true
        switch($key){
            '-noprofile' {$result.ProfileLoading='Disabled'}
            '-executionpolicy' {if(++$i -ge $tokens.Count){return $result};$result.ExecutionPolicy=$tokens[$i]}
            '-windowstyle' {if(++$i -ge $tokens.Count){return $result};$result.WindowStyle=$tokens[$i]}
            '-file' {if(++$i -ge $tokens.Count){return $result};$result.ScriptPath=$tokens[$i]}
            default {return $result}
        }
    }
    $result.Known=$seen.Count -eq 4 -and $seen.ContainsKey('-noprofile') -and $seen.ContainsKey('-executionpolicy') -and $seen.ContainsKey('-windowstyle') -and $seen.ContainsKey('-file')
    $result
}

function Get-KioskLaunchTaskFields {
    param($Context,[string]$Availability='Missing')
    $fields=[ordered]@{
        'Task Name'='Launch Kiosk';'Task Path'='\';'Task'=$Availability;'Task State'='Not configured';'Task Enabled'='Not configured'
        'Run As'='Not configured';'Logon Type'='Not configured';'Run Level'='Not configured';'Trigger'='Not configured';'Logon User'='Not configured'
        'Startup Delay'='Not configured';'Program'='Not configured';'Script Path'='Not configured';'Profile Loading'='Not configured'
        'Execution Policy'='Not configured';'Window Style'='Not configured';'Working Directory'='Not configured';'Execution Time Limit'='Not configured'
        'Start On Battery'='Not configured';'Stop On Battery'='Not configured';'Start When Available'='Not configured'
        'Launcher File'=$Context.LauncherFile;'Startup BAT'=$Context.StartupBat
    }
    if($Availability -eq 'Not verified'){foreach($key in @($fields.Keys|Where-Object {$_ -notin @('Task Name','Task','Launcher File','Startup BAT')})){$fields[$key]='Not verified'}}
    $fields
}

function Get-KioskLaunchTaskRequirements {
    param($Context)
    [ordered]@{
        'Task Name'='Launch Kiosk';'Task Path'='\';'Task'='Available';'Task State'='';'Task Enabled'='Yes'
        'Run As'=$Context.UserId;'Logon Type'='Interactive';'Run Level'='Limited';'Trigger'='At logon';'Logon User'=$Context.UserId
        'Startup Delay'='5 seconds';'Program'='Windows PowerShell';'Script Path'=$Context.ScriptPath;'Profile Loading'='Disabled'
        'Execution Policy'='Bypass';'Window Style'='Hidden';'Working Directory'='';'Execution Time Limit'='Unlimited'
        'Start On Battery'='Yes';'Stop On Battery'='No';'Start When Available'='Yes';'Launcher File'='Available';'Startup BAT'=''
    }
}

function Read-KioskLaunchTaskSnapshot {
    param([AllowEmptyCollection()][object[]]$Tasks,$Context)
    $fields=Get-KioskLaunchTaskFields $Context
    if($Tasks.Count -eq 0){return [pscustomobject]@{Fields=$fields;Verified=$true;Passed=$false;Reason='Launch Kiosk task is missing.'}}
    if($Tasks.Count -ne 1){
        $fields['Task']='Multiple matches';$fields['Task Path']=($Tasks|ForEach-Object {[string]$_.TaskPath}) -join ', '
        foreach($key in @($fields.Keys|Where-Object {$_ -notin @('Task Name','Task Path','Task','Launcher File','Startup BAT')})){$fields[$key]='Not verified'}
        return [pscustomobject]@{Fields=$fields;Verified=$false;Passed=$false;Reason='Multiple Launch Kiosk tasks require manual review; existing tasks were preserved.'}
    }
    $task=$Tasks[0];$fields['Task']='Available';$fields['Task Path']=[string]$task.TaskPath;$fields['Task State']=[string]$task.State
    $reader=$null;$inputText=$null
    try{
        if(-not [string]$task.TaskPath){throw 'Task folder could not be verified.'}
        $xml=Export-ScheduledTask -TaskName 'Launch Kiosk' -TaskPath ([string]$task.TaskPath) -ErrorAction Stop
        $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
        $inputText=[IO.StringReader]::new([string]$xml);$reader=[Xml.XmlReader]::Create($inputText,$settings)
        $document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)
        if($document.DocumentElement.LocalName -ne 'Task' -or $document.DocumentElement.NamespaceURI -ne 'http://schemas.microsoft.com/windows/2004/02/mit/task'){throw 'Unrecognized scheduled task definition.'}
        $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('t',$document.DocumentElement.NamespaceURI)
        $text={param([string]$Path) $node=$document.SelectSingleNode($Path,$ns);if($node){$node.InnerText}else{''}}
        $yesNo={param([string]$Value) if($Value -ieq 'true'){'Yes'}elseif($Value -ieq 'false'){'No'}else{'Not verified'}}
        # Task Scheduler schema defaults omitted Enabled elements to true.
        $enabledValue=& $text '/t:Task/t:Settings/t:Enabled'
        $fields['Task Enabled']=if($document.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns)){& $yesNo $enabledValue}else{'Yes'}
        if($fields['Task State'] -eq 'Disabled'){$fields['Task Enabled']='No'}
        $principals=@($document.SelectNodes('/t:Task/t:Principals/t:Principal',$ns))
        if($principals.Count -ne 1){throw 'The task principal is missing or ambiguous.'}
        $principal=& $text '/t:Task/t:Principals/t:Principal/t:UserId'
        $fields['Run As']=if(Test-KioskLaunchTaskIdentity $principal $Context){$Context.UserId}else{$principal}
        $logon=& $text '/t:Task/t:Principals/t:Principal/t:LogonType'
        $fields['Logon Type']=if($logon -eq 'InteractiveToken'){'Interactive'}elseif($logon){$logon}else{'Not verified'}
        $level=& $text '/t:Task/t:Principals/t:Principal/t:RunLevel'
        if(-not $document.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:RunLevel',$ns)){$level='LeastPrivilege'}
        $fields['Run Level']=switch($level){'LeastPrivilege'{'Limited'};'HighestAvailable'{'Highest'};default{'Not verified'}}
        $triggers=@($document.SelectNodes('/t:Task/t:Triggers/*',$ns))
        if($triggers.Count -eq 1 -and $triggers[0].LocalName -eq 'LogonTrigger'){
            $enabled=& $text '/t:Task/t:Triggers/t:LogonTrigger/t:Enabled'
            if(-not $document.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:Enabled',$ns)){$enabled='true'}
            $fields['Trigger']=if($enabled -ieq 'true'){'At logon'}elseif($enabled -ieq 'false'){'Disabled logon trigger'}else{'Not verified'}
            $triggerUser=& $text '/t:Task/t:Triggers/t:LogonTrigger/t:UserId'
            $fields['Logon User']=if(Test-KioskLaunchTaskIdentity $triggerUser $Context){$Context.UserId}elseif($triggerUser){$triggerUser}else{'Any user'}
            $delay=& $text '/t:Task/t:Triggers/t:LogonTrigger/t:Delay'
            try{$duration=[Xml.XmlConvert]::ToTimeSpan($delay);$fields['Startup Delay']=$duration.TotalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)+' seconds'}catch{$fields['Startup Delay']='Not verified'}
        }else{$fields['Trigger']=if($triggers.Count -gt 1){'Multiple triggers'}else{'Not a logon trigger'};$fields['Logon User']='Not verified';$fields['Startup Delay']='Not verified'}
        $actions=@($document.SelectNodes('/t:Task/t:Actions/*',$ns))
        if($actions.Count -eq 1 -and $actions[0].LocalName -eq 'Exec'){
            $program=& $text '/t:Task/t:Actions/t:Exec/t:Command'
            $fields['Program']=if($program -ieq $Context.ProgramPath -or $program -ieq 'powershell.exe'){'Windows PowerShell'}else{$program}
            $arguments=Read-KioskLaunchTaskArguments (& $text '/t:Task/t:Actions/t:Exec/t:Arguments')
            if($arguments.Known){
                $fields['Script Path']=$arguments.ScriptPath;$fields['Profile Loading']=$arguments.ProfileLoading
                $fields['Execution Policy']=$arguments.ExecutionPolicy;$fields['Window Style']=$arguments.WindowStyle
            }else{foreach($key in @('Script Path','Profile Loading','Execution Policy','Window Style')){$fields[$key]='Not verified'}}
            $directory=& $text '/t:Task/t:Actions/t:Exec/t:WorkingDirectory'
            $fields['Working Directory']=if($directory){$directory}else{'(default)'}
        }else{foreach($key in @('Program','Script Path','Profile Loading','Execution Policy','Window Style','Working Directory')){$fields[$key]='Not verified'}}
        $limit=& $text '/t:Task/t:Settings/t:ExecutionTimeLimit'
        try{$duration=[Xml.XmlConvert]::ToTimeSpan($limit);$fields['Execution Time Limit']=if($duration -eq [TimeSpan]::Zero){'Unlimited'}else{$limit}}catch{$fields['Execution Time Limit']='Not verified'}
        $disallow=& $text '/t:Task/t:Settings/t:DisallowStartIfOnBatteries'
        $fields['Start On Battery']=if($disallow -ieq 'false'){'Yes'}elseif($disallow -ieq 'true'){'No'}else{'Not verified'}
        $fields['Stop On Battery']=& $yesNo (& $text '/t:Task/t:Settings/t:StopIfGoingOnBatteries')
        $fields['Start When Available']=& $yesNo (& $text '/t:Task/t:Settings/t:StartWhenAvailable')
        $required=Get-KioskLaunchTaskRequirements $Context
        $passed=$Context.Ready
        foreach($key in $required.Keys){if($required[$key] -and [string]$fields[$key] -ine [string]$required[$key]){$passed=$false}}
        [pscustomobject]@{Fields=$fields;Verified=$true;Passed=$passed;Reason=$(if($passed){'Existing task definition verified; no task was changed or executed.'}else{'Existing task configuration requires manual review; task preserved. '+$Context.Reason})}
    }catch{
        foreach($key in @($fields.Keys|Where-Object {$_ -notin @('Task Name','Task Path','Task','Task State','Launcher File','Startup BAT')})){$fields[$key]='Not verified'}
        [pscustomobject]@{Fields=$fields;Verified=$false;Passed=$false;Reason='Task definition could not be verified: '+$_.Exception.Message}
    }finally{if($reader){$reader.Dispose()};if($inputText){$inputText.Dispose()}}
}

function Open-KioskLaunchTaskScheduler {
    $service=New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $service
}

function New-KioskLaunchTaskDefinition {
    param($Service,$Context)
    $definition=$service.NewTask(0)
    $definition.RegistrationInfo.Description='Start the existing kiosk launcher five seconds after the selected local user logs on.'
    $definition.Principal.UserId=$Context.Sid;$definition.Principal.LogonType=3;$definition.Principal.RunLevel=0
    $trigger=$definition.Triggers.Create(9);$trigger.UserId=$Context.Sid;$trigger.Delay='PT5S';$trigger.Enabled=$true
    $action=$definition.Actions.Create(0);$action.Path=$Context.ProgramPath
    $action.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Context.ScriptPath+'"'
    $action.WorkingDirectory=$Context.WorkingDirectory
    $definition.Settings.Enabled=$true;$definition.Settings.DisallowStartIfOnBatteries=$false
    $definition.Settings.StopIfGoingOnBatteries=$false;$definition.Settings.StartWhenAvailable=$true
    $definition.Settings.ExecutionTimeLimit='PT0S';$definition.Settings.MultipleInstances=2
    $definition
}

function Register-MissingKioskLaunchTask {
    param($Context)
    if(-not (Test-CanApply) -or -not $Context.Ready){throw 'Missing-task creation requires approved Apply and verified kiosk prerequisites.'}
    $service=Open-KioskLaunchTaskScheduler
    $definition=New-KioskLaunchTaskDefinition $service $Context
    $root=$service.GetFolder('\')
    # TASK_CREATE_OR_UPDATE (6) creates a new task or updates an existing invalid task definition.
    [void]$root.RegisterTaskDefinition('Launch Kiosk',$definition,6,$Context.Sid,$null,3,$null)
}

function Assert-KioskLaunchTaskBaseline {
    param([object[]]$Tasks,[AllowEmptyString()][string]$Xml)
    if(-not $Xml){
        if($Tasks.Count){throw 'A Launch Kiosk task appeared after confirmation; no task changed.'}
    }elseif($Tasks.Count -ne 1 -or [string]$Tasks[0].TaskPath -cne '\' -or [string](Export-ScheduledTask -TaskName 'Launch Kiosk' -TaskPath '\' -ErrorAction Stop) -cne $Xml){
        throw 'Launch Kiosk task changed after confirmation; no task changed.'
    }
}

function Get-KioskLaunchTaskCheck {
    param([string]$UserName,$Account,[AllowEmptyString()][string]$ExpectedTaskXml,[switch]$RequireUnchangedTask)
    $context=Get-KioskLaunchTaskContext $UserName $Account
    $status='Fail';$note='Task not verified; no task was changed.';$fields=Get-KioskLaunchTaskFields $context 'Not verified'
    $created=$false;$failure=$null
    try{
        $tasks=@(Get-KioskLaunchTaskInventory)
        if($RequireUnchangedTask){Assert-KioskLaunchTaskBaseline -Tasks $tasks -Xml $ExpectedTaskXml}
        $snapshot=Read-KioskLaunchTaskSnapshot -Tasks $tasks -Context $context
        $isMissing = ($tasks.Count -eq 0)
        $canRepair = ($isMissing -or ($tasks.Count -eq 1 -and -not $snapshot.Passed))
        if($canRepair -and (Test-CanApply)){
            if(-not $context.Ready){$note=if($isMissing){'Missing task was not created: '+$context.Reason}else{'Existing invalid task was not updated: '+$context.Reason}}
            else{
                $tasks=@(Get-KioskLaunchTaskInventory)
                if($RequireUnchangedTask){Assert-KioskLaunchTaskBaseline -Tasks $tasks -Xml $ExpectedTaskXml}
                $snapshot=Read-KioskLaunchTaskSnapshot -Tasks $tasks -Context $context
                if($tasks.Count -eq 0 -or ($tasks.Count -eq 1 -and -not $snapshot.Passed)){
                    try{Register-MissingKioskLaunchTask $context;$created=$true}catch{$failure=$_.Exception.Message}
                    $tasks=@(Get-KioskLaunchTaskInventory)
                    $snapshot=Read-KioskLaunchTaskSnapshot -Tasks $tasks -Context $context
                }
                if($failure){$note=if($isMissing){'Task creation failed: '+$failure+' Existing tasks were preserved. '+$snapshot.Reason}else{'Task repair failed: '+$failure+' Existing tasks were preserved. '+$snapshot.Reason}}
                elseif($created -and $snapshot.Passed){$status='Remediated';$note=if($isMissing){'Created missing Launch Kiosk task; readback verified. The task was not executed.'}else{'Repaired Launch Kiosk task; readback verified. The task was not executed.'}}
                elseif($created -and $snapshot.Verified){$note=if($isMissing){'Created missing Launch Kiosk task; readback shows configuration mismatches. Manual action required. '+$snapshot.Reason}else{'Repaired Launch Kiosk task; readback shows configuration mismatches. Manual action required. '+$snapshot.Reason}}
                elseif($created){$note='Task creation returned, but configuration readback was not verified. Manual action required. '+$snapshot.Reason}
                else{$note=$snapshot.Reason;if($snapshot.Passed){$status='Pass'}}
            }
        }else{$note=$snapshot.Reason;if($snapshot.Passed){$status='Pass'}}
        $fields=$snapshot.Fields
    }catch{$note='Task Scheduler verification failed: '+$_.Exception.Message+' No existing task was replaced.';if($created){$note+=' Creation returned, but readback was not verified; manual review required.'}}
    if($context.StartupBat -eq 'Also present (unchanged)'){$note+=' Startup BAT also exists; both logon launch paths remain configured.'}
    $history=if($fields['Task'] -eq 'Available' -and $tasks.Count -eq 1){Get-KioskLaunchTaskHistory $tasks}elseif($fields['Task'] -eq 'Missing'){Get-KioskLaunchTaskHistory @()}else{[ordered]@{'Last Run'='Not verified'}}
    foreach($label in $history.Keys){$fields[$label]=$history[$label]}
    $result=New-CheckResult $status $note 'Kiosk launch task inspected'
    $result|Add-Member NoteProperty StateHtml (ConvertTo-ReportDefinitionHtml $fields)
    $result|Add-Member NoteProperty ExpectedHtml (ConvertTo-ReportDefinitionHtml (Get-KioskLaunchTaskRequirements $context))
    $result
}

function Invoke-KioskLaunchTaskCheck {
    param([string]$UserName,$Account)
    $result=Get-KioskLaunchTaskCheck $UserName $Account
    Add-AuditEntry -SectionNumber 2 -SectionTitle 'Kiosk Application & Policies' -ItemTitle 'Kiosk Launch Task' -ItemSub 'Type: Missing-only logon task repair' -Shortcut (New-ReportCommand @('taskschd.msc','schtasks.exe /Query /TN "\Launch Kiosk" /XML')) -FoundStateHtml $result.StateHtml -Status $result.Status -ActionTaken ([Net.WebUtility]::HtmlEncode($result.Action))
    $auditRows[$auditRows.Count-1]|Add-Member NoteProperty ExpectedHtml $result.ExpectedHtml
}
