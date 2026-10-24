@{
    SchemaVersion = '1.0'
    Modes = @(
        @{ Id = 'Audit'; DisplayName = 'Audit Report'; Description = 'Review the current state without changing system configuration.' }
        @{ Id = 'Apply'; DisplayName = 'Apply Fix'; Description = 'Apply the selected operation and verify the resulting state.' }
        @{ Id = 'Final'; DisplayName = 'Thorough Check Report'; Description = '' }
        @{ Id = 'Uninstall'; DisplayName = 'Remove Payment Service'; Description = '' }
    )
    Operations = @(
        @{
            Id                  = 'ThoroughCheck'
            DisplayName         = 'Thorough Check'
            Devices             = @('KIOSK', 'POS', 'KDS')
            ReadyDevices        = @()
            ReadySelections     = @()
            HandlerTemplate     = 'Checks\{Device}\ThoroughCheck.ps1'
            ImplementationState = 'Pending'
        }
        @{
            Id                  = 'PaymentService'
            DisplayName         = 'Payment Service'
            Devices             = @('KIOSK', 'POS', 'KDS')
            ReadyDevices        = @()
            ReadySelections     = @()
            HandlerTemplate     = 'Payments\{Client}\{Device}\PaymentService.ps1'
            ImplementationState = 'Pending'
        }
        @{
            Id                  = 'KioskInstallation'
            DisplayName         = 'KIOSK Installation'
            Devices             = @('KIOSK')
            ReadyDevices        = @()
            ReadySelections     = @('SaaS|KIOSK|Apply')
            HandlerTemplate     = 'Installations\KIOSK\{Client}-Install.ps1'
            ImplementationState = 'Ready'
        }
        @{
            Id                  = 'PosInstallation'
            DisplayName         = 'POS Installation'
            Devices             = @('POS')
            ReadyDevices        = @()
            HandlerTemplate     = 'Installations\POS\Install.ps1'
            ImplementationState = 'Pending'
        }
        @{
            Id                  = 'KdsInstallation'
            DisplayName         = 'KDS Installation'
            Devices             = @('KDS')
            ReadyDevices        = @()
            HandlerTemplate     = 'Installations\KDS\Install.ps1'
            ImplementationState = 'Pending'
        }
    )
}
