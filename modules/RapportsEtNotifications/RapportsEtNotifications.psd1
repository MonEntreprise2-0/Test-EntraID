@{
    # Manifeste du module RapportsEtNotifications
    RootModule           = 'RapportsEtNotifications.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a8b90123-76cd-4e12-84d3-41782534c9f6'
    Author               = 'Ardian Cloud IAM & DevOps'
    CompanyName          = 'Ardian'
    Copyright            = '(c) Ardian. Tous droits réservés.'
    Description          = 'Module de génération et formatage des rapports Markdown pour les commentaires de Pull Request et Step Summaries'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @(
        'Formater-RapportPlanCI',
        'Formater-RapportDeploiementCD'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
