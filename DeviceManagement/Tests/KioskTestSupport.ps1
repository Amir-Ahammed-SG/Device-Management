# Read actual shared implementations while retaining client-labelled fixture loops.
# This helper never executes the check engine or an installer.
$script:KioskTestProjectRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $script:KioskTestProjectRoot 'Core\KioskClient.psm1') -Force
$script:KioskTestConfiguration=Import-PowerShellDataFile (Join-Path $script:KioskTestProjectRoot 'Config\KioskClients.psd1')
function Read-KioskTestSource {
    param([string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    foreach($client in @('SaaS','Subway')) {
        $checkName=if($client -eq 'SaaS'){'SaaSKioskThoroughCheckScript.ps1'}else{'SubwayKioskThoroughCheck.ps1'}
        $edgeName=if($client -eq 'SaaS'){'Kiosk_Mode_Setup.ps1'}else{'kiosk_mode_setup.ps1'}
        $map=@{}
        $map[(Join-Path $script:KioskTestProjectRoot $checkName)]='KioskThoroughCheck.ps1'
        $map[(Join-Path $script:KioskTestProjectRoot ('Installations\KIOSK\'+$client+'-Install.ps1'))]='Installations\KIOSK\Install.ps1'
        $map[(Join-Path $script:KioskTestProjectRoot ('Installations\KIOSK\'+$client+'\'+$edgeName))]='Installations\KIOSK\Setup-Edge.ps1'
        $map[(Join-Path $script:KioskTestProjectRoot ('Installations\KIOSK\'+$client+'\Kiosk_Mode_Setup_Chrome.ps1'))]='Installations\KIOSK\Setup-Chrome.ps1'
        if($map.ContainsKey($full)) {
            $script:KioskClientSettings=Get-KioskClientSettings -ClientType $client -ProjectRoot $script:KioskTestProjectRoot
            return [IO.File]::ReadAllText((Join-Path $script:KioskTestProjectRoot $map[$full]))
        }
    }
    return [IO.File]::ReadAllText($full)
}
class KioskTestSource {
    static [string] ReadAllText([string]$Path) { return (Read-KioskTestSource $Path) }
    static [System.Management.Automation.Language.ScriptBlockAst] ParseFile([string]$Path,[ref]$Tokens,[ref]$Errors) {
        return [System.Management.Automation.Language.Parser]::ParseInput([KioskTestSource]::ReadAllText($Path),$Path,$Tokens,$Errors)
    }
}
