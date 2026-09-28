# ============================================================================
# MODULE : ImportationEntra
# ============================================================================
# Rôle :
#   Rétro-ingénierie (Reverse Engineering) de catalogues existants dans Entra ID vers des fichiers de déclaration YAML.
#
#    
# ============================================================================

<#
.SYNOPSIS
    Lorsqu'on importe un catalogue existant depuis Entra ID pour générer son YAML, cette fonction accomplit deux missions :

    1. Vérifier que l'Access Package respecte strictement la nomenclature obligatoire de l'entreprise : [app_name] - [Contexte] [Privilège] - [Environnement]
    2. Décomposer le nom pour en extraire automatiquement les 3 clés nécessaires au fichier YAML : context_subapp, privilege_level, env 
.DESCRIPTION
    Convention attendue :
    - Avec contexte : "{app_name} - [Context] [Privilege] - [Env]" (ex: "monApp - SubApp Admin - PRD")
    - Sans contexte : "{app_name} - [Privilege] - [Env]" (ex: "monApp - Admin - PRD")
    Contrainte stricte : Env doit avoir les valeurs suivantes DEV, UAT, PRD, TST, GLB.
.OUTPUTS
    PSCustomObject contenant IsValid, AppName, ContextSubapp, Privilege, Env, ErrorMessage.
#>
function Tester-NomenclatureAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,  # Nom de l'accessPackage dans EntraID

        [Parameter(Mandatory = $false)]
        [string]$AppName = ""  # Nom du catalogue
    )

    $clean = $DisplayName.Trim()
    $allowedEnvs = @('DEV', 'UAT', 'PRD', 'TST', 'GLB')

    # 1. Vérification du préfixe de l'application si fourni (Si l'app_name est fourni, alors le nom de l'AccessPackage doit obligatoirement commencer par cet app_name)
    $workingName = $clean
    if (-not [string]::IsNullOrWhiteSpace($AppName)) {
        $appPrefix = "$AppName - "
        if (-not $clean.StartsWith($appPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                IsValid      = $false
                DisplayName  = $clean
                ErrorMessage = "Le nom '$clean' ne commence pas par le préfixe de l'application attendu '$appPrefix'."
            }
        }
        $workingName = $clean.Substring($appPrefix.Length).Trim()
    }

    # 2. Doit contenir au moins un tiret séparateur pour l'environnement
    if (-not $workingName.Contains("-")) {
        return [PSCustomObject]@{
            IsValid      = $false
            DisplayName  = $clean
            ErrorMessage = "Le nom '$clean' ne contient aucun séparateur d'environnement ' - '."
        }
    }

    $prefix = ""
    $env = ""

    # Cas standard : Dernier séparateur " - "
    $dashIndex = $workingName.LastIndexOf(' - ')
    if ($dashIndex -gt 0) {
        $prefix = $workingName.Substring(0, $dashIndex).Trim()
        $env = $workingName.Substring($dashIndex + 3).Trim()
    } elseif ($workingName -match '^(?<prefix>.+?)\s*-\s*(?<env>[A-Za-z0-9_-]+)$') {
        $prefix = $Matches['prefix'].Trim()
        $env = $Matches['env'].Trim()
    } else {
        return [PSCustomObject]@{
            IsValid      = $false
            DisplayName  = $clean
            ErrorMessage = "Le nom '$clean' ne respecte pas le format '{app_name} - [Contexte] [Privilège] - [Environnement]' ou '{app_name} - [Privilège] - [Environnement]'."
        }
    }

    if ([string]::IsNullOrWhiteSpace($prefix) -or [string]::IsNullOrWhiteSpace($env)) {
        return [PSCustomObject]@{
            IsValid      = $false
            DisplayName  = $clean
            ErrorMessage = "Le préfixe (contexte/privilège) ou l'environnement est vide pour '$clean'."
        }
    }

    # 3. Contrôle strict de la valeur de l'environnement (insensible à la casse)
    if (-not ($allowedEnvs -contains $env.ToUpperInvariant())) {
        return [PSCustomObject]@{
            IsValid      = $false
            DisplayName  = $clean
            ErrorMessage = "L'environnement '$env' n'est pas autorisé pour '$clean'. Valeurs strictement autorisées : $($allowedEnvs -join ', ')."
        }
    }

    # 4. Décomposition du préfixe en [Contexte] et [Privilège]
    $context = ""
    $privilege = ""

    # Cas où le préfixe entier est un privilège direct sans contexte (ex: "Read Only", "Full Access")
    if ($prefix -match '^(?i)(?:Read[\s-_]?Only|Full[\s-_]?(?:Control|Access)|Direct[\s-_]?Access)$') {
        $context = ""
        $privilege = $prefix
    } elseif ($prefix.Contains(' ')) {
        # Premier mot = contexte (supportant tirets/underscores), reste = privilège
        $firstSpaceIndex = $prefix.IndexOf(' ')
        $context = $prefix.Substring(0, $firstSpaceIndex).Trim()
        $privilege = $prefix.Substring($firstSpaceIndex + 1).Trim()
    } else {
        $context = ""
        $privilege = $prefix
    }

    return [PSCustomObject]@{
        IsValid       = $true
        DisplayName   = $clean
        AppName       = $AppName
        ContextSubapp = $context
        Privilege     = $privilege
        Env           = $env.ToUpperInvariant()
        ErrorMessage  = ""
    }
}

<#
.SYNOPSIS
    Récupère un catalogue existant depuis Entra ID et génère la déclaration YAML correspondante.
.PARAMETER TargetCatalogOrAppName
    Nom du catalogue à importer.
.PARAMETER DeclarationDir
    Répertoire racine des déclarations sur Github (défaut : 'declaration').
#>
function Exporter-CatalogueVersYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetCatalogName,

        [Parameter(Mandatory = $false)]
        [string]$DeclarationDir = "declaration"
    )

    $rawInput = $TargetCatalogName.Trim()

    # 1. Règle stricte de nomenclature : la saisie doit impérativement commencer par CAT-
    if (-not $rawInput.StartsWith("CAT-", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Le catalogue '$rawInput' ne respecte pas la nomenclature obligatoire 'CAT-{app_name}'. Vous devez impérativement saisir le nom complet du catalogue commençant par 'CAT-'."
    }

    $appName = $rawInput.Substring(4).Trim()
    if ([string]::IsNullOrWhiteSpace($appName)) {
        throw "Le nom de l'application dérivé de '$rawInput' est vide."
    }

    # On enlève les accents pour créer les noms de répertoires/fichiers car avec les accents ça génère des erreurs
    $appNameNoAccents = $appName -replace '[\u00E8-\u00EB\u00C8-\u00CBéèêëÉÈÊË]','e' `
                                 -replace '[\u00E0-\u00E5\u00C0-\u00C5àâäÀÂÄ]','a' `
                                 -replace '[\u00EC-\u00EF\u00CC-\u00CFîïÎÏ]','i' `
                                 -replace '[\u00F2-\u00F6\u00D2-\u00D6ôöÔÖ]','o' `
                                 -replace '[\u00F9-\u00FC\u00D9-\u00DCùûüÙÛÜ]','u' `
                                 -replace '[\u00E7\u00C7çÇ]','c'

    $targetCatalogName = "CAT-$appNameNoAccents"
    $targetDir = Join-Path $DeclarationDir $targetCatalogName
    $targetFile = Join-Path $targetDir "$targetCatalogName.yaml"


    #Détection de l'existence préalable dans Git. S'il existe, il note $wasOverwritten = $true
    $wasOverwritten = $false
    $existingDescription = ""

    if (Test-Path $targetFile) {
        $wasOverwritten = $true
        Write-Host "⚠️ L'application '$appName' existe déjà dans Git ($targetFile)." -ForegroundColor Yellow
        Write-Host "   -> Le fichier sera écrasé et redéfini avec l'état réel d'Entra ID." -ForegroundColor Yellow
        #Extrait l'ancienne app_description au cas où le catalogue dans Entra ID n'aurait pas de description renseignée (afin de ne pas perdre la documentation existante)
        try {
            $oldContent = Get-Content $targetFile -Raw -Encoding UTF8
            if ($oldContent -match '(?m)^\s*app_description\s*:\s*["'']?(.*?)["'']?\s*$') {
                $existingDescription = $Matches[1].Trim()
            }
        } catch {}
    }

    Write-Host "🔍 Recherche du catalogue '$targetCatalogName' dans Entra ID..." -ForegroundColor Cyan

    $allCatalogs = Get-CatalogueEntra
    if (-not $allCatalogs -or $allCatalogs.Count -eq 0) {
        throw "Aucun catalogue trouvé dans Microsoft Entra ID."
    }

    $matchedCatalog = $null
    foreach ($cat in $allCatalogs) {
        if ($cat.displayName -and $cat.displayName.Equals($targetCatalogName, [StringComparison]::OrdinalIgnoreCase)) {
            $matchedCatalog = $cat
            break
        }
    }

    if (-not $matchedCatalog) {
        $availableNames = ($allCatalogs | ForEach-Object { "- $($_.displayName)" }) -join "`n"
        throw "Le catalogue '$targetCatalogName' est introuvable dans Entra ID.`n`nCatalogues disponibles :`n$availableNames"
    }

    $catalogId = $matchedCatalog.id
    $catalogName = $matchedCatalog.displayName

    Write-Host "✅ Catalogue Entra ID trouvé : '$catalogName' (ID : $catalogId) pour app_name '$appName'" -ForegroundColor Green

    # Récupération des Access Packages du catalogue
    $aps = Get-AccessPackageEntra -CatalogId $catalogId
    if (-not $aps -or $aps.Count -eq 0) {
        throw "Le catalogue '$catalogName' ne contient aucun Access Package."
    }

    Write-Host "📦 Nombre d'Access Packages trouvés : $($aps.Count)" -ForegroundColor Cyan

    # 1. Validation préalable de la nomenclature de TOUS les packages (règle bloquante)
    $parsedPackages = [System.Collections.Generic.List[PSObject]]::new()
    $nomenclatureErrors = [System.Collections.Generic.List[string]]::new()

    foreach ($ap in $aps) {
        $nomCheck = Tester-NomenclatureAccessPackage -DisplayName $ap.displayName -AppName $appName
        if (-not $nomCheck.IsValid) {
            $nomenclatureErrors.Add("Access Package '$($ap.displayName)' : $($nomCheck.ErrorMessage)")
        } else {
            $parsedPackages.Add([PSCustomObject]@{
                AccessPackage = $ap
                Nomenclature  = $nomCheck
            })
        }
    }

    if ($nomenclatureErrors.Count -gt 0) {
        $errSummary = ($nomenclatureErrors -join "`n- ")
        throw "Erreur de nomenclature obligatoire dans le catalogue '$catalogName' :`n- $errSummary`n`n👉 Pour corriger : Ajustez le nom des Access Packages directement dans le portail Entra ID pour respecter le format '$appName - [Contexte] [Privilège] - [Environnement]' (ou '$appName - [Privilège] - [Environnement]'), avec un environnement strictement parmi DEV, UAT, PRD, TST, GLB."
    }

    # 2. Extraction des ressources et approbateurs pour chaque paquet d'accès
    $yamlAccessPackages = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $parsedPackages) {
        $ap = $item.AccessPackage
        $nom = $item.Nomenclature
        $apId = $ap.id

        Write-Host "  ⚙️ Traitement de l'Access Package '$($ap.displayName)'..." -ForegroundColor Gray

        # Approbateurs depuis la politique
        $approverEmails = [System.Collections.Generic.List[string]]::new()
        $basePolicy = Get-PolitiqueAssignationEntra -AccessPackageId $apId

        if ($basePolicy -and -not [string]::IsNullOrWhiteSpace($basePolicy.id)) {
            $fullPolicy = Invoke-GraphRequest -Endpoint "/identityGovernance/entitlementManagement/assignmentPolicies/$($basePolicy.id)" -Method GET -IgnoreNotFound
            $polToInspect = if ($fullPolicy) { $fullPolicy } else { $basePolicy }
            $ras = $polToInspect.requestApprovalSettings

            if ($ras) {
                # Support de Graph v1.0 (approvalStages) et Graph beta / interne (stages)
                $stages = [System.Collections.Generic.List[object]]::new()
                if ($ras.approvalStages) {
                    foreach ($s in $ras.approvalStages) { $stages.Add($s) }
                }
                if ($ras.stages) {
                    foreach ($s in $ras.stages) { $stages.Add($s) }
                }

                foreach ($stage in $stages) {
                    # Récupération des approbateurs principaux et de secours
                    $approversToProcess = [System.Collections.Generic.List[object]]::new()
                    if ($stage.primaryApprovers) {
                        foreach ($a in $stage.primaryApprovers) { $approversToProcess.Add($a) }
                    }
                    if ($stage.fallbackPrimaryApprovers) {
                        foreach ($fa in $stage.fallbackPrimaryApprovers) { $approversToProcess.Add($fa) }
                    }

                    foreach ($appr in $approversToProcess) {
                        # 1. Email direct si déjà renseigné sur l'objet
                        $directEmail = if ($appr.mail) { $appr.mail } elseif ($appr.email) { $appr.email } elseif ($appr.userPrincipalName) { $appr.userPrincipalName } else { $null }
                        if ($directEmail -and -not $approverEmails.Contains($directEmail.Trim())) {
                            $approverEmails.Add($directEmail.Trim())
                            continue
                        }

                        # 2. Utilisateur unique (singleUser)
                        $uid = if ($appr.userId) { $appr.userId } elseif ($appr.id -and -not $appr.groupId) { $appr.id } else { $null }
                        if ($uid) {
                            $userObj = Invoke-GraphRequest -Endpoint "/users/$($uid)?`$select=id,displayName,mail,userPrincipalName,otherMails" -Method GET -IgnoreNotFound
                            if ($userObj) {
                                $mail = if (-not [string]::IsNullOrWhiteSpace($userObj.mail)) {
                                    $userObj.mail.Trim()
                                } elseif ($userObj.otherMails -and $userObj.otherMails.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($userObj.otherMails[0])) {
                                    $userObj.otherMails[0].Trim()
                                } elseif (-not [string]::IsNullOrWhiteSpace($userObj.userPrincipalName)) {
                                    $userObj.userPrincipalName.Trim()
                                } else { $null }

                                if ($mail -and -not $approverEmails.Contains($mail)) {
                                    $approverEmails.Add($mail)
                                }
                            }
                            continue
                        }

                        # 3. Membres d'un groupe (groupMembers)
                        $gid = if ($appr.groupId) { $appr.groupId } elseif ($appr.id -and -not $appr.userId) { $appr.id } else { $null }
                        if ($gid) {
                            $grpObj = Invoke-GraphRequest -Endpoint "/groups/$($gid)?`$select=id,displayName,mail" -Method GET -IgnoreNotFound
                            if ($grpObj -and -not [string]::IsNullOrWhiteSpace($grpObj.mail)) {
                                $grpMail = $grpObj.mail.Trim()
                                if (-not $approverEmails.Contains($grpMail)) {
                                    $approverEmails.Add($grpMail)
                                }
                            } else {
                                $members = Invoke-GraphRequest -Endpoint "/groups/$($gid)/transitiveMembers?`$select=id,displayName,mail,userPrincipalName&`$top=20" -Method GET -IgnoreNotFound
                                if ($members) {
                                    foreach ($m in $members) {
                                        $mMail = if (-not [string]::IsNullOrWhiteSpace($m.mail)) { $m.mail.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($m.userPrincipalName)) { $m.userPrincipalName.Trim() } else { $null }
                                        if ($mMail -and -not $approverEmails.Contains($mMail)) {
                                            $approverEmails.Add($mMail)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        # Ressources rattachées à cet Access Package
        $resourcesList = [System.Collections.Generic.List[object]]::new()
        $roleScopes = Get-RolesRessourcesAccessPackage -AccessPackageId $apId

        if ($roleScopes) {
            foreach ($rs in $roleScopes) {
                $roleObj = $rs.accessPackageResourceRole
                $scopeObj = $rs.accessPackageResourceScope
                $originSys = if ($roleObj) { $roleObj.originSystem } else { "AadGroup" }
                $roleName = if ($roleObj) { $roleObj.displayName } else { "Member" }

                # Si c'est un groupe Entra ID
                if ($originSys -eq "AadGroup") {
                    $grpId = if ($scopeObj) { $scopeObj.originId } else { $null }
                    $grpName = "Group_Unknown"
                    if ($grpId) {
                        $grpObj = Invoke-GraphRequest -Endpoint "/groups/$grpId" -Method GET -IgnoreNotFound
                        if ($grpObj -and $grpObj.displayName) {
                            $grpName = $grpObj.displayName
                        }
                    }
                    $resourcesList.Add([ordered]@{
                        resource_type = "EntraID Group"
                        group_name    = $grpName
                        role          = if ($roleName -eq "Owner") { "Owner" } else { "Member" }
                    })
                } elseif ($originSys -eq "AadApplication") {
                    $spId = if ($scopeObj) { $scopeObj.originId } else { $null }
                    $appNameVal = "App_Unknown"
                    if ($spId) {
                        $spObj = Invoke-GraphRequest -Endpoint "/servicePrincipals/$spId" -Method GET -IgnoreNotFound
                        if ($spObj -and $spObj.displayName) {
                            $appNameVal = $spObj.displayName
                        }
                    }
                    $resourcesList.Add([ordered]@{
                        resource_type  = "Application Role"
                        enterprise_app = $appNameVal
                    })
                } elseif ($originSys -eq "SharePointOnline") {
                    $siteUrl = if ($scopeObj) { $scopeObj.originId } else { "https://ardian.sharepoint.com/sites/Unknown" }
                    $grpNameVal = if ($roleObj -and $roleObj.displayName) { $roleObj.displayName } else { "SharePoint Group" }
                    $resourcesList.Add([ordered]@{
                        resource_type         = "Sharepoint Group"
                        sharepoint_url        = $siteUrl
                        sharepoint_group_name = $grpNameVal
                    })
                }
            }
        }

        $apDict = [ordered]@{
            privilege_level      = $nom.Privilege
            env                  = $nom.Env
            description          = $(if ($ap.description) { $ap.description.Trim() } else { "Access Package $($ap.displayName)" })
            authorization_owners = $approverEmails.ToArray()
            resources            = $resourcesList.ToArray()
        }
        if (-not [string]::IsNullOrWhiteSpace($nom.ContextSubapp)) {
            $apDict.Insert(0, "context_subapp", $nom.ContextSubapp)
        }

        $yamlAccessPackages.Add($apDict)
    }

    # 3. Génération du fichier YAML
    $catalogDesc = if ($matchedCatalog.description -and -not [string]::IsNullOrWhiteSpace($matchedCatalog.description)) {
        $matchedCatalog.description.Trim()
    } elseif ($existingDescription) {
        $existingDescription
    } else {
        "Description importée pour $appName"
    }

    $yamlLines = [System.Collections.Generic.List[string]]::new()
    $yamlLines.Add("app_name: `"$appName`"")
    $yamlLines.Add("app_description: `"$catalogDesc`"")
    $yamlLines.Add("")
    $yamlLines.Add("access_packages:")

    foreach ($yap in $yamlAccessPackages) {
        $first = $true
        foreach ($k in $yap.Keys) {
            $v = $yap[$k]
            if ($k -eq "authorization_owners") {
                if ($v -and $v.Count -gt 0) {
                    $yamlLines.Add("    authorization_owners:")
                    foreach ($email in $v) {
                        $yamlLines.Add("      - `"$email`"")
                    }
                } else {
                    $yamlLines.Add("    authorization_owners: []")
                }
            } elseif ($k -eq "resources") {
                if ($v -and $v.Count -gt 0) {
                    $yamlLines.Add("    resources:")
                    foreach ($r in $v) {
                        $resFirst = $true
                        foreach ($rk in $r.Keys) {
                            $rv = $r[$rk]
                            $prefix = if ($resFirst) { "      - " } else { "        " }
                            $yamlLines.Add("$prefix$($rk): `"$rv`"")
                            $resFirst = $false
                        }
                    }
                } else {
                    $yamlLines.Add("    resources: []")
                }
            } else {
                $prefix = if ($first) { "  - " } else { "    " }
                $yamlLines.Add("$prefix$($k): `"$v`"")
                $first = $false
            }
        }
        $yamlLines.Add("")
    }

    $targetDir = Join-Path $DeclarationDir $targetCatalogName
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $targetFile = Join-Path $targetDir "$targetCatalogName.yaml"
    $yamlContent = $yamlLines -join "`r`n"
    [System.IO.File]::WriteAllText($targetFile, $yamlContent, [System.Text.Encoding]::UTF8)

    $actionMsg = if ($wasOverwritten) { "écrasée et redéfinie" } else { "générée" }
    Write-Host "🎉 Déclaration YAML $actionMsg avec succès : $targetFile" -ForegroundColor Green

    return [PSCustomObject]@{
        Success           = $true
        AppName           = $appName
        CatalogName       = $catalogName
        TargetFile        = $targetFile
        PackagesImported  = $yamlAccessPackages.Count
        WasOverwritten    = $wasOverwritten
    }
}

Export-ModuleMember -Function Exporter-CatalogueVersYaml, Tester-NomenclatureAccessPackage
