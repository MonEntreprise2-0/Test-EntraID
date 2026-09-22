@{
    # Manifeste du module ConnexionGraph
    RootModule           = 'ConnexionGraph.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'b78a9c21-7294-4d8b-87cf-432d8471e9a1'
    Author               = 'Ardian Cloud IAM & DevOps'
    CompanyName          = 'Ardian'
    Copyright            = '(c) Ardian. Tous droits réservés.'
    Description          = 'Module d authentification et d interactions HTTP avec Microsoft Graph API pour Entra ID'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @(
        'Connect-GraphSession',
        'Get-GraphSessionToken',
        'Invoke-GraphRequest',
        'Resolve-GraphUser',
        'Resolve-GraphGroup',
        'Resolve-GraphServicePrincipal'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
