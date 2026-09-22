@{
    # Manifeste du module SynchronisationEntra
    RootModule           = 'SynchronisationEntra.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'f7a89034-65bc-4d01-b3c2-30671423b8e5'
    Author               = 'Ardian Cloud IAM & DevOps'
    CompanyName          = 'Ardian'
    Copyright            = '(c) Ardian. Tous droits réservés.'
    Description          = 'Module de réconciliation déclarative, calcul de Diff et déploiement idempotent vers Entra ID'
    PowerShellVersion    = '5.1'
    RequiredModules      = @(
        @{ ModuleName = 'ConnexionGraph'; ModuleVersion = '1.0.0' },
        @{ ModuleName = 'ValidationSyntaxe'; ModuleVersion = '1.0.0' },
        @{ ModuleName = 'GestionCatalogues'; ModuleVersion = '1.0.0' },
        @{ ModuleName = 'GestionAccessPackages'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport    = @(
        'Comparer-EtatEntra',
        'Synchroniser-EtatEntra'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
