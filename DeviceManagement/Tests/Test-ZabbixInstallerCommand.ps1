
. (Join-Path $PSScriptRoot 'KioskTestSupport.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
# Execute the generated child command against fixture ZIPs and fake service APIs.
# No network, MSI executable or real Windows service operation is allowed.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$root=$projectRoot
$fixtureRoot=Join-Path $projectRoot ('output\zabbix-command\run-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
function Assert-InstallerCommand {param([bool]$Condition,[string]$Message) if (-not $Condition) {throw $Message}}
$fakeInstaller=@'
param([string]$MsiPath,[Parameter(Mandatory=$true)][string]$Hostname,[string]$ScriptSource,[string]$LogPath)
[IO.File]::WriteAllText($global:fixtureRecord,(@{Hostname=$Hostname;MsiPresent=[IO.File]::Exists($MsiPath);MonitoringPresent=[IO.File]::Exists($ScriptSource)} | ConvertTo-Json -Compress))
if ($global:fixtureFailure) {throw 'Fixture MSI failed'}
'@
$prefix=@'
$global:fixtureZip=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ZIP__'))
$global:fixtureRecord=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__RECORD__'))
$global:fixtureStageRecord=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__STAGE__'))
$global:fixtureRestartRecord=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__RESTART__'))
$global:fixtureFailure=__FAIL__
function Invoke-WebRequest {
    [CmdletBinding()]param([switch]$UseBasicParsing,$Uri,$OutFile)
    if ($Uri -cne 'https://cdn-ito.selisesme.com/omk/zabbix/zabbix.zip') {throw 'Unexpected URL'}
    [IO.File]::WriteAllText($global:fixtureStageRecord,(Split-Path $OutFile -Parent))
    [IO.File]::Copy($global:fixtureZip,$OutFile)
}
function Read-Host {throw 'Unexpected installer prompt'}
function Start-Process {throw 'Real MSI/native invocation is forbidden in this fixture'}
function Set-Service {throw 'Real service change is forbidden'}
function Stop-Service {throw 'Real service stop is forbidden'}
function Get-Service {
    [CmdletBinding()]param($Name)
    if ($Name -cne 'Zabbix Agent 2') {throw 'Another service queried'}
    $service=[pscustomobject]@{Status='Running'}
    $service | Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)}
    return $service
}
function Restart-Service {[CmdletBinding()]param($Name) if ($Name -cne 'Zabbix Agent 2') {throw 'Another service restarted'};[IO.File]::WriteAllText($global:fixtureRestartRecord,'Restarted fixture agent')}
function Start-Service {throw 'Unexpected start path for running fixture'}
'@
foreach($sourceName in @('SaaS','Subway')){
    Set-KioskTestClient -ClientType $sourceName
    $tokens=$null;$errors=$null
    $ast=[KioskTestSource]::ParseFile((Join-Path $root 'KioskThoroughCheck.ps1'),[ref]$tokens,[ref]$errors)
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ZabbixInstallCommand'},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
    foreach ($case in @('success','failure','badArchive','missingParameter')) {
        $folder=Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($folder)
        $zip=Join-Path $folder 'fixture.zip'
        $archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entries=@{'zabbix-msi-install.ps1'=$fakeInstaller;'zabbix.msi'='Not a real installer';'omk-monitoring.conf'='# Fixture only'}
            if ($case -eq 'missingParameter') {$entries['zabbix-msi-install.ps1']='param($Other) throw ''Must not run'''}
            if ($case -eq 'badArchive') {$entries['../escaped.txt']='Must never be extracted'}
            foreach ($item in $entries.GetEnumerator()) {
                $entry=$archive.CreateEntry($item.Key)
                $writer=[IO.StreamWriter]::new($entry.Open())
                try {$writer.Write($item.Value)} finally {$writer.Dispose()}
            }
        } finally {$archive.Dispose()}
        $record=Join-Path $folder 'called.json'
        $stageRecord=Join-Path $folder 'stage.txt'
        $restartRecord=Join-Path $folder 'restart.txt'
        $bootstrap=$prefix
        foreach ($pair in @(@('__ZIP__',$zip),@('__RECORD__',$record),@('__STAGE__',$stageRecord),@('__RESTART__',$restartRecord))) {
            $bootstrap=$bootstrap.Replace($pair[0],[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair[1])))
        }
        $bootstrap=$bootstrap.Replace('__FAIL__',$(if ($case -eq 'failure') {'$true'} else {'$false'}))
        $hostname="LAUNCHER-01 '`$literal & name"
        $command=$bootstrap+"`r`n"+(New-ZabbixInstallCommand -Hostname $hostname)
        $childPath=Join-Path $folder 'installer-child.ps1'
        [IO.File]::WriteAllText($childPath,$command,[Text.UTF8Encoding]::new($false))
        $priorPreference=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $childPath *> (Join-Path $folder 'child-output.txt')
        $code=$LASTEXITCODE
        $ErrorActionPreference=$priorPreference
        Assert-InstallerCommand (($code -eq 0) -eq ($case -eq 'success')) "Incorrect installer child completion: $case"
        if ($case -in @('success','failure')) {
            $called=[KioskTestSource]::ReadAllText($record) | ConvertFrom-Json
            Assert-InstallerCommand ($called.Hostname -ceq $hostname -and $called.MsiPresent -and $called.MonitoringPresent) 'Installer did not receive exact hostname and package paths'
        } else {Assert-InstallerCommand (-not [IO.File]::Exists($record)) 'Invalid package installer ran'}
        Assert-InstallerCommand ([IO.File]::Exists($restartRecord) -eq ($case -eq 'success')) 'Agent restart occurred after failed install or was omitted after success'
        $stage=[KioskTestSource]::ReadAllText($stageRecord)
        Assert-InstallerCommand ([IO.Directory]::Exists($stage) -eq ($case -ne 'success')) 'Success cleanup or failure-log retention incorrect'
        Assert-InstallerCommand (-not [IO.File]::Exists((Join-Path $stage 'escaped.txt'))) 'Archive wrote outside package folder'
        if ([IO.Directory]::Exists($stage)) {
            $resolved=[IO.Path]::GetFullPath($stage)
            $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
            Assert-InstallerCommand ($resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^ThoroughCheck-Zabbix-[0-9a-f]{32}$') 'Fixture cleanup target outside intended temp root'
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    Write-Output "PASS: $sourceName generated installer command executes with exact launcher hostname, no prompt, package validation, failed-install isolation, new-agent restart and scoped cleanup"
}
