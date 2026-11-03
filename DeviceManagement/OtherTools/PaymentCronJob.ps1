[CmdletBinding()]
param([switch]$MenuRun)
$ErrorActionPreference='Stop'

function Skip-PaymentCronJsonSpace {
    param($Reader)
    while($Reader.Position -lt $Reader.Text.Length){
        $c=$Reader.Text[$Reader.Position]
        if($c -in @(' ',"`t","`r","`n")){$Reader.Position++;continue}
        if($c -eq '/' -and $Reader.Position+1 -lt $Reader.Text.Length){
            $next=$Reader.Text[$Reader.Position+1]
            if($next -eq '/'){
                $Reader.Position+=2
                while($Reader.Position -lt $Reader.Text.Length -and $Reader.Text[$Reader.Position] -notin @("`r","`n")){$Reader.Position++}
                continue
            }
            if($next -eq '*'){
                $end=$Reader.Text.IndexOf('*/',$Reader.Position+2,[StringComparison]::Ordinal)
                if($end -lt 0){throw 'Unterminated JSON comment; no changes made.'}
                $Reader.Position=$end+2;continue
            }
        }
        break
    }
}

function Read-PaymentCronJsonString {
    param($Reader)
    $start=$Reader.Position;$Reader.Position++
    while($Reader.Position -lt $Reader.Text.Length){
        $c=$Reader.Text[$Reader.Position];$Reader.Position++
        if($c -eq '"'){
            $raw=$Reader.Text.Substring($start,$Reader.Position-$start)
            try{return (ConvertFrom-Json -InputObject ('{"value":'+$raw+'}') -ErrorAction Stop).value}
            catch{throw ('Invalid JSON string at offset '+$start+'; no changes made.')}
        }
        if([int]$c -lt 32){throw ('Invalid JSON control character at offset '+($Reader.Position-1))}
        if($c -eq '\'){
            if($Reader.Position -ge $Reader.Text.Length){break}
            $escape=$Reader.Text[$Reader.Position];$Reader.Position++
            if($escape -eq 'u'){
                if($Reader.Position+4 -gt $Reader.Text.Length -or $Reader.Text.Substring($Reader.Position,4) -notmatch '^[0-9a-fA-F]{4}$'){throw 'Invalid JSON Unicode escape; no changes made.'}
                $Reader.Position+=4
            }elseif($escape -notin @('"','\','/','b','f','n','r','t')){throw 'Invalid JSON escape; no changes made.'}
        }
    }
    throw 'Unterminated JSON string; no changes made.'
}

function Read-PaymentCronJsonNode {
    param($Reader,[int]$Depth=0)
    if($Depth -gt 64 -or ++$Reader.Nodes -gt 100000){throw 'JSON exceeds inspection limits; no changes made.'}
    Skip-PaymentCronJsonSpace $Reader
    $start=$Reader.Position
    if($start -ge $Reader.Text.Length){throw 'Incomplete JSON; no changes made.'}
    $c=$Reader.Text[$start]
    $node=[pscustomobject]@{Kind='';Start=$start;Length=0;Value=$null;Members=$null;Items=$null}
    if($c -eq '{'){
        $node.Kind='Object';$node.Members=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $Reader.Position++;Skip-PaymentCronJsonSpace $Reader
        if($Reader.Position -lt $Reader.Text.Length -and $Reader.Text[$Reader.Position] -eq '}'){$Reader.Position++}
        else{
            while($true){
                Skip-PaymentCronJsonSpace $Reader
                if($Reader.Position -ge $Reader.Text.Length -or $Reader.Text[$Reader.Position] -ne '"'){throw 'Invalid JSON property; no changes made.'}
                $key=Read-PaymentCronJsonString $Reader
                if($node.Members.ContainsKey($key)){throw 'Duplicate JSON property; manual review required.'}
                Skip-PaymentCronJsonSpace $Reader
                if($Reader.Position -ge $Reader.Text.Length -or $Reader.Text[$Reader.Position] -ne ':'){throw 'Missing JSON colon; no changes made.'}
                $Reader.Position++;$value=Read-PaymentCronJsonNode $Reader ($Depth+1);$node.Members.Add($key,$value)
                Skip-PaymentCronJsonSpace $Reader
                if($Reader.Position -ge $Reader.Text.Length){throw 'Incomplete JSON object; no changes made.'}
                $end=$Reader.Text[$Reader.Position];$Reader.Position++
                if($end -eq '}'){break}
                if($end -ne ','){throw 'Invalid JSON object separator; no changes made.'}
                Skip-PaymentCronJsonSpace $Reader
                if($Reader.Position -lt $Reader.Text.Length -and $Reader.Text[$Reader.Position] -eq '}'){$Reader.Position++;break}
            }
        }
    }elseif($c -eq '['){
        $node.Kind='Array';$node.Items=[Collections.Generic.List[object]]::new()
        $Reader.Position++;Skip-PaymentCronJsonSpace $Reader
        if($Reader.Position -lt $Reader.Text.Length -and $Reader.Text[$Reader.Position] -eq ']'){$Reader.Position++}
        else{
            while($true){
                $node.Items.Add((Read-PaymentCronJsonNode $Reader ($Depth+1)))
                Skip-PaymentCronJsonSpace $Reader
                if($Reader.Position -ge $Reader.Text.Length){throw 'Incomplete JSON array; no changes made.'}
                $end=$Reader.Text[$Reader.Position];$Reader.Position++
                if($end -eq ']'){break}
                if($end -ne ','){throw 'Invalid JSON array separator; no changes made.'}
                Skip-PaymentCronJsonSpace $Reader
                if($Reader.Position -lt $Reader.Text.Length -and $Reader.Text[$Reader.Position] -eq ']'){$Reader.Position++;break}
            }
        }
    }elseif($c -eq '"'){$node.Kind='String';$node.Value=Read-PaymentCronJsonString $Reader}
    else{
        $remaining=$Reader.Text.Substring($start)
        if($remaining.StartsWith('true',[StringComparison]::Ordinal)){$node.Kind='Boolean';$node.Value=$true;$Reader.Position+=4}
        elseif($remaining.StartsWith('false',[StringComparison]::Ordinal)){$node.Kind='Boolean';$node.Value=$false;$Reader.Position+=5}
        elseif($remaining.StartsWith('null',[StringComparison]::Ordinal)){$node.Kind='Null';$Reader.Position+=4}
        else{
            $number=[regex]::Match($remaining,'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
            if(-not $number.Success){throw ('Invalid JSON value at offset '+$start+'; no changes made.')}
            $node.Kind='Number';$node.Value=$number.Value;$Reader.Position+=$number.Length
        }
    }
    $node.Length=$Reader.Position-$start
    $node
}

function Get-PaymentCronMember {
    param($Node,[string]$Name)
    if($null -ne $Node -and $Node.Kind -eq 'Object' -and $Node.Members.ContainsKey($Name)){$Node.Members[$Name]}
}

function Get-PaymentCronModel {
    param([string]$Text)
    $reader=[pscustomobject]@{Text=$Text;Position=0;Nodes=0}
    $root=Read-PaymentCronJsonNode $reader
    Skip-PaymentCronJsonSpace $reader
    if($reader.Position -ne $Text.Length -or $root.Kind -ne 'Object'){throw 'Configuration must contain one complete JSON object; no changes made.'}
    $configuration=Get-PaymentCronMember $root 'ScheduleConfiguration'
    $schedules=Get-PaymentCronMember $configuration 'Schedules'
    if($null -eq $schedules -or $schedules.Kind -ne 'Array'){throw 'ScheduleConfiguration.Schedules array is unavailable; no changes made.'}
    $records=[Collections.Generic.List[object]]::new();$six=[Collections.Generic.List[object]]::new();$index=0
    foreach($schedule in $schedules.Items){
        if($schedule.Kind -ne 'Object'){throw 'A schedule record is not an object; manual review required.'}
        $provider=Get-PaymentCronMember $schedule 'Provider'
        if($null -eq $provider -or $provider.Kind -ne 'String'){throw 'A schedule Provider is missing or invalid; manual review required.'}
        if($provider.Value -in @('SIX','NETS','NEXIDE')){
            $flag=Get-PaymentCronMember $schedule 'IsEnabled'
            $record=[pscustomobject]@{Index=$index;Provider=$provider.Value;Name='Not configured';UID='Not configured';CronExpression='Not configured';IsEnabled=$null;Token=$flag}
            foreach($name in @('Name','UID','CronExpression')){$value=Get-PaymentCronMember $schedule $name;if($null -ne $value -and $value.Kind -eq 'String'){$record.$name=$value.Value}}
            if($null -ne $flag -and $flag.Kind -eq 'Boolean'){$record.IsEnabled=[bool]$flag.Value}
            $records.Add($record)
            if($provider.Value -ieq 'SIX'){$six.Add($record)}
        }
        $index++
    }
    [pscustomobject]@{Records=$records.ToArray();Six=$six.ToArray()}
}

function Assert-PaymentCronLocalPath {
    param([string]$Path)
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')){throw 'A local Windows file path is required; no changes made.'}
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked paths require manual review; no changes made.'}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function Get-PaymentCronRunningServices {
    @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop|Where-Object {
        $_.State -eq 'Running' -and ($_.Name -match '^AspPayment|^SubwayLocal$' -or $_.DisplayName -match 'Payment\s*Middleware|AspPayment' -or $_.PathName -match 'Kiosk Payment Middleware\.exe')
    }|Sort-Object Name)
}

function Get-PaymentCronServiceContext {
    param($Service)
    if($Service.State -ne 'Running'){throw 'The selected Payment Service is not running; no changes made.'}
    $command=[Environment]::ExpandEnvironmentVariables([string]$Service.PathName).Trim()
    $match=[regex]::Match($command,'^(?:"(?<Path>[^"]+\.exe)"|(?<Path>.+?\.exe))\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $match.Success){throw 'Service executable or command-line overrides are ambiguous; manual review required.'}
    if($match.Groups['Path'].Value -notmatch '^[A-Za-z]:\\'){throw 'Service executable path must be absolute; no changes made.'}
    $executable=[IO.Path]::GetFullPath($match.Groups['Path'].Value)
    if([IO.Path]::GetFileName($executable) -in @('dotnet.exe','cmd.exe','powershell.exe','pwsh.exe','svchost.exe','nssm.exe','winsw.exe')){throw 'Hosted service configuration requires manual path verification.'}
    Assert-PaymentCronLocalPath $executable
    if(-not (Test-Path -LiteralPath $executable -PathType Leaf -ErrorAction Stop)){throw 'Payment Service executable is unavailable.'}
    $processIdValue=[uint32]$Service.ProcessId
    if($processIdValue -eq 0){throw 'Running service process identity is unavailable.'}
    $processes=@(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = '+$processIdValue) -ErrorAction Stop)
    if($processes.Count -ne 1 -or [string]$processes[0].ExecutablePath -ine $executable){throw 'Running process does not match the configured service executable; no changes made.'}
    $actualCommand=[regex]::Match([string]$processes[0].CommandLine,'^(?:"(?<Path>[^"]+\.exe)"|(?<Path>.+?\.exe))\s*$',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $actualCommand.Success -or $actualCommand.Groups['Path'].Value -ine $executable){throw 'Actual running process arguments or configuration overrides are not verified; no changes made.'}
    $path=Join-Path ([IO.Path]::GetDirectoryName($executable)) 'appsettings.json'
    Assert-PaymentCronLocalPath $path
    if(-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop)){throw 'appsettings.json is unavailable.'}
    [pscustomobject]@{Name=[string]$Service.Name;ProcessId=$processIdValue;Path=$path;Executable=$executable;Command=$command}
}

function Read-PaymentCronBytes {
    param([IO.Stream]$Stream)
    if($Stream.Length -eq 0 -or $Stream.Length -gt 8MB){throw 'Configuration is empty or exceeds 8 MB; no changes made.'}
    $Stream.Position=0;$bytes=New-Object byte[] ([int]$Stream.Length);$offset=0
    while($offset -lt $bytes.Length){$read=$Stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){throw 'Configuration read was incomplete.'};$offset+=$read}
    ,$bytes
}

function ConvertFrom-PaymentCronBytes {
    param([byte[]]$Bytes)
    $offset=0;$encoding=[Text.UTF8Encoding]::new($false,$true)
    if($Bytes.Length -ge 4 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254 -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0){$offset=4;$encoding=[Text.UTF32Encoding]::new($false,$true,$true)}
    elseif($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 254 -and $Bytes[3] -eq 255){$offset=4;$encoding=[Text.UTF32Encoding]::new($true,$true,$true)}
    elseif($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191){$offset=3}
    elseif($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254){$offset=2;$encoding=[Text.UnicodeEncoding]::new($false,$true,$true)}
    elseif($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255){$offset=2;$encoding=[Text.UnicodeEncoding]::new($true,$true,$true)}
    try{$text=$encoding.GetString($Bytes,$offset,$Bytes.Length-$offset)}catch{throw 'Configuration encoding is invalid; no changes made.'}
    [pscustomobject]@{Bytes=$Bytes;Text=$text;Encoding=$encoding;PreambleLength=$offset;Model=(Get-PaymentCronModel $text)}
}

function Read-PaymentCronSnapshot {
    param([string]$Path)
    Assert-PaymentCronLocalPath $Path
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{ConvertFrom-PaymentCronBytes (Read-PaymentCronBytes $stream)}finally{$stream.Dispose()}
}

function Test-PaymentCronBytesEqual {
    param([byte[]]$Left,[byte[]]$Right)
    $Left.Length -eq $Right.Length -and [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

function Write-PaymentCronBytes {
    param([IO.Stream]$Stream,[byte[]]$Bytes)
    $Stream.Position=0;$Stream.Write($Bytes,0,$Bytes.Length);$Stream.SetLength($Bytes.Length);$Stream.Flush($true)
}

function Test-PaymentCronAdministrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-PaymentCronSix {
    param($Context,$Snapshot)
    if($WhatIfPreference){throw 'WhatIf is enabled; no configuration was changed.'}
    if(-not (Test-PaymentCronAdministrator)){throw 'Run Windows PowerShell as Administrator to apply this change.'}
    if($Snapshot.Model.Six.Count -ne 1 -or $Snapshot.Model.Six[0].IsEnabled -isnot [bool]){throw 'Exactly one SIX schedule with a Boolean IsEnabled is required.'}
    if($Snapshot.Model.Six[0].IsEnabled){return $Snapshot}
    $fresh=@(Get-PaymentCronRunningServices|Where-Object Name -CEQ $Context.Name)
    if($fresh.Count -ne 1){throw 'Selected Payment Service is no longer uniquely running; no changes made.'}
    $current=Get-PaymentCronServiceContext $fresh[0]
    if($current.ProcessId -ne $Context.ProcessId -or $current.Path -ine $Context.Path -or $current.Command -cne $Context.Command){throw 'Payment Service changed after inspection; check again before applying.'}
    $stream=$null;$attempted=$false;$original=$null
    try{
        $stream=[IO.FileStream]::new($Context.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        Assert-PaymentCronLocalPath $Context.Path
        $original=Read-PaymentCronBytes $stream
        if(-not (Test-PaymentCronBytesEqual $original $Snapshot.Bytes)){throw 'appsettings.json changed after inspection; no changes made. Run the check again.'}
        $verified=ConvertFrom-PaymentCronBytes $original
        if($verified.Model.Six.Count -ne 1 -or $verified.Model.Six[0].IsEnabled -isnot [bool] -or $verified.Model.Six[0].IsEnabled){throw 'SIX schedule changed after inspection; no changes made.'}
        $token=$verified.Model.Six[0].Token
        if($verified.Text.Substring($token.Start,$token.Length) -cne 'false'){throw 'The exact SIX Boolean token could not be verified.'}
        $start=$verified.PreambleLength+$verified.Encoding.GetByteCount($verified.Text.Substring(0,$token.Start))
        $oldLength=$verified.Encoding.GetByteCount('false');$replacement=$verified.Encoding.GetBytes('true')
        $candidate=New-Object byte[] ($original.Length-$oldLength+$replacement.Length)
        [Buffer]::BlockCopy($original,0,$candidate,0,$start)
        [Buffer]::BlockCopy($replacement,0,$candidate,$start,$replacement.Length)
        [Buffer]::BlockCopy($original,$start+$oldLength,$candidate,$start+$replacement.Length,$original.Length-$start-$oldLength)
        $parsed=ConvertFrom-PaymentCronBytes $candidate
        if($parsed.Model.Six.Count -ne 1 -or $parsed.Model.Six[0].IsEnabled -ne $true){throw 'Candidate verification failed; no changes made.'}
        $attempted=$true;Write-PaymentCronBytes $stream $candidate
        $afterBytes=Read-PaymentCronBytes $stream
        if(-not (Test-PaymentCronBytesEqual $candidate $afterBytes)){throw 'Configuration write readback did not match.'}
        $after=ConvertFrom-PaymentCronBytes $afterBytes
        if($after.Model.Six.Count -ne 1 -or $after.Model.Six[0].IsEnabled -ne $true){throw 'SIX readback was not verified.'}
        $after
    }catch{
        $message=$_.Exception.Message
        if($attempted -and $null -ne $stream -and $null -ne $original){
            try{Write-PaymentCronBytes $stream $original;if(-not (Test-PaymentCronBytesEqual $original (Read-PaymentCronBytes $stream))){throw 'Restore mismatch'};$message+=' Original bytes restored and verified.'}
            catch{$message+=' Original bytes could not be restored; manual recovery required.'}
        }
        throw $message
    }finally{if($null -ne $stream){$stream.Dispose()}}
}

function Write-PaymentCronSchedules {
    param($Model)
    foreach($record in $Model.Records){
        Write-Host ''
        foreach($name in @('Provider','Name','UID','CronExpression','IsEnabled')){
            $value=if($null -eq $record.$name){'Not verified'}else{[string]$record.$name}
            # Avoid terminal control sequences from configuration strings.
            $value=[regex]::Replace($value,'[\x00-\x1F\x7F-\x9F]',' ')
            Write-Host ('  {0,-15}: {1}' -f $name,$value)
        }
    }
}

function Invoke-PaymentCronJob {
    try{
        if(-not [Environment]::Is64BitProcess){throw 'Run 64-bit Windows PowerShell.'}
        $services=@(Get-PaymentCronRunningServices)
        if($services.Count -eq 0){throw 'No running Payment Service found.'}
        $service=$services[0]
        if($services.Count -gt 1){
            Write-Host '  Select the running Payment Service:'
            for($i=0;$i -lt $services.Count;$i++){$key=if($i -ge 7){$i+2}else{$i+1};Write-Host ('  [{0}] {1}' -f $key,$services[$i].Name)}
            Write-Host '  [8] Back'
            do{$choice=([string](Read-Host '  Select option')).Trim();if($choice -eq '8'){return [pscustomobject]@{Status='Skipped';ReturnToMenu=$true}};$number=0;$valid=[int]::TryParse($choice,[ref]$number);if($number -gt 8){$number--}}while(-not $valid -or $number -lt 1 -or $number -gt $services.Count)
            $service=$services[$number-1]
        }
        $context=Get-PaymentCronServiceContext $service
        $snapshot=Read-PaymentCronSnapshot $context.Path
        Write-Host ('  Service : '+$context.Name+' - Running')
        Write-Host ('  Config  : '+$context.Path)
        Write-PaymentCronSchedules $snapshot.Model
        if($snapshot.Model.Six.Count -ne 1 -or $snapshot.Model.Six[0].IsEnabled -isnot [bool]){throw 'Exactly one SIX schedule with a Boolean IsEnabled is required. Manual review required.'}
        if($snapshot.Model.Six[0].IsEnabled){Write-Host "`n  Already enabled - no change needed." -ForegroundColor Green;return [pscustomobject]@{Status='Pass';ReturnToMenu=$false}}
        do{$answer=([string](Read-Host '  Enable SIX Cron? [Y/N]')).Trim()}while($answer -notin @('Y','N'))
        if($answer -ieq 'N'){Write-Host '  No changes made.';return [pscustomobject]@{Status='Skipped';ReturnToMenu=$true}}
        $after=Enable-PaymentCronSix $context $snapshot
        Write-Host "`n  SIX IsEnabled: False -> True" -ForegroundColor Green
        Write-Host '  File readback: Verified; all bytes outside the SIX Boolean are unchanged.' -ForegroundColor Green
        Write-Host '  Setting saved. Service reload/runtime status was not verified.'
        [pscustomobject]@{Status='Pass';ReturnToMenu=$false}
    }catch{Write-Host ('  Failed: '+$_.Exception.Message) -ForegroundColor Red;[pscustomobject]@{Status='Fail';ReturnToMenu=$false}}
}

$result=Invoke-PaymentCronJob
if($MenuRun){$result}else{if($result.Status -eq 'Fail'){exit 1}else{exit 0}}
