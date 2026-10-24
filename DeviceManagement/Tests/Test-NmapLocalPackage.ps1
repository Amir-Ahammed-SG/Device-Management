$projectRoot = Split-Path $PSScriptRoot -Parent
# Run isolated check blocks with mocked installers. Never install Nmap or scan.
$ErrorActionPreference = 'Stop'
$parent = Split-Path $projectRoot -Parent
$fixtureRoot = Join-Path $projectRoot ('output\nmap-tests\run-' + [guid]::NewGuid().ToString('N'))
$fixturePackage = Join-Path $fixtureRoot 'DeviceManagement\Packages\Nmap'
New-Item -ItemType Directory -Path $fixturePackage -Force | Out-Null
$fixtureBytes = [Text.Encoding]::UTF8.GetBytes('Fixture installer bytes. This is not an executable.')
$fixtureBinary = Join-Path $fixturePackage 'nmap-7.992-setup.exe'
$fixtureManifest = Join-Path $fixturePackage 'NmapPackage.psd1'
function Assert-Nmap { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Reset-Package {
    [IO.File]::WriteAllBytes($fixtureBinary, $fixtureBytes)
    $hash = (Get-FileHash -LiteralPath $fixtureBinary -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($fixtureManifest, "@{ Version='7.992'; FileName='nmap-7.992-setup.exe'; SHA256='$hash' }")
}
function Reset-NmapFixture {
    $script:ApplyChanges=$true; $script:installed=$false; $script:createsExecutable=$true
    $script:osName='Microsoft Windows 10 Pro'; $script:installerExit=0
    $script:versionThrows=$false; $script:launchThrows=$false; $script:wingetMissing=$false
    $script:discoveryThrows=$false; $script:createsBeforeFailure=$false
    $script:installCalls=0; $script:packageCalls=0; $script:versionCalls=0; $script:osCalls=0; $script:wingetCalls=0
    $script:capturedRow=$null
    Reset-Package
}
foreach ($sourceName in @('SaaSKioskThoroughCheckScript.ps1','SubwayKioskThoroughCheck.ps1')) {
    $sourcePath=Join-Path $parent $sourceName
    $source=[IO.File]::ReadAllText($sourcePath)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
    Assert-Nmap ($errors.Count -eq 0) "Parser errors in $sourceName"
    $start=$source.IndexOf('# 4.3 Nmap Tool'); $end=$source.IndexOf('# 4.4 lodctr /R', $start)
    $block=$source.Substring($start,$end-$start)
    $functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Get-NmapExecutable','Get-NmapVersion','Get-LocalNmapInstaller')},$true))
    Assert-Nmap ($functions.Count -eq 3) 'Missing Nmap function definitions'
    . ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"))
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-ReportDefinitionHtml'},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $localInstallerFunction=${function:Get-LocalNmapInstaller}
    foreach ($definition in ($functions | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $block=$block.Remove($definition.Extent.StartOffset-$start,$definition.Extent.Text.Length)
    }
    # Keep real -File semantics for $PSScriptRoot in the selected check block.
    $checkBlock=Join-Path $fixtureRoot 'isolated-nmap-check.ps1'
    [IO.File]::WriteAllText($checkBlock,$block,[Text.UTF8Encoding]::new($false))
    function Start-AuditStep { param($Number,$Name) }
    function Write-Host { [CmdletBinding()]param($Object,$ForegroundColor) }
    function Test-CanApply { return $script:ApplyChanges }
    function Get-NmapExecutable { if ($script:discoveryThrows) { throw 'Fixture discovery failed' }; if ($script:installed) { return 'C:\Fixture Nmap\nmap.exe' } return $null }
    function Get-NmapVersion { param($Path) $script:versionCalls++; if ($script:versionThrows) { throw 'Version command failed' }; [pscustomobject]@{Version='7.992';Output='Nmap version 7.992'} }
    function Get-LocalNmapInstaller { param($ScriptDirectory) $script:packageCalls++; Assert-Nmap ($ScriptDirectory -eq $fixtureRoot) 'Check did not pass its script directory'; & $localInstallerFunction -ScriptDirectory $ScriptDirectory }
    function Get-CimInstance { [CmdletBinding()]param($ClassName) Assert-Nmap ($ClassName -eq 'Win32_OperatingSystem') 'Unexpected device query'; $script:osCalls++; [pscustomobject]@{Caption=$script:osName} }
    function Start-Process {
        [CmdletBinding()]param($FilePath,[switch]$Wait,[switch]$PassThru)
        Assert-Nmap ($FilePath -eq $fixtureBinary -and $Wait -and $PassThru) 'Wrong installer path or wait options'
        $script:installCalls++
        if ($script:launchThrows) { throw 'Fixture launch failed' }
        if (($script:installerExit -eq 0 -and $script:createsExecutable) -or $script:createsBeforeFailure) { $script:installed=$true }
        [pscustomobject]@{ExitCode=$script:installerExit}
    }
    function Get-Command { [CmdletBinding()]param($Name,$CommandType) Assert-Nmap ($Name -eq 'winget.exe') 'Unexpected executable lookup'; if (-not $script:wingetMissing) { [pscustomobject]@{Source='Invoke-FixtureWinget'} } }
    function Invoke-FixtureWinget {
        $script:wingetCalls++
        Assert-Nmap (($args -join ' ') -match 'install --id Insecure.Nmap --exact --source winget') 'Windows 11 winget invocation changed'
        $global:LASTEXITCODE=$script:installerExit
        if ($script:installerExit -eq 0 -and $script:createsExecutable) { $script:installed=$true }
    }
    function Add-AuditEntry {
        param($SectionNumber,$SectionTitle,$ItemTitle,$ItemSub,$Shortcut,$FoundStateHtml,$Status,$ActionTaken)
        $script:capturedRow=[pscustomobject]@{Status=$Status;Findings=$FoundStateHtml;Action=$ActionTaken}
    }

    Reset-NmapFixture; $script:ApplyChanges=$false
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:installCalls -eq 0 -and $script:packageCalls -eq 0 -and $script:wingetCalls -eq 0) 'Windows 10 Audit installed or bypassed missing Nmap'
    Assert-Nmap ($script:capturedRow.Findings -match 'Tool State:</span> Not installed\. Please install manually\.' -and $script:capturedRow.Action -match 'local Nmap setup wizard') 'Audit missing-package guidance incorrect'
    foreach ($apply in @($false,$true)) {
        Reset-NmapFixture; $script:ApplyChanges=$apply; $script:installed=$true
        . $checkBlock
        Assert-Nmap ($script:capturedRow.Status -eq 'Pass' -and $script:installCalls -eq 0 -and $script:packageCalls -eq 0 -and $script:osCalls -eq 0 -and $script:versionCalls -eq 1) 'Existing Nmap was reinstalled or not checked'
        Assert-Nmap ($script:capturedRow.Findings -match 'Tool State:</span> Installed' -and $script:capturedRow.Findings -match 'Version:</span> 7\.992' -and $script:capturedRow.Findings -match 'Executable Path:</span> C:') 'Installed tool, version or executable path was not recorded'
    }
    Reset-NmapFixture
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Pass' -and $script:installCalls -eq 1 -and $script:wingetCalls -eq 0 -and $script:versionCalls -eq 1) ('Local install and version readback failed: ' + $script:capturedRow.Action)
    Assert-Nmap ($script:capturedRow.Findings -match 'Version:</span> 7\.992' -and $script:capturedRow.Findings -match 'Executable Path:</span> C:' -and $script:capturedRow.Action -match 'local setup wizard') 'Detected version was not recorded'
    Reset-NmapFixture; Remove-Item -LiteralPath $fixtureManifest -Force
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:installCalls -eq 0 -and $script:capturedRow.Action -match 'package is missing') 'Missing manifest launched an installer'
    Reset-NmapFixture; [IO.File]::AppendAllText($fixtureBinary,'Corruption')
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:installCalls -eq 0 -and $script:capturedRow.Action -match 'checksum mismatch') 'Damaged package was executed'
    Reset-NmapFixture; Remove-Item -LiteralPath $fixtureBinary -Force
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:installCalls -eq 0 -and $script:capturedRow.Action -match 'installer is missing') 'Missing binary was executed'
    Reset-NmapFixture; [IO.File]::WriteAllText($fixtureManifest,"@{ Version='7.992'; FileName='..\other.exe'; SHA256='$('A'*64)' }")
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:installCalls -eq 0 -and $script:capturedRow.Action -match 'manifest is invalid') 'Invalid package path was accepted'
    Reset-NmapFixture; $script:installerExit=1
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Action -match 'exit code 1' -and $script:versionCalls -eq 0) 'Installer failure reported success'
    Reset-NmapFixture; $script:launchThrows=$true
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Action -match 'launch failed') 'Installer launch failure reported success'
    Reset-NmapFixture; $script:createsExecutable=$false
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Action -match 'still missing') 'Installer exit 0 without executable reported success'
    Reset-NmapFixture; $script:versionThrows=$true
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Action -match 'Version command failed') 'Version failure reported success'
    Assert-Nmap ($script:capturedRow.Findings -match 'Tool State:</span> Installed' -and $script:capturedRow.Findings -match 'Version:</span> Not verified\. Please check manually\.') 'Version failure hid an installed executable or invented a version'
    Reset-NmapFixture; $script:discoveryThrows=$true
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Findings -match 'Tool State:</span> Not verified\. Please check manually\.' -and $script:installCalls -eq 0) 'Failed discovery was treated as a confirmed missing tool or triggered an install'
    Reset-NmapFixture; $script:installerExit=1; $script:createsBeforeFailure=$true
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Findings -match 'Tool State:</span> Installed' -and $script:versionCalls -eq 0) 'Installer failure readback lost the detected executable or changed Fail to Pass'
    Reset-NmapFixture; $script:osName='Microsoft Windows 11 Pro'
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Pass' -and $script:wingetCalls -eq 1 -and $script:packageCalls -eq 0) 'Windows 11 no longer uses winget'
    Reset-NmapFixture; $script:osName='Microsoft Windows 11 Pro'; $script:installerExit=9
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:capturedRow.Action -match 'exit code 9') 'winget exit code was ignored'
    Reset-NmapFixture; $script:osName='Microsoft Windows 11 Pro'; $script:wingetMissing=$true
    . $checkBlock
    Assert-Nmap ($script:capturedRow.Status -eq 'Fail' -and $script:wingetCalls -eq 0) 'Unavailable winget reported success'
    Microsoft.PowerShell.Utility\Write-Host "PASS: $sourceName Windows 10 Audit/Apply, existing installation, package preflight, installer failures/readback and Windows 11 winget"

    $counterStart=$source.IndexOf('# 4.4 lodctr /R')
    $counterEnd=$source.IndexOf('# END COMPONENT CHECKS',$counterStart)
    $counterBlock=[scriptblock]::Create($source.Substring($counterStart,$counterEnd-$counterStart))
    function Start-Process {
        [CmdletBinding()]param($FilePath,$ArgumentList,[switch]$Wait,$WindowStyle,[switch]$PassThru)
        Assert-Nmap ($FilePath -eq 'lodctr.exe' -and $ArgumentList -eq '/R' -and $Wait -and $WindowStyle -eq 'Hidden' -and $PassThru) 'Unexpected performance-counter execution'
        $script:installCalls++
        [pscustomobject]@{ExitCode=0}
    }
    foreach($apply in @($false,$true)){
        Reset-NmapFixture; $script:ApplyChanges=$apply
        . $counterBlock
        if($apply){
            Assert-Nmap ($script:installCalls -eq 1 -and $script:capturedRow.Status -eq 'Pass' -and $script:capturedRow.Findings -match 'Rebuild State:</span> Exit code: 0' -and $script:capturedRow.Findings -notmatch 'Audit|Not executed') 'Apply counter Findings contain an Audit annotation or lost the execution result'
        } else {
            Assert-Nmap ($script:installCalls -eq 0 -and $script:capturedRow.Status -eq 'Bypass' -and $script:capturedRow.Findings -match 'Audit:</span> Not executed' -and $script:capturedRow.Findings -notmatch 'Rebuild State') 'Audit counter Findings or read-only behavior is incorrect'
        }
    }
    Microsoft.PowerShell.Utility\Write-Host "PASS: $sourceName Audit/Apply performance-counter Findings and Audit never executes the rebuild"
}

# Verify acquisition independently with fake downloads and signatures.
$savePath=Join-Path $projectRoot 'Packages\Nmap\Save-NmapPackage.ps1'
$tokens=$null; $errors=$null
$saveAst=[Management.Automation.Language.Parser]::ParseFile($savePath,[ref]$tokens,[ref]$errors)
Assert-Nmap ($errors.Count -eq 0) 'Preparation script did not parse'
$saveDefinition=$saveAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-NmapPackage'},$true)
. ([scriptblock]::Create($saveDefinition.Extent.Text))
$script:downloadCalls=0; $script:badDigest=$false; $script:badSignature=$false; $script:downloadError=$false
$fixtureHash=(Get-FileHash -LiteralPath $fixtureBinary -Algorithm SHA256).Hash
function Invoke-WebRequest {
    [CmdletBinding()]param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
    $script:downloadCalls++
    if ($script:downloadError) { throw 'Fixture HTTPS certificate error' }
    Assert-Nmap ($Uri -like 'https://nmap.org/dist/*') 'Preparation used a nonofficial source'
    if ($OutFile) { [IO.File]::WriteAllBytes($OutFile,$fixtureBytes) } else {
        $hash=if ($script:badDigest) { '0'*64 } else { $fixtureHash }
        $groups=([regex]::Matches($hash,'.{8}') | ForEach-Object { $_.Value }) -join ' '
        [pscustomobject]@{Content="nmap-7.992-setup.exe: SHA256 = $groups`r`n"}
    }
}
function Get-AuthenticodeSignature {
    [CmdletBinding()]param($LiteralPath)
    if ($script:badSignature) { return [pscustomobject]@{Status='NotSigned';SignerCertificate=$null} }
    [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Insecure.Com LLC, O=Insecure.Com LLC, C=US'}}
}
$acquisition=Join-Path $fixtureRoot 'prepared-package'
Save-NmapPackage -PackageDirectory $acquisition -Version '7.992' | Out-Null
Assert-Nmap ($script:downloadCalls -eq 2 -and (Test-Path -LiteralPath (Join-Path $acquisition 'NmapPackage.psd1'))) 'Verified package was not saved'
Save-NmapPackage -PackageDirectory $acquisition -Version '7.992' | Out-Null
Assert-Nmap ($script:downloadCalls -eq 2) 'Already prepared package was downloaded again'
foreach ($failure in @('digest','signature','download')) {
    $script:badDigest=$failure -eq 'digest'; $script:badSignature=$failure -eq 'signature'; $script:downloadError=$failure -eq 'download'
    $failedDirectory=Join-Path $fixtureRoot ('rejected-' + $failure)
    $rejected=$false
    try { Save-NmapPackage -PackageDirectory $failedDirectory -Version '7.992' | Out-Null } catch { $rejected=$true }
    Assert-Nmap $rejected "Preparation accepted $failure failure"
    Assert-Nmap (-not (Test-Path -LiteralPath (Join-Path $failedDirectory 'NmapPackage.psd1'))) 'Failed acquisition left a manifest'
    Assert-Nmap (@(Get-ChildItem -LiteralPath $failedDirectory -Filter '*.exe' -Force).Count -eq 0) 'Failed acquisition left executable bytes'
}
$oldManifest=[IO.File]::ReadAllText((Join-Path $acquisition 'NmapPackage.psd1'))
$rejected=$false
try { Save-NmapPackage -PackageDirectory $acquisition -Version '7.991' | Out-Null } catch { $rejected=$true }
Assert-Nmap ($rejected -and [IO.File]::ReadAllText((Join-Path $acquisition 'NmapPackage.psd1')) -ceq $oldManifest) 'Failed preparation changed the existing package manifest'
Microsoft.PowerShell.Utility\Write-Host 'PASS: Package acquisition, official-source checksum/publisher checks, idempotency, cleanup and preservation after failed downloads'
