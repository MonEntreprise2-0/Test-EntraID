@{
    # Manifeste du module GestionCatalogues
    RootModule           = 'GestionCatalogues.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'd5e67812-43fa-4b89-91a0-18459201f6c3'
    CompanyName          = 'Ardian'
    Description          = 'Module de gestion du cycle de vie des catalogues, ressources et propriétaires dans Microsoft Entra ID'
    PowerShellVersion    = '5.1'
    RequiredModules      = @(
        @{ ModuleName = 'ConnexionGraph'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport    = @(
        'Get-CatalogueEntra',
        'New-CatalogueEntra',
        'Set-CatalogueEntra',
        'Remove-CatalogueEntra',
        'Get-RessourcesCatalogue',
        'Add-RessourceCatalogue',
        'Remove-RessourceCatalogue'
    )
}
