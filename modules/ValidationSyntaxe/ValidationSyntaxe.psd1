@{
    # Manifeste du module ValidationSyntaxe
    RootModule           = 'ValidationSyntaxe.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'c45b7891-62d4-4e12-9c3f-762d9812e4b2'
    Author               = 'Ardian Cloud IAM & DevOps'
    CompanyName          = 'Ardian'
    Copyright            = '(c) Ardian. Tous droits réservés.'
    Description          = 'Module de validation syntaxique, schéma YAML et conformité SSoT contre Microsoft Entra ID'
    PowerShellVersion    = '5.1'
    RequiredModules      = @(
        @{ ModuleName = 'ConnexionGraph'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport    = @(
        'Lire-DeclarationYaml',
        'Valider-StructureYaml',
        'Valider-RessourcesEntraId',
        'Calculer-NomAccessPackage'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
