# Load shared sources directly; each fixture selects its client explicitly.
# This helper never executes the check engine or an installer.
$script:KioskTestProjectRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $script:KioskTestProjectRoot 'Core\KioskClient.psm1') -Force
$script:KioskTestConfiguration=Import-PowerShellDataFile (Join-Path $script:KioskTestProjectRoot 'Config\KioskClients.psd1')
function Set-KioskTestClient {
    param([Parameter(Mandatory=$true)][ValidateSet('SaaS','Subway')][string]$ClientType)
    $script:KioskClientSettings=Get-KioskClientSettings -ClientType $ClientType -Configuration $script:KioskTestConfiguration
}
function Read-KioskTestSource {
    param([string]$Path)
    $text=[IO.File]::ReadAllText($Path)
    if($text -notmatch '(?m)^# KioskFunction '){return $text}
    # Reconstruct the source view at the original definition boundaries so tests
    # can inspect guarded check blocks without executing the engine or loaders.
    $definitions=@{}
    $parts=Join-Path (Split-Path $Path -Parent) 'Core\Kiosk'
    foreach($file in Get-ChildItem -LiteralPath $parts -Filter '*.ps1' -File){
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ('Shared module syntax error: '+$file.Name)}
        foreach($fn in $ast.EndBlock.Statements){
            if($fn -is [Management.Automation.Language.FunctionDefinitionAst]){
                if($definitions.ContainsKey($fn.Name)){throw ('Duplicate shared function: '+$fn.Name)}
                $definitions[$fn.Name]=$fn.Extent.Text
            }
        }
    }
    $text=[regex]::Replace($text,'(?s)# BEGIN KIOSK SHARED MODULES.*?# END KIOSK SHARED MODULES\r?\n','')
    [regex]::Replace($text,'(?m)^# KioskFunction ([A-Za-z0-9-]+)',[Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $name=$match.Groups[1].Value
        if(-not $definitions.ContainsKey($name)){throw ('Shared function is missing: '+$name)}
        $definitions[$name]
    })
}
class KioskTestSource {
    static [string] ReadAllText([string]$Path) { return (Read-KioskTestSource $Path) }
    static [System.Management.Automation.Language.ScriptBlockAst] ParseFile([string]$Path,[ref]$Tokens,[ref]$Errors) {
        return [System.Management.Automation.Language.Parser]::ParseInput([KioskTestSource]::ReadAllText($Path),$Path,$Tokens,$Errors)
    }
}
Set-KioskTestClient -ClientType SaaS
