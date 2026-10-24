$script:ArchitectureRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'DeviceManagement'
$script:Clients = Import-PowerShellDataFile (Join-Path $script:ArchitectureRoot 'Config\Clients.psd1')
$script:Operations = Import-PowerShellDataFile (Join-Path $script:ArchitectureRoot 'Config\Operations.psd1')

Import-Module (Join-Path $script:ArchitectureRoot 'Core\Validation.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\Context.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\Menu.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\Reporting.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\PackageLoader.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\PaymentAudit.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\PaymentInstall.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\PaymentUninstall.psm1') -Force
Import-Module (Join-Path $script:ArchitectureRoot 'Core\KioskInstallation.psm1') -Force

Describe 'Device-management source and configuration' {
    It 'parses every PowerShell architecture file' {
        foreach ($file in (Get-ChildItem $script:ArchitectureRoot -Recurse -Include *.ps1,*.psm1)) {
            $tokens = $null; $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should Be 0
        }
    }
    It 'defines exactly the approved clients' {
        @($script:Clients.Clients.Id) -join ',' | Should Be 'Subway,SaaS,ViCafe'
    }
    It 'limits ViCafe to POS' {
        $client = Get-ClientDefinition $script:Clients 'ViCafe'
        @($client.Devices).Count | Should Be 1
        $client.Devices[0] | Should Be 'POS'
    }
    It 'allows KIOSK POS and KDS for Subway and SaaS' {
        foreach ($clientId in @('Subway', 'SaaS')) {
            (Get-ClientDefinition $script:Clients $clientId).Devices -join ',' | Should Be 'KIOSK,POS,KDS'
        }
    }
    It 'enables only approved client and device selections' {
        (Get-DeviceOperations $script:Operations KIOSK | Where-Object Id -eq ThoroughCheck).ImplementationState | Should Be 'Pending'
        (Get-DeviceOperations $script:Operations KIOSK SaaS | Where-Object Id -eq ThoroughCheck).ImplementationState | Should Be 'Ready'
        (Get-DeviceOperations $script:Operations KIOSK Subway | Where-Object Id -eq ThoroughCheck).ImplementationState | Should Be 'Ready'
        (Get-DeviceOperations $script:Operations POS | Where-Object Id -eq ThoroughCheck).ImplementationState | Should Be 'Pending'
        (Get-DeviceOperations $script:Operations KDS | Where-Object Id -eq ThoroughCheck).ImplementationState | Should Be 'Pending'
        @($script:Operations.Operations | Where-Object { $_.Id -ne 'ThoroughCheck' } | ForEach-Object { $_.ReadyDevices } | Where-Object { $_ }).Count | Should Be 0
        $payment = Get-DeviceOperations $script:Operations KIOSK SaaS | Where-Object Id -eq PaymentService
        (Test-OperationSelectionReady $payment SaaS KIOSK Audit) | Should Be $true
        (Test-OperationSelectionReady $payment SaaS KIOSK Apply) | Should Be $true
        (Test-OperationSelectionReady $payment SaaS KIOSK Uninstall) | Should Be $true
        (Test-OperationSelectionReady $payment Subway KIOSK Audit) | Should Be $false
        $kioskInstallation = Get-DeviceOperations $script:Operations KIOSK SaaS | Where-Object Id -eq KioskInstallation
        (Test-OperationSelectionReady $kioskInstallation SaaS KIOSK Audit) | Should Be $false
        (Test-OperationSelectionReady $kioskInstallation SaaS KIOSK Apply) | Should Be $true
        $paymentModes = Get-OperationModes $script:Operations $payment SaaS KIOSK
        ($paymentModes | Where-Object Id -eq Audit).DisplayName | Should Be 'Audit Report'
        ($paymentModes | Where-Object Id -eq Apply).DisplayName | Should Be 'Install'
        ($paymentModes | Where-Object Id -eq Uninstall).DisplayName | Should Be 'Remove Payment Service'
        @($paymentModes).Count | Should Be 3
        @($paymentModes | Where-Object { $_.Description }).Count | Should Be 0
        $thorough = Get-DeviceOperations $script:Operations KIOSK SaaS | Where-Object Id -eq ThoroughCheck
        $thoroughModes = Get-OperationModes $script:Operations $thorough SaaS KIOSK
        @($thoroughModes | Where-Object Id -eq Uninstall).Count | Should Be 0
        @($thoroughModes | Where-Object { -not [string]::IsNullOrEmpty($_.Description) }).Count | Should Be 0
    }
}

Describe 'Device-specific operation routing' {
    It 'shows only KIOSK operations on KIOSK' {
        @(Get-DeviceOperations $script:Operations KIOSK).Id -join ',' | Should Be 'ThoroughCheck,PaymentService,KioskInstallation'
    }
    It 'shows only POS operations on POS' {
        @(Get-DeviceOperations $script:Operations POS).Id -join ',' | Should Be 'ThoroughCheck,PaymentService,PosInstallation'
    }
    It 'shows only KDS operations on KDS' {
        @(Get-DeviceOperations $script:Operations KDS).Id -join ',' | Should Be 'ThoroughCheck,PaymentService,KdsInstallation'
    }
    It 'rejects KIOSK for ViCafe' {
        { Assert-RunSelection $script:Clients $script:Operations ViCafe KIOSK ThoroughCheck Audit } | Should Throw
    }
    It 'accepts both modes for every configured operation' {
        foreach ($client in $script:Clients.Clients) {
            foreach ($device in $client.Devices) {
                foreach ($operation in (Get-DeviceOperations $script:Operations $device)) {
                    (Assert-RunSelection $script:Clients $script:Operations $client.Id $device $operation.Id Audit).Operation.Id | Should Be $operation.Id
                    (Assert-RunSelection $script:Clients $script:Operations $client.Id $device $operation.Id Apply).Operation.Id | Should Be $operation.Id
                }
            }
        }
    }
}

Describe 'Safe Phase 1 dispatch' {
    It 'returns unavailable without invoking a handler' {
        $context = New-DeviceManagementContext Subway KIOSK PaymentService Apply 'Subway - Fixture' $script:ArchitectureRoot
        $operation = Get-DeviceOperations $script:Operations KIOSK | Where-Object Id -eq PaymentService
        $result = Invoke-ConfiguredOperation $script:ArchitectureRoot $operation $context
        $result.Status | Should Be 'Unavailable'
        $result.Message | Should Match 'No system changes were made'
    }
    It 'maps each KIOSK Thorough Check to its client handler' {
        $context = New-DeviceManagementContext Subway KIOSK ThoroughCheck Audit 'Fixture' $script:ArchitectureRoot
        $operation = Get-DeviceOperations $script:Operations KIOSK | Where-Object Id -eq ThoroughCheck
        $handler = Resolve-OperationHandlerPath $script:ArchitectureRoot $operation $context
        $handler | Should Be (Join-Path $script:ArchitectureRoot 'Checks\KIOSK\Subway-ThoroughCheck.ps1')
        Test-Path -LiteralPath $handler -PathType Leaf | Should Be $true
        $context = New-DeviceManagementContext SaaS KIOSK ThoroughCheck Audit 'Fixture' $script:ArchitectureRoot
        $handler = Resolve-OperationHandlerPath $script:ArchitectureRoot $operation $context
        $handler | Should Be (Join-Path $script:ArchitectureRoot 'Checks\KIOSK\SaaS-ThoroughCheck.ps1')
        Test-Path -LiteralPath $handler -PathType Leaf | Should Be $true
    }
    It 'maps the SaaS KIOSK Payment audit to its handler' {
        $context = New-DeviceManagementContext SaaS KIOSK PaymentService Audit 'Fixture' $script:ArchitectureRoot
        $operation = Get-DeviceOperations $script:Operations KIOSK SaaS | Where-Object Id -eq PaymentService
        $handler = Resolve-OperationHandlerPath $script:ArchitectureRoot $operation $context
        $handler | Should Be (Join-Path $script:ArchitectureRoot 'Payments\SaaS\KIOSK\PaymentService.ps1')
        Test-Path -LiteralPath $handler -PathType Leaf | Should Be $true
    }
    It 'passes explicit mode and architecture-run switches to the current script' {
        $handlerText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Checks\KIOSK\ThoroughCheck.ps1'))
        $handlerText | Should Match "'-ArchitectureRun'"
        $handlerText | Should Match "arguments \+= '-Apply'"
        $handlerText | Should Match "arguments \+= '-AuditOnly'"
    }
    It 'resolves a handler only inside the architecture root' {
        $context = New-DeviceManagementContext Subway KIOSK ThoroughCheck Audit 'Fixture' $script:ArchitectureRoot
        $operation = [pscustomobject]@{ HandlerTemplate = '..\outside.ps1' }
        { Resolve-OperationHandlerPath $script:ArchitectureRoot $operation $context } | Should Throw
    }
    It 'creates a complete immutable selection context' {
        $context = New-DeviceManagementContext SaaS KDS KdsInstallation Audit 'SaaS - Fixture' $script:ArchitectureRoot
        $context.ClientType | Should Be 'SaaS'
        $context.DeviceType | Should Be 'KDS'
        $context.Operation | Should Be 'KdsInstallation'
        $context.Mode | Should Be 'Audit'
        $context.RunId | Should Match '^\d{8}_\d{6}_[a-f0-9]{8}$'
    }
    It 'keeps the selected Payment Service package in the run context' {
        $package = [pscustomobject]@{ Id = 'Fixture-v9'; DisplayName = 'Payment Service v9' }
        $context = New-DeviceManagementContext SaaS KIOSK PaymentService Apply 'SaaS - Fixture' $script:ArchitectureRoot $package
        $context.SelectedPackage.Id | Should Be 'Fixture-v9'
    }
    It 'creates an Uninstall context only for the Payment Service workflow' {
        $context = New-DeviceManagementContext SaaS KIOSK PaymentService Uninstall '' $script:ArchitectureRoot
        $context.Mode | Should Be 'Uninstall'
        $payment = Get-DeviceOperations $script:Operations KIOSK SaaS | Where-Object Id -eq PaymentService
        (Assert-RunSelection $script:Clients $script:Operations SaaS KIOSK PaymentService Uninstall).Operation.Id | Should Be 'PaymentService'
        (Test-OperationSelectionReady $payment SaaS KIOSK Uninstall) | Should Be $true
        { Assert-RunSelection $script:Clients $script:Operations SaaS KIOSK ThoroughCheck Uninstall } | Should Throw
    }
}

Describe 'Client-specific KIOSK installation routing' {
    It 'dispatches KIOSK Installation directly in Apply mode without a mode screen' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $launcherText | Should Match "selectedOperation\.Id -eq 'KioskInstallation'"
        $launcherText | Should Match "selectedMode = 'Apply'"
        $launcherText | Should Match "Invoke-ConfiguredOperation"
    }

    It 'routes SaaS and Subway to separate installation handlers' {
        foreach ($client in @('SaaS', 'Subway')) {
            $context = New-DeviceManagementContext $client KIOSK KioskInstallation Apply 'Fixture' $script:ArchitectureRoot
            $operation = Get-DeviceOperations $script:Operations KIOSK $client | Where-Object Id -eq KioskInstallation
            $handler = Resolve-OperationHandlerPath $script:ArchitectureRoot $operation $context
            $handler | Should Be (Join-Path $script:ArchitectureRoot "Installations\KIOSK\$client-Install.ps1")
            Test-Path -LiteralPath $handler -PathType Leaf | Should Be $true
            (Test-OperationSelectionReady $operation $client KIOSK Audit) | Should Be $false
            (Test-OperationSelectionReady $operation $client KIOSK Apply) | Should Be $true
        }
    }

    It 'creates the launcher, Startup BAT and Desktop shortcut with the selected URL' {
        $profile = Join-Path $TestDrive 'SELISE-KIOSK'
        New-Item -ItemType Directory -Path $profile -Force | Out-Null
        $edge = Join-Path $TestDrive 'msedge.exe'
        Set-Content -LiteralPath $edge -Value 'fixture'
        $result = Write-KioskLauncherFiles $profile $edge 'https://kiosk.subway.ch/#/onboarding/login' 'RID' 'Kiosk-1' 'SUB-HOST'
        $result.Url | Should Be 'https://kiosk.subway.ch/#/onboarding/login?restaurantId=RID&kioskId=Kiosk-1&host=SUB-HOST'
        Test-Path -LiteralPath $result.LaunchPath -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $result.BatchPath -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $result.ShortcutPath -PathType Leaf | Should Be $true
        [IO.File]::ReadAllText($result.LaunchPath) | Should Match '--edge-kiosk-type=fullscreen'
        (New-Object -ComObject WScript.Shell).CreateShortcut($result.ShortcutPath).TargetPath | Should Be $result.BatchPath
    }
}

Describe 'Subway KIOSK Thorough Check isolation' {
    It 'uses only the Subway kiosk origin while the SaaS source stays on OrderMonkey' {
        $subwayPath = Join-Path (Split-Path $script:ArchitectureRoot -Parent) 'SubwayKioskThoroughCheck.ps1'
        $saasPath = Join-Path (Split-Path $script:ArchitectureRoot -Parent) 'SaaSKioskThoroughCheckScript.ps1'
        $subwayText = [IO.File]::ReadAllText($subwayPath)
        $saasText = [IO.File]::ReadAllText($saasPath)
        $subwayText | Should Match 'https://kiosk\.subway\.ch'
        $subwayText | Should Not Match 'https://kiosk\.ordermonkey\.com'
        $saasText | Should Match 'https://kiosk\.ordermonkey\.com'
        $saasText | Should Not Match 'https://kiosk\.subway\.ch'
    }
}

Describe 'SaaS Payment Service configuration audit' {
    It 'handles an empty service collection without a parameter-binding error' {
        $selected = Select-RunningPaymentService @()
        $selected | Should BeNullOrEmpty
    }

    It 'reads commented JSON without damaging URL values' {
        $json = @'
{
  "ServicePort": 5009,
  "IPAddress": "127.0.0.1", // local endpoint
  "PaymentService": "SIX",
  "Endpoint": "https://example.test/path",
  "PaymentConfiguration": { "SixTerminals": [{ "KioskId": "Kiosk-1", "TerminalId": "12345" }] },
  "ScheduleConfiguration": { "Schedules": [{ "Provider": "SendPing", "IsEnabled": false }, { "Provider": "KitchenTicketPrint", "IsKioskPrintingEnabled": false }] },
  "Print": { "PrinterName": "Kitchen", "KioskPrinterName": "Receipt" }
}

'@
        $configuration = ConvertFrom-PaymentJson $json
        $configuration.Endpoint | Should Be 'https://example.test/path'
        $lines = Get-PaymentConfigurationAuditLines $configuration
        $lines -join "`n" | Should Match 'SIX:'
        $lines -join "`n" | Should Match 'Terminal 1 KioskId: Kiosk-1'
        $lines -join "`n" | Should Match 'Terminal 1 TerminalId: 12345'
        $lines -join "`n" | Should Match 'Send Ping:'
        $lines -join "`n" | Should Match 'IsEnabled: False'
        $lines -join "`n" | Should Match 'Cloud Print:'
        $lines -join "`n" | Should Match 'IsKioskPrintingEnabled: False'
        $lines -join "`n" | Should Match 'Printer Information:'
        $lines -join "`n" | Should Match 'PrinterName: Kitchen'
        $lines -join "`n" | Should Match 'KioskPrinterName: Receipt'
    }

    It 'reports the requested PRINT setting' {
        $configuration = ConvertFrom-PaymentJson '{"PaymentService":"PRINT","PaymentConfiguration":{"Options":{"IsDeferredInitiation":true}},"Print":{}}'
        (Get-PaymentConfigurationAuditLines $configuration) -join "`n" | Should Match 'IsDeferredInitiation: True'
    }

    It 'reports the requested NETS terminal settings' {
        $json = '{"PaymentService":"NETS","PaymentConfiguration":{"NetsTerminals":[{"PosId":"POS","KioskId":"Kiosk-3","TerminalIPAddress":"10.0.0.8","Language":"en","IsSetupEnabled":false}]},"Print":{}}'
        $lines = (Get-PaymentConfigurationAuditLines (ConvertFrom-PaymentJson $json)) -join "`n"
        $lines | Should Match 'NETS:'
        $lines | Should Match 'Terminal 1 PosId: POS'
        $lines | Should Match 'Terminal 1 KioskId: Kiosk-3'
        $lines | Should Match 'Terminal 1 TerminalIPAddress: 10.0.0.8'
        $lines | Should Match 'Terminal 1 Language: en'
        $lines | Should Match 'Terminal 1 IsSetupEnabled: False'
    }
}

Describe 'SaaS Payment Service v9 installation contract' {
    It 'pins the reviewed SaaS KIOSK package metadata' {
        $packages = Import-PowerShellDataFile (Join-Path $script:ArchitectureRoot 'Config\PaymentPackages.psd1')
        $package = @($packages.Packages)[0]
        $package.DisplayName | Should Be 'Payment Service v9'
        $package.Client | Should Be 'SaaS'
        $package.Devices -join ',' | Should Be 'KIOSK'
        $package.Version | Should Be '9.0.0.0'
        $package.ServiceName | Should Be 'AspPaymentSaaSProd'
        $package.Sha256 | Should Be '2A48EC6FFF78DCD619C7069C98D5C6FC3F6D9429269F329180EC4FC82DE185A1'
        { Assert-PaymentPackageMetadata $package } | Should Not Throw
    }

    It 'accepts a hash-matched package with the required deployment files' {
        $source = Join-Path $TestDrive 'package-source'
        $archive = Join-Path $TestDrive 'package.zip'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'deploy.ps1') -Value '# fixture'
        Set-Content -LiteralPath (Join-Path $source 'deploy.json') -Value '{"ServiceName":"Fixture","Version":"9.0.0.0","InstallPath":"C:\\Fixture","ExecutableName":"Fixture.exe"}'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($source, $archive)
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        $package = [pscustomobject]@{ Id='Fixture';Version='9.0.0.0';Uri='https://example.test/package.zip';Sha256=$hash;ServiceName='Fixture';InstallPath='C:\Fixture';ExecutableName='Fixture.exe';ExecutableRelativePath='PaymentService\Fixture.exe';ConfigRelativePath='PaymentService\appsettings.json';TimApiRelativePath='PaymentService\TimApi.cfg';VersionRelativePath='version.txt';DeployScript='deploy.ps1' }
        (Assert-PaymentPackageArchive $archive $package) | Should Be $hash
    }

    It 'rejects a package when its hash does not match' {
        $archive = Join-Path $TestDrive 'mismatch.zip'
        Set-Content -LiteralPath $archive -Value 'not the approved package'
        $package = [pscustomobject]@{ Id='Fixture';Version='9.0.0.0';Uri='https://example.test/package.zip';Sha256=('0' * 64);ServiceName='Fixture';InstallPath='C:\Fixture';ExecutableName='Fixture.exe';ExecutableRelativePath='PaymentService\Fixture.exe';ConfigRelativePath='PaymentService\appsettings.json';TimApiRelativePath='PaymentService\TimApi.cfg';VersionRelativePath='version.txt';DeployScript='deploy.ps1' }
        { Assert-PaymentPackageArchive $archive $package } | Should Throw
    }

    It 'accepts an empty existing-service list during first-time installation and rollback' {
        { Disable-RunningPaymentServices @() } | Should Not Throw
        { Restore-PaymentServiceStates @() } | Should Not Throw
    }

    It 'restores a previously running old service as Automatic and Running after failure' {
        $global:PreviousPaymentController = [pscustomobject]@{ Status = 'Stopped' }
        $global:PreviousPaymentController | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param ($Status, $Timeout) $this.Status = $Status }
        Mock Get-Service { $global:PreviousPaymentController } -ModuleName PaymentInstall
        Mock Set-Service { } -ModuleName PaymentInstall
        Mock Start-Service { $global:PreviousPaymentController.Status = 'Running' } -ModuleName PaymentInstall

        $errors = @(Restore-PaymentServiceStates @([pscustomobject]@{ Name='AspPaymentOld';State='Running';StartMode='Manual' }))

        $errors.Count | Should Be 0
        Assert-MockCalled Set-Service 1 -Exactly -Scope It -ModuleName PaymentInstall -ParameterFilter { $StartupType -eq 'Automatic' }
        Assert-MockCalled Start-Service 1 -Exactly -Scope It -ModuleName PaymentInstall
        Remove-Variable PreviousPaymentController -Scope Global -ErrorAction SilentlyContinue
    }

    It 'resolves the installed executable without relying on the audit module scope' {
        $service = [pscustomobject]@{ Name = 'AspPaymentSaaSProd'; PathName = '"C:\PaymentServiceSaaSProd\Kiosk Payment Middleware.exe" --service' }
        $path = & (Get-Module PaymentInstall) { param ($Service) Get-PaymentInstallServiceExecutablePath $Service } $service
        $path | Should Be 'C:\PaymentServiceSaaSProd\Kiosk Payment Middleware.exe'
    }

    It 'uses the package version marker while retaining the executable file version separately' {
        $installPath = Join-Path $TestDrive 'ApprovedPaymentInstall'
        $paymentFolder = Join-Path $installPath 'PaymentService'
        New-Item -ItemType Directory -Path $paymentFolder -Force | Out-Null
        $executable = Join-Path $paymentFolder 'Fixture.exe'
        Set-Content -LiteralPath $executable -Value 'fixture executable'
        Set-Content -LiteralPath (Join-Path $paymentFolder 'appsettings.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $paymentFolder 'TimApi.cfg') -Value 'fixture'
        Set-Content -LiteralPath (Join-Path $installPath 'version.txt') -Value '9.0.0.0'
        $package = [pscustomobject]@{ Id='Fixture';Version='9.0.0.0';Uri='https://example.test/package.zip';Sha256=('0' * 64);ServiceName='Fixture';InstallPath=$installPath;ExecutableName='Fixture.exe';ExecutableRelativePath='PaymentService\Fixture.exe';ConfigRelativePath='PaymentService\appsettings.json';TimApiRelativePath='PaymentService\TimApi.cfg';VersionRelativePath='version.txt';DeployScript='deploy.ps1' }

        $verified = & (Get-Module PaymentInstall) { param ($Package, $Executable) Assert-PaymentInstalledFiles -Package $Package -ActualExecutablePath $Executable } $package $executable

        $verified.PackageVersion | Should Be '9.0.0.0'
        $verified.Paths.Executable | Should Be $executable
    }

    It 'returns a first-time failed deployment to a clean pre-install state' {
        $installPath = Join-Path $TestDrive 'RollbackInstall'
        $existingBackup = Join-Path $TestDrive 'RollbackBackup'
        $failedInstall = Join-Path $TestDrive 'FailedInstall'
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'new.txt') -Value 'new'
        Mock Get-Service { $null } -ModuleName PaymentInstall

        & (Get-Module PaymentInstall) {
            param ($InstallPath, $BackupPath, $FailedPath)
            Restore-PaymentTargetAfterFailedInstall -ServiceName 'Fixture' -OriginalService $null `
                -InstallPath $InstallPath -ExistingBackupPath $BackupPath -FailedInstallPath $FailedPath
        } $installPath $existingBackup $failedInstall

        Test-Path -LiteralPath $installPath | Should Be $false
        Test-Path -LiteralPath $failedInstall | Should Be $false
    }

    It 'restores the previous service as Automatic and Running and removes failed upgrade files' {
        $installPath = Join-Path $TestDrive 'UpgradeInstall'
        $existingBackup = Join-Path $TestDrive 'UpgradeBackup'
        $failedInstall = Join-Path $TestDrive 'FailedUpgrade'
        New-Item -ItemType Directory -Path $installPath,$existingBackup -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'new.txt') -Value 'new'
        Set-Content -LiteralPath (Join-Path $existingBackup 'old.txt') -Value 'old'
        $original = [pscustomobject]@{ Name='Fixture';DisplayName='Fixture';PathName='C:\Fixture.exe';StartMode='Manual';State='Stopped';StartName='LocalSystem' }
        $global:PaymentRollbackController = [pscustomobject]@{ Status = 'Stopped' }
        $global:PaymentRollbackController | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param ($Status, $Timeout) $this.Status = $Status }
        Mock Get-Service { $global:PaymentRollbackController } -ModuleName PaymentInstall
        Mock Set-Service { } -ModuleName PaymentInstall
        Mock Start-Service { $global:PaymentRollbackController.Status = 'Running' } -ModuleName PaymentInstall

        & (Get-Module PaymentInstall) {
            param ($Original, $InstallPath, $BackupPath, $FailedPath)
            Restore-PaymentTargetAfterFailedInstall -ServiceName 'Fixture' -OriginalService $Original `
                -InstallPath $InstallPath -ExistingBackupPath $BackupPath -FailedInstallPath $FailedPath
        } $original $installPath $existingBackup $failedInstall

        Test-Path -LiteralPath (Join-Path $installPath 'old.txt') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $failedInstall | Should Be $false
        Assert-MockCalled Set-Service 1 -Exactly -Scope It -ModuleName PaymentInstall -ParameterFilter { $StartupType -eq 'Automatic' }
        Assert-MockCalled Start-Service 1 -Exactly -Scope It -ModuleName PaymentInstall
        Remove-Variable PaymentRollbackController -Scope Global -ErrorAction SilentlyContinue
    }

    It 'configures and verifies Restart Restart No Action recovery for the new service' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ModuleName PaymentInstall
        Mock Test-PaymentInstallRecoveryPolicy { $true } -ModuleName PaymentInstall

        & (Get-Module PaymentInstall) { Set-PaymentInstallRecoveryPolicy -ServiceName 'AspPaymentSaaSProd' }

        Assert-MockCalled Start-Process 1 -Exactly -Scope It -ModuleName PaymentInstall -ParameterFilter {
            $FilePath -eq 'sc.exe' -and $ArgumentList -match 'reset= 0' -and $ArgumentList -match 'restart/60000/restart/60000'
        }
        Assert-MockCalled Test-PaymentInstallRecoveryPolicy 1 -Exactly -Scope It -ModuleName PaymentInstall
    }

    It 'keeps vendor console output out of the installation result pipeline' {
        $installText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Core\PaymentInstall.psm1'))
        $installText.Contains('& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $deployScript 2>&1 | Out-Host') | Should Be $true
        $installText.Contains('$deployExitCode = $LASTEXITCODE') | Should Be $true
    }
}

Describe 'Safe Payment Service uninstall' {
    BeforeEach {
        $global:PaymentUninstallGetServiceCalls = 0
        $global:PaymentUninstallServices = @()
        Mock Test-PaymentUninstallAdministrator { $true } -ModuleName PaymentUninstall
        Mock Get-CimInstance { @($global:PaymentUninstallServices) } -ModuleName PaymentUninstall
        Mock Get-Service {
            $global:PaymentUninstallGetServiceCalls++
            if ($global:PaymentUninstallGetServiceCalls -eq 1) {
                return [pscustomobject]@{ Status = [ServiceProcess.ServiceControllerStatus]::Stopped }
            }
            return $null
        } -ModuleName PaymentUninstall
        Mock Invoke-WindowsPaymentServiceDelete { } -ModuleName PaymentUninstall
    }

    AfterEach {
        Remove-Variable PaymentUninstallGetServiceCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable PaymentUninstallServices -Scope Global -ErrorAction SilentlyContinue
    }

    It 'moves the selected installation to a verified backup before removing the service' {
        $installPath = Join-Path $TestDrive 'PaymentServiceCurrent'
        $backupRoot = Join-Path $TestDrive 'PaymentServiceBackups'
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        $executablePath = Join-Path $installPath 'KioskPaymentMiddleware.exe'
        Set-Content -LiteralPath $executablePath -Value 'fixture executable'
        Set-Content -LiteralPath (Join-Path $installPath 'appsettings.json') -Value '{"fixture":true}'
        $service = [pscustomobject]@{ Name='AspPaymentFixture';DisplayName='Fixture Payment';State='Stopped';StartMode='Manual';StartName='LocalSystem';PathName=('"' + $executablePath + '"') }
        $global:PaymentUninstallServices = @($service)

        $result = Invoke-PaymentServiceUninstall -Service $service -BackupRoot $backupRoot -RunId 'fixture_run'

        $result.ServiceName | Should Be 'AspPaymentFixture'
        Test-Path -LiteralPath $installPath | Should Be $false
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'Installation\KioskPaymentMiddleware.exe') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'Installation\appsettings.json') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'ServiceMetadata.json') -PathType Leaf | Should Be $true
        Assert-MockCalled Invoke-WindowsPaymentServiceDelete 1 -Exactly -Scope It -ModuleName PaymentUninstall
    }

    It 'includes the v9 package root and version marker in the removal backup' {
        $installPath = Join-Path $TestDrive 'PaymentServiceSaaSProd'
        $paymentFolder = Join-Path $installPath 'PaymentService'
        $backupRoot = Join-Path $TestDrive 'PaymentServiceV9Backups'
        New-Item -ItemType Directory -Path $paymentFolder -Force | Out-Null
        $executablePath = Join-Path $paymentFolder 'KioskPaymentMiddleware.exe'
        Set-Content -LiteralPath $executablePath -Value 'fixture executable'
        Set-Content -LiteralPath (Join-Path $installPath 'version.txt') -Value '9.0.0.0'
        $service = [pscustomobject]@{ Name='AspPaymentFixture';DisplayName='Fixture Payment';State='Stopped';StartMode='Manual';StartName='LocalSystem';PathName=('"' + $executablePath + '"') }
        $global:PaymentUninstallServices = @($service)

        $result = Invoke-PaymentServiceUninstall -Service $service -BackupRoot $backupRoot -RunId 'v9_fixture'

        Test-Path -LiteralPath $installPath | Should Be $false
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'Installation\version.txt') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'Installation\PaymentService\KioskPaymentMiddleware.exe') -PathType Leaf | Should Be $true
    }

    It 'restores the installation folder when Windows service removal fails' {
        $installPath = Join-Path $TestDrive 'PaymentServiceRollback'
        $backupRoot = Join-Path $TestDrive 'PaymentServiceBackupsRollback'
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        $executablePath = Join-Path $installPath 'KioskPaymentMiddleware.exe'
        Set-Content -LiteralPath $executablePath -Value 'fixture executable'
        $service = [pscustomobject]@{ Name='AspPaymentRollback';DisplayName='Fixture Payment';State='Stopped';StartMode='Manual';StartName='LocalSystem';PathName=('"' + $executablePath + '"') }
        $global:PaymentUninstallServices = @($service)
        Mock Invoke-WindowsPaymentServiceDelete { throw 'fixture delete failure' } -ModuleName PaymentUninstall

        $failureMessage = $null
        try { Invoke-PaymentServiceUninstall -Service $service -BackupRoot $backupRoot -RunId 'rollback_run' } catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should Match 'fixture delete failure'
        Test-Path -LiteralPath $installPath -PathType Container | Should Be $true
        Test-Path -LiteralPath $executablePath -PathType Leaf | Should Be $true
    }

    It 'refuses to move a folder shared by another Windows service' {
        $installPath = Join-Path $TestDrive 'SharedPaymentService'
        $backupRoot = Join-Path $TestDrive 'SharedBackups'
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        $paymentExecutable = Join-Path $installPath 'KioskPaymentMiddleware.exe'
        $otherExecutable = Join-Path $installPath 'OtherService.exe'
        Set-Content -LiteralPath $paymentExecutable -Value 'payment'
        Set-Content -LiteralPath $otherExecutable -Value 'other'
        $service = [pscustomobject]@{ Name='AspPaymentShared';DisplayName='Fixture Payment';State='Stopped';StartMode='Manual';StartName='LocalSystem';PathName=('"' + $paymentExecutable + '"') }
        $other = [pscustomobject]@{ Name='OtherWindowsService';DisplayName='Other';State='Stopped';StartMode='Manual';StartName='LocalSystem';PathName=('"' + $otherExecutable + '"') }
        $global:PaymentUninstallServices = @($service, $other)

        $failureMessage = $null
        try { Invoke-PaymentServiceUninstall -Service $service -BackupRoot $backupRoot -RunId 'shared_run' } catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should Match 'shared with service'
        Test-Path -LiteralPath $installPath -PathType Container | Should Be $true
        Assert-MockCalled Invoke-WindowsPaymentServiceDelete 0 -Exactly -Scope It -ModuleName PaymentUninstall
    }

    It 'rejects protected Windows and shared application roots before any mutation' {
        $module = Get-Module PaymentUninstall
        foreach ($protectedPath in @($env:SystemRoot, (Join-Path $env:SystemRoot 'System32'), [Environment]::GetFolderPath('ProgramFiles'))) {
            { & $module {
                param ($Path)
                Assert-PaymentUninstallPathSafe -InstallPath $Path -BackupRoot 'C:\PaymentServiceBackups' `
                    -SelectedServiceName 'AspPaymentFixture' -AllServices @()
            } $protectedPath } | Should Throw
        }
    }
}

Describe 'Payment Service menu routing' {
    It 'shows versions with Audit and Uninstall without a separate Install screen' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $launcherText.Contains("if (`$selectedOperation.Id -eq 'PaymentService') { 'Package' } else { 'Mode' }") | Should Be $true
        $launcherText.Contains("DisplayName = 'Audit Report'") | Should Be $true
        $launcherText.Contains("DisplayName = 'Remove Payment Service'") | Should Be $true
        $launcherText.Contains("SelectionType       = 'Package'") | Should Be $true
        $launcherText.Contains("`$selectedMode = 'Apply'") | Should Be $true
        $launcherText | Should Not Match 'Payment Service \| Select Version'
        $launcherText | Should Not Match "Prompt 'Select version'"
    }

    It 'requires an exact service-name confirmation and uses the backup root' {
        $handlerText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Payments\SaaS\KIOSK\PaymentService.ps1'))
        $handlerText | Should Match 'Type service name'
        $handlerText | Should Match '-cne \$selectedInventory\.Name'
        $handlerText.Contains("-BackupRoot 'C:\PaymentServiceBackups'") | Should Be $true
    }

    It 'returns one layer at a time from the result screen' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $launcherText.Contains("Write-Host '  [8] Back' -ForegroundColor DarkGray") | Should Be $true
        $launcherText.Contains('Back to Operations') | Should Be $false
        $launcherText.Contains("if (`$selectedOperation.Id -eq 'PaymentService') { `$screen = 'Package' }") | Should Be $true
        $launcherText.Contains("elseif (`$selectedOperation.Id -eq 'KioskInstallation') { `$screen = 'Operation' }") | Should Be $true
        $launcherText.Contains("else { `$screen = 'Mode' }") | Should Be $true
    }

    It 'uses zero as the Exit key in every menu layer' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $menuText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Core\Menu.psm1'))
        $saasThoroughText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot '..\SaaSKioskThoroughCheckScript.ps1'))
        $subwayThoroughText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot '..\SubwayKioskThoroughCheck.ps1'))

        $menuText.Contains("[string]`$ExitKey = '0'") | Should Be $true
        $launcherText.Contains("Write-Host '  [0] Exit' -ForegroundColor DarkGray") | Should Be $true
        $launcherText.Contains("Read-Host '  Select option'") | Should Be $true
        $launcherText | Should Not Match 'Select option \[[0-9, -]+\]'
        $saasThoroughText.Contains('[0] Exit') | Should Be $true
        $subwayThoroughText.Contains('[0] Exit') | Should Be $true
        ($launcherText + $menuText + $saasThoroughText + $subwayThoroughText) | Should Not Match '\[(4|9)\] Exit'
    }
}

Describe 'KIOSK Thorough Check handler boundary' {
    BeforeEach {
        $script:FixtureWorkspace = Join-Path $TestDrive 'workspace'
        $script:FixtureArchitecture = Join-Path $script:FixtureWorkspace 'DeviceManagement'
        $script:FixtureReports = Join-Path $TestDrive 'reports'
        New-Item -ItemType Directory -Path $script:FixtureArchitecture, $script:FixtureReports -Force | Out-Null
        $script:FixtureLegacy = Join-Path $script:FixtureWorkspace 'SaaSKioskThoroughCheckScript.ps1'
        $script:Handler = Join-Path $script:ArchitectureRoot 'Checks\KIOSK\ThoroughCheck.ps1'
    }
    It 'returns Pass and the generated report from a successful child run' {
        $report = Join-Path $script:FixtureReports 'fixture-success.html'
        $escapedReport = $report.Replace("'", "''")
        [IO.File]::WriteAllText($script:FixtureLegacy, "param([switch]`$ArchitectureRun,[switch]`$AuditOnly,[switch]`$Apply,[string]`$DeviceType,[string]`$ClientLocation,[string]`$ArchitectureResultPath)`r`n[IO.File]::WriteAllText('$escapedReport','ok')`r`n[IO.File]::WriteAllText(`$ArchitectureResultPath,'Completed')`r`nexit 0")
        $context = [pscustomobject]@{ RootPath=$script:FixtureArchitecture; ReportFolder=$script:FixtureReports; DeviceType='KIOSK'; Operation='ThoroughCheck'; Mode='Audit'; ClientLocation='Fixture' }
        $result = & $script:Handler -Context $context
        $result.Status | Should Be 'Pass'
        $result.Message | Should Match 'fixture-success.html'
    }
    It 'returns Fail with the report when the child reports failed checks' {
        $report = Join-Path $script:FixtureReports 'fixture-failed.html'
        $escapedReport = $report.Replace("'", "''")
        [IO.File]::WriteAllText($script:FixtureLegacy, "param([switch]`$ArchitectureRun,[switch]`$AuditOnly,[switch]`$Apply,[string]`$DeviceType,[string]`$ClientLocation,[string]`$ArchitectureResultPath)`r`n[IO.File]::WriteAllText('$escapedReport','failed')`r`n[IO.File]::WriteAllText(`$ArchitectureResultPath,'Completed')`r`nexit 1")
        $context = [pscustomobject]@{ RootPath=$script:FixtureArchitecture; ReportFolder=$script:FixtureReports; DeviceType='KIOSK'; Operation='ThoroughCheck'; Mode='Apply'; ClientLocation='Fixture' }
        $result = & $script:Handler -Context $context
        $result.Status | Should Be 'Fail'
        $result.Message | Should Match 'fixture-failed.html'
    }
    It 'reports a standard failure when the child exits before completing the audit' {
        [IO.File]::WriteAllText($script:FixtureLegacy, "param([switch]`$ArchitectureRun,[switch]`$AuditOnly,[switch]`$Apply,[string]`$DeviceType,[string]`$ClientLocation,[string]`$ArchitectureResultPath)`r`nexit 1")
        $context = [pscustomobject]@{ RootPath=$script:FixtureArchitecture; ReportFolder=$script:FixtureReports; DeviceType='KIOSK'; Operation='ThoroughCheck'; Mode='Audit'; ClientLocation=$null }
        $result = & $script:Handler -Context $context
        $result.Status | Should Be 'Fail'
        $result.Message | Should Be 'KIOSK Thorough Check could not start or complete. Review the PowerShell error and retry.'
    }
    It 'omits ClientLocation from the Audit child-process arguments' {
        $handlerText = [IO.File]::ReadAllText($script:Handler)
        $handlerText | Should Match 'if \(\$Context.Mode -eq ''Apply''\)[\s\S]*arguments \+= @\(''-ClientLocation'''
        $handlerText | Should Not Match "'-DeviceType', 'KIOSK',\s*'-ClientLocation'"
    }
    It 'streams child output to the terminal before capturing the native exit code' {
        foreach ($handlerName in @('ThoroughCheck.ps1', 'SaaS-ThoroughCheck.ps1', 'Subway-ThoroughCheck.ps1')) {
            $handlerText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot "Checks\KIOSK\$handlerName"))
            $handlerText | Should Match '& \$powershell @arguments 2>&1 \| Out-Host\s+\$operationExitCode = \$LASTEXITCODE'
        }
    }
}

Describe 'KIOSK Thorough Check audit console flow' {
    It 'bypasses Client and Branch input during Audit but keeps it for Apply' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $launcherText | Should Match 'selectedMode -eq ''Apply''.*selectedOperation\.Id -ne ''PaymentService'''
        foreach ($name in @('SaaSKioskThoroughCheckScript.ps1', 'SubwayKioskThoroughCheck.ps1')) {
            $source = [IO.File]::ReadAllText((Join-Path (Split-Path $script:ArchitectureRoot -Parent) $name))
            $source | Should Match 'if \(\$script:ApplyChanges\)[\s\S]*Read-Host ''Client & Branch''[\s\S]*\$ClientLocation = ''Not provided'''
        }
    }

    It 'preserves completed Thorough Check logs in Audit and Apply' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $launcherText | Should Match 'preserveOperationOutput = .*selectedOperation\.Id -eq ''ThoroughCheck'''
        $launcherText | Should Match 'if \(-not \$preserveOperationOutput\)'
    }

    It 'prints only the save location for Y and no report message for N' {
        foreach ($name in @('SaaSKioskThoroughCheckScript.ps1', 'SubwayKioskThoroughCheck.ps1')) {
            $source = [IO.File]::ReadAllText((Join-Path (Split-Path $script:ArchitectureRoot -Parent) $name))
            $source | Should Match 'Audit report saved to:'
            $source | Should Not Match 'HTML report was not generated\.'
            $source | Should Not Match 'Review the terminal results\.'
        }
    }
}

Describe 'Payment Service audit console and report flow' {
    It 'shows Send Ping and uses the same optional HTML report interaction' {
        $handlerText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Payments\SaaS\KIOSK\PaymentService.ps1'))
        $handlerText | Should Match 'Payment Service Audit Results'
        $handlerText | Should Match 'Generate HTML report\? \[Y/N\]'
        $handlerText | Should Match 'Payment_Service_Audit_Report_'
        $handlerText | Should Match 'Audit report saved to:'
        $handlerText | Should Not Match 'HTML report was not generated\.'
    }

    It 'preserves Payment Service Audit results when returning to the menu' {
        $launcherText = [IO.File]::ReadAllText((Join-Path $script:ArchitectureRoot 'Start-DeviceManagement.ps1'))
        $launcherText | Should Match 'selectedMode -eq ''Audit'' -and \$selectedOperation\.Id -eq ''PaymentService'''
    }
}
