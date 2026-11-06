@{
    SchemaVersion = '1.0'
    Clients = @{
        SaaS = @{
            ClientType = 'SaaS'
            Origin = 'https://kiosk.ordermonkey.com'
            OnboardingPath = '/#/onboarding/login'
            PreferredServiceNames = @()
            PreferredServiceNamePattern = 'SaaSProd'
            PaymentServiceRequirement = 'AspPaymentSaaSProd'
            LauncherUrlPattern = 'https://[A-Za-z0-9.-]+/[^\s"'']*'
        }
        Subway = @{
            ClientType = 'Subway'
            Origin = 'https://kiosk.subway.ch'
            OnboardingPath = '/#/onboarding/login'
            PreferredServiceNames = @('SubwayLocal', 'AspPaymentSubwayProd')
            PreferredServiceNamePattern = ''
            PaymentServiceRequirement = 'SubwayLocal or AspPaymentSubwayProd'
            LauncherUrlPattern = 'https://[A-Za-z0-9.-]+/[^\s"'']*'
        }
    }
}
