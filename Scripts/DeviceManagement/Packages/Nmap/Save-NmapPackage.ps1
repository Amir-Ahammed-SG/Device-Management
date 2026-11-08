# Preparation only: download and verify the official package; never install it.
[CmdletBinding()]
param (
    [ValidatePattern('^\d+(\.\d+)+$')][string]$Version = '7.992'
)

function Save-NmapPackage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$PackageDirectory,
        [Parameter(Mandatory)][ValidatePattern('^\d+(\.\d+)+$')][string]$Version
    )
    $ErrorActionPreference = 'Stop'
    $fileName = 'nmap-{0}-setup.exe' -f $Version
    $installerPath = Join-Path $PackageDirectory $fileName
    $manifestPath = Join-Path $PackageDirectory 'NmapPackage.psd1'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $existing = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
        if ($existing.Version -eq $Version -and $existing.FileName -ceq $fileName -and $existing.SHA256 -match '^[A-Fa-f0-9]{64}$' -and (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
            if ((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash -eq $existing.SHA256) {
                Write-Output "Verified local Nmap $Version package already present: $installerPath"
                return
            }
        }
    }
    New-Item -ItemType Directory -Path $PackageDirectory -Force -ErrorAction Stop | Out-Null
    $temporaryPath = Join-Path $PackageDirectory ('.nmap-download-{0}.exe' -f [guid]::NewGuid().ToString('N'))
    $previousProgressPreference = $ProgressPreference
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $sourceUrl = 'https://nmap.org/dist/{0}' -f $fileName
        $digestUrl = 'https://nmap.org/dist/sigs/{0}.digest.txt' -f $fileName
        # Keep normal HTTPS certificate validation for both official downloads.
        $digest = [string](Invoke-WebRequest -Uri $digestUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content
        $hashMatch = [regex]::Match($digest, '(?i)SHA256(?:\s*\([^)]+\))?\s*=\s*((?:[a-f0-9][ \t\r\n]*){64})(?![a-f0-9])')
        if (-not $hashMatch.Success) { throw 'Official Nmap checksum file contains no recognizable SHA256 value.' }
        $expectedHash = ($hashMatch.Groups[1].Value -replace '\s', '').ToUpperInvariant()
        Invoke-WebRequest -Uri $sourceUrl -OutFile $temporaryPath -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        $actualHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actualHash -ne $expectedHash) { throw 'Downloaded Nmap installer does not match the official SHA256 checksum.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $temporaryPath -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Insecure\.Com LLC(,|$)') {
            throw 'Downloaded Nmap installer does not have a valid Insecure.Com LLC publisher signature.'
        }
        # Publish the manifest last, after all download and authenticity checks succeed.
        Move-Item -LiteralPath $temporaryPath -Destination $installerPath -Force -ErrorAction Stop
        [IO.File]::WriteAllText((Join-Path $PackageDirectory ($fileName + '.digest.txt')), $digest, [Text.UTF8Encoding]::new($false))
        $manifest = "@{`r`n    Version = '$Version'`r`n    FileName = '$fileName'`r`n    SHA256 = '$expectedHash'`r`n    SourceUrl = '$sourceUrl'`r`n}`r`n"
        [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
        Write-Output "Prepared and verified Nmap $Version package: $installerPath"
    } finally {
        $ProgressPreference = $previousProgressPreference
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop }
    }
}

Save-NmapPackage -PackageDirectory $PSScriptRoot -Version $Version
