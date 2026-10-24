[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]{8}-[A-Za-z0-9-]+$')][string]$ReleaseId
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $projectRoot -Parent
$releaseDirectory = Join-Path $projectRoot ('output\releases\' + $ReleaseId)
if (Test-Path -LiteralPath $releaseDirectory) { throw 'Release directory already exists. Use a new release ID.' }
$utf8 = New-Object Text.UTF8Encoding($false)
function Get-SourceAst {
    param([string]$Text)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
function Replace-OnlyExit {
    param([string]$Text,[string]$Replacement)
    $ast=Get-SourceAst $Text
    $exits=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.ExitStatementAst]},$true))
    if ($exits.Count -ne 1 -or $exits[0].Parent -ne $ast.EndBlock) { throw 'Expected exactly one top-level exit boundary.' }
    return $Text.Remove($exits[0].Extent.StartOffset,$exits[0].Extent.EndOffset-$exits[0].Extent.StartOffset).Insert($exits[0].Extent.StartOffset,$Replacement)
}
$files=[ordered]@{
    'SaaSKioskThoroughCheckScript.ps1'=Join-Path $workspaceRoot 'SaaSKioskThoroughCheckScript.ps1'
    'SubwayKioskThoroughCheck.ps1'=Join-Path $workspaceRoot 'SubwayKioskThoroughCheck.ps1'
    'DeviceManagement/Start-DeviceManagement.ps1'=Join-Path $projectRoot 'Start-DeviceManagement.ps1'
    'DeviceManagement/Checks/KIOSK/ThoroughCheck.ps1'=Join-Path $projectRoot 'Checks\KIOSK\ThoroughCheck.ps1'
    'DeviceManagement/Installations/KIOSK/SaaS-Install.ps1'=Join-Path $projectRoot 'Installations\KIOSK\SaaS-Install.ps1'
    'DeviceManagement/Installations/KIOSK/SaaS/Kiosk_Mode_Setup.ps1'=Join-Path $projectRoot 'Installations\KIOSK\SaaS\Kiosk_Mode_Setup.ps1'
    'Deployment/MemoryRuntime.ps1'=Join-Path $PSScriptRoot 'MemoryRuntime.ps1'
}
foreach ($folder in @('Core','Config')) {
    $filter=if ($folder -eq 'Core') {'*.psm1'} else {'*.psd1'}
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $projectRoot $folder) -Filter $filter -File | Sort-Object Name)) {
        $files.Add(('DeviceManagement/'+$folder+'/'+$file.Name),$file.FullName)
    }
}
$runtimeCode=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MemoryRuntime.ps1'))
$dispatcher=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MemoryDispatcher.ps1'))
$startup=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MemoryMenuStartup.ps1'))
$fileManifest=@()
$resourceLines=New-Object 'Collections.Generic.List[string]'
foreach ($name in $files.Keys) {
    $source=$files[$name]
    $text=[IO.File]::ReadAllText($source)
    $ast=Get-SourceAst $text
    $originalHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ($name -in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
        $text=Replace-OnlyExit $text '[pscustomobject]@{ MemoryCheckCompleted=$true; ExitCode=[int]$global:LASTEXITCODE; ReportPath=if ($generateReport) { [string]$reportPath } else { $null } }'
    } elseif ($name -eq 'DeviceManagement/Start-DeviceManagement.ps1') {
        $start=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$architectureRoot' })
        $end=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$thoroughCheckOperation.ImplementationState' })
        if ($start.Count -ne 1 -or $end.Count -ne 1 -or $end[0].Right.Extent.Text -notmatch "'Ready'") { throw 'Launcher startup boundary changed.' }
        $text=$text.Remove($start[0].Extent.StartOffset,$end[0].Extent.EndOffset-$start[0].Extent.StartOffset).Insert($start[0].Extent.StartOffset,$startup)
        $text=Replace-OnlyExit $text 'return'
    } elseif ($name -eq 'DeviceManagement/Core/PackageLoader.psm1') {
        $dispatch=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ConfiguredOperation'},$true))
        if ($dispatch.Count -ne 1) { throw 'Operation dispatch boundary changed.' }
        $text=$text.Remove($dispatch[0].Extent.StartOffset,$dispatch[0].Extent.EndOffset-$dispatch[0].Extent.StartOffset).Insert($dispatch[0].Extent.StartOffset,$dispatcher)
        $text='param($MemoryBundle,$MemoryRuntime)' + "`r`n" + $runtimeCode + "`r`n" + $text
    }
    [void](Get-SourceAst $text)
    $bytes=$utf8.GetBytes($text)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try {$compiledHash=[BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-','')} finally {$hasher.Dispose()}
    $data=[Convert]::ToBase64String($bytes)
    $resourceLines.Add(("    '{0}' = @{{ Data = '{1}'; SHA256 = '{2}' }}" -f $name,$data,$compiledHash))
    $fileManifest += [pscustomobject]@{Path=$name;SourceSHA256=$originalHash;RuntimeSHA256=$compiledHash}
}
$resources='@{' + "`r`n" + ($resourceLines -join "`r`n") + "`r`n}"
$entry=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Bootstrap.ps1.template')).Replace('@@RESOURCES@@',$resources)
[void](Get-SourceAst $entry)
[void][IO.Directory]::CreateDirectory($releaseDirectory)
$entryPath=Join-Path $releaseDirectory 'Start-DeviceManagement.ps1'
[IO.File]::WriteAllText($entryPath,$entry,$utf8)
$entryHash=(Get-FileHash -LiteralPath $entryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=[ordered]@{ReleaseId=$ReleaseId;Delivery='InMemory';CreatedAt=[DateTimeOffset]::Now.ToString('o');BootstrapSHA256=$entryHash;Files=$fileManifest}
[IO.File]::WriteAllText((Join-Path $releaseDirectory 'release.json'),($manifest | ConvertTo-Json -Depth 5),$utf8)
Write-Warning 'In-memory project delivery does not include a local Nmap installer; the documented Windows 10 limitation remains.'
[pscustomobject]@{ReleaseDirectory=$releaseDirectory;Files=$files.Count;BootstrapSHA256=$entryHash;BootstrapPath=$entryPath}
