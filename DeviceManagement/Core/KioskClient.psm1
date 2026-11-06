Set-StrictMode -Version 2.0
function Get-KioskClientSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateSet('SaaS','Subway')][string]$ClientType,
        [string]$ProjectRoot,
        [hashtable]$Configuration
    )
    if(-not $Configuration) {
        if([string]::IsNullOrWhiteSpace($ProjectRoot)){throw 'A project root or embedded kiosk configuration is required.'}
        $Configuration=Import-PowerShellDataFile -LiteralPath (Join-Path $ProjectRoot 'Config\KioskClients.psd1') -ErrorAction Stop
    }
    if($Configuration.SchemaVersion -ne '1.0' -or -not $Configuration.Clients.ContainsKey($ClientType)){throw 'Invalid or missing kiosk client configuration.'}
    $settings=@{} + $Configuration.Clients[$ClientType]
    $settings.PreferredServiceNames=@($settings.PreferredServiceNames)
    if($settings.ClientType -cne $ClientType -or $settings.Origin -notmatch '^https://[A-Za-z0-9.-]+$' -or $settings.OnboardingPath -cne '/#/onboarding/login'){
        throw 'Invalid kiosk client identity, origin or onboarding route.'
    }
    if([string]::IsNullOrWhiteSpace($settings.PaymentServiceRequirement) -or [string]::IsNullOrWhiteSpace($settings.LauncherUrlPattern)) {throw 'Missing kiosk service or URL matching configuration.'}
    if(@($settings.PreferredServiceNames).Count -eq 0 -and [string]::IsNullOrWhiteSpace($settings.PreferredServiceNamePattern)){throw 'A preferred payment service matching rule is required.'}
    [void][regex]::new($settings.LauncherUrlPattern)
    if($settings.PreferredServiceNamePattern){[void][regex]::new($settings.PreferredServiceNamePattern)}
    return $settings
}
Export-ModuleMember -Function Get-KioskClientSettings
