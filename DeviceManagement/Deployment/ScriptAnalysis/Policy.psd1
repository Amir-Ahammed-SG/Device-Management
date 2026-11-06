@{
    AnalyzerVersion = '1.25.0'
    BlockingSeverities = @('Error')
    BlockingRules = @(
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
    SourcePaths = @(
        'Start-DeviceManagement.ps1'
        'KioskThoroughCheck.ps1'
        'SaaSKioskThoroughCheckScript.ps1'
        'SubwayKioskThoroughCheck.ps1'
        'Core'
        'Config'
        'Checks'
        'Installations'
        'OtherTools'
        'Packages'
        'Handlers'
        'Tools'
        'Deployment'
    )
    # Tests are verified by the separate fixture jobs. Generated/backup files and
    # the unexpanded Bootstrap.ps1.template are not runnable source inputs.
    ExcludedDirectories = @('output', 'Backups', 'Docs', 'Tests', 'node_modules', '.git', '.ssh', '.aws', '.codex', '.agents')
}
