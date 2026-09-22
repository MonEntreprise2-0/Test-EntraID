@{
    # Manifeste du module ImportationEntra
    RootModule           = 'ImportationEntra.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'b9c01234-87de-4f23-95e4-52893645d0a7'
    Author               = 'Ardian Cloud IAM & DevOps'
    CompanyName          = 'Ardian'
    Copyright            = '(c) Ardian. Tous droits réservés.'
    Description          = 'Module de rétro-ingénierie (Reverse Engineering) de catalogues Entra ID vers des fichiers déclaratifs YAML'
    PowerShellVersion    = '5.1'
    RequiredModules      = @(
        @{ ModuleName = 'ConnexionGraph'; ModuleVersion = '1.0.0' },
        @{ ModuleName = 'GestionCatalogues'; ModuleVersion = '1.0.0' },
        @{ ModuleName = 'GestionAccessPackages'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport    = @(
        'Exporter-CatalogueVersYaml',
        'Tester-NomenclatureAccessPackage'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
