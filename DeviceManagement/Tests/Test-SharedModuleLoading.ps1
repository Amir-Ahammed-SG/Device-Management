# Exercise real module loading only; stop before mode/admin/device checks.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('output\shared-module-loading\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
foreach($folder in @('Core','Config')){Copy-Item -LiteralPath (Join-Path $root $folder) -Destination $fixture -Recurse}
$source=[IO.File]::ReadAllText((Join-Path $root 'KioskThoroughCheck.ps1'))
$boundary=$source.IndexOf('if (@($Apply')
if($boundary -lt 0){throw 'Cannot identify the preflight boundary.'}
$startup=$source.Substring(0,$boundary)+@'
[pscustomobject]@{
    Client=$script:KioskClientSettings.ClientType
    Origin=$script:KioskClientSettings.Origin
    AccountFunction=[bool](Get-Command Get-KioskAccountCheck -ErrorAction SilentlyContinue)
    ServiceFunction=[bool](Get-Command Get-LocalNmapInstaller -ErrorAction SilentlyContinue)
}|ConvertTo-Json -Compress
'@
$path=Join-Path $fixture 'Startup.ps1'
[IO.File]::WriteAllText($path,$startup,[Text.UTF8Encoding]::new($false))
$runtime=[IO.File]::ReadAllText((Join-Path $root 'Deployment\MemoryRuntime.ps1'))
. ([scriptblock]::Create($runtime))
$configuration=Import-PowerShellDataFile (Join-Path $root 'Config\KioskClients.psd1')
$files=@{'DeviceManagement/Core/KioskClient.psm1'=[IO.File]::ReadAllText((Join-Path $root 'Core\KioskClient.psm1'))}
foreach($part in Get-ChildItem (Join-Path $root 'Core\Kiosk') -Filter '*.ps1' -File){$files['DeviceManagement/Core/Kiosk/'+$part.Name]=[IO.File]::ReadAllText($part.FullName)}
$bundle=@{Files=$files;Configurations=@{KioskClients=$configuration}}
foreach($client in @('SaaS','Subway')){
    $local=& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path -ClientType $client | ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or $local.Client -cne $client -or -not $local.AccountFunction -or -not $local.ServiceFunction){throw 'Local shared-module loading failed.'}
    $execution=Invoke-DeviceManagementMemoryScript -Code $startup -Bundle $bundle -RuntimeCode $runtime -Parameters @{ClientType=$client}
    if($execution.State -ne 'Completed' -or $execution.Errors.Count -or $execution.Output.Count -ne 1){throw ('Embedded shared-module loading failed: '+($execution.Errors|Out-String))}
    $loaded=$execution.Output[0]|ConvertFrom-Json
    if($loaded.Client -cne $client -or $loaded.Origin -cne $configuration.Clients[$client].Origin -or -not $loaded.AccountFunction -or -not $loaded.ServiceFunction){throw 'Embedded client settings or definitions crossed scopes.'}
}
# Missing/invalid local libraries fail before any mode or device check executes.
$localServices=Join-Path $fixture 'Core\Kiosk\Services.ps1'
$originalServices=[IO.File]::ReadAllText($localServices)
foreach($problem in @('missing','syntax')){
    if($problem -eq 'missing'){[IO.File]::Delete($localServices)}else{[IO.File]::WriteAllText($localServices,'function Broken {')}
    $previousPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path -ClientType SaaS *> (Join-Path $fixture ($problem+'.log'))
    $exitCode=$LASTEXITCODE;$ErrorActionPreference=$previousPreference
    if($exitCode -eq 0){throw ('Local library preflight accepted '+$problem)}
    [IO.File]::WriteAllText($localServices,$originalServices,[Text.UTF8Encoding]::new($false))
}
$files.Remove('DeviceManagement/Core/Kiosk/Services.ps1')
$failed=Invoke-DeviceManagementMemoryScript -Code $startup -Bundle $bundle -RuntimeCode $runtime -Parameters @{ClientType='SaaS'}
if($failed.State -eq 'Completed' -and -not $failed.Errors.Count){throw 'A missing shared module was accepted.'}
Write-Output 'PASS: real local and embedded shared-library loading, explicit client isolation and missing-module preflight rejection; no device checks executed.'
