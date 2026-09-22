@{
    # Manifeste du module GestionAccessPackages
    RootModule           = 'GestionAccessPackages.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'e6f78923-54ab-4c90-a2b1-29560312a7d4'
    Author               = 'Ardian Cloud IAM & DevOps'
    CompanyName          = 'Ardian'
    Copyright            = '(c) Ardian. Tous droits réservés.'
    Description          = 'Module de gestion des Access Packages, rôles de ressources et politiques d assignation dans Microsoft Entra ID'
    PowerShellVersion    = '5.1'
    RequiredModules      = @(
        @{ ModuleName = 'ConnexionGraph'; ModuleVersion = '1.0.0' },
        @{ ModuleName = 'GestionCatalogues'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport    = @(
        'Get-AccessPackageEntra',
        'New-AccessPackageEntra',
        'Set-AccessPackageEntra',
        'Remove-AccessPackageEntra',
        'Get-RolesRessourcesAccessPackage',
        'Add-RoleRessourceAccessPackage',
        'Remove-RoleRessourceAccessPackage',
        'Get-PolitiqueAssignationEntra',
        'New-PolitiqueAssignationEntra',
        'Set-PolitiqueAssignationEntra',
        'Remove-PolitiqueAssignationEntra'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
