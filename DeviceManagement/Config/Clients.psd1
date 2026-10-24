@{
    SchemaVersion = '1.0'
    Clients = @(
        @{
            Id          = 'Subway'
            DisplayName = 'Subway'
            Devices     = @('KIOSK', 'POS', 'KDS')
        }
        @{
            Id          = 'SaaS'
            DisplayName = 'SaaS'
            Devices     = @('KIOSK', 'POS', 'KDS')
        }
        @{
            Id          = 'ViCafe'
            DisplayName = 'ViCafe'
            Devices     = @('POS')
        }
    )
}
