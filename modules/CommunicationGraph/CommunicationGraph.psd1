@{
    # Manifeste du module CommunicationGraph
    RootModule           = 'CommunicationGraph.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'b78a9c21-7294-4d8b-87cf-432d8471e9a1'
    CompanyName          = 'Ardian'
    Description          = 'Module d authentification et d interactions HTTP avec Microsoft Graph API pour Entra ID'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @(
        'Connect-GraphSession',
        'Get-GraphSessionToken',
        'Invoke-GraphRequest',
        'Resolve-GraphUser',
        'Resolve-GraphGroup',
        'Resolve-GraphServicePrincipal',
        'Resolve-SharepointSite'
    )
}
