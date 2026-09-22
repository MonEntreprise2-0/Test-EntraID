# ============================================================================
# MODULE : ImportationEntra
# ============================================================================
# Rôle :
#   Rétro-ingénierie (Reverse Engineering) de catalogues existants dans Entra ID
#   vers des fichiers de déclaration YAML au format Ardian v2 (Scénario D).
#   Applique le contrôle strict de la nomenclature :
#     [Contexte/Sous-Application] [Privilège] - [Environnement]
#
# Auteur : Ardian Cloud IAM & DevOps
# ============================================================================

<#
.SYNOPSIS
    Valide et décompose le nom d'un Access Package selon la règle de nomenclature obligatoire.
.DESCRIPTION
    Convention attendue :
    - Avec contexte : "[Context] [Privilege] - [Env]" (ex: "Credit Read Only - UAT")
    - Sans contexte : "[Privilege] - [Env]" (ex: "Admin - Prod")
.OUTPUTS
    PSCustomObject contenant IsValid, ContextSubapp, PrivilegeLevel, Env, ErrorMessage.
#>
function Tester-NomenclatureAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $clean = $DisplayName.Trim()
    
    # Doit contenir au moins un tiret séparateur
    if (-not $clean.Contains("-")) {
        return [PSCustomObject]@{
            IsValid      = $false
            DisplayName  = $clean
            ErrorMessage = "Le nom '$clean' ne contient aucun tiret '-' séparateur d'environnement."
        }
    }

    # Regex de décomposition : ^(?:(?<context>[A-Za-z0-9_]+)\s+)?(?<privilege>[A-Za-z0-9_\s]+?)\s*-\s*(?<env>[A-Za-z0-9_]+)$
    $pattern = '^(?:(?<context>[A-Za-z0-9_]+)\s+)?(?<privilege>[A-Za-z0-9_\s]+?)\s*-\s*(?<env>[A-Za-z0-9_]+)$'
    if ($clean -match $pattern) {
        $context = $Matches['context']
        $privilege = $Matches['privilege'].Trim()
        $env = $Matches['env'].Trim()

        # Si le privilège est vide après découpage
        if ([string]::IsNullOrWhiteSpace($privilege)) {
            return [PSCustomObject]@{
                IsValid      = $false
                DisplayName  = $clean
                ErrorMessage = "Le niveau de privilège n'a pas pu être extrait pour '$clean'."
            }
        }

        return [PSCustomObject]@{
            IsValid       = $true
            DisplayName   = $clean
            ContextSubapp = if ($context) { $context.Trim() } else { "" }
            Privilege     = $privilege
            Env           = $env
            ErrorMessage  = ""
        }
    }

    return [PSCustomObject]@{
        IsValid      = $false
        DisplayName  = $clean
        ErrorMessage = "Le nom '$clean' ne respecte pas le format '[Contexte] [Privilège] - [Environnement]' ou '[Privilège] - [Environnement]'."
    }
}

<#
.SYNOPSIS
    Aspire un catalogue existant depuis Entra ID et génère la déclaration YAML correspondante.
.PARAMETER TargetCatalogOrAppName
    Nom du catalogue ou de l'application à importer.
.PARAMETER DeclarationDir
    Répertoire racine des déclarations (défaut : 'declaration').
.PARAMETER FallbackApproverEmail
    Email de l'approbateur par défaut si aucun approbateur direct n'est configuré dans la politique.
#>
function Exporter-CatalogueVersYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetCatalogOrAppName,

        [Parameter(Mandatory = $false)]
        [string]$DeclarationDir = "declaration",

        [Parameter(Mandatory = $false)]
        [string]$FallbackApproverEmail = "OrlaineLEKANEGUETSA@monentreprise123.onmicrosoft.com"
    )

    $inputAppName = $TargetCatalogOrAppName.Trim()

    # 1. Vérification de l'existence préalable dans Git (règle d'écrasement / overwrite)
    $existingDir = $null
    if (Test-Path $DeclarationDir) {
        $existingDir = Get-ChildItem -Path $DeclarationDir -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name.Equals($inputAppName, [StringComparison]::OrdinalIgnoreCase)
        }
    }

    $appName = ""
    $wasOverwritten = $false
    $existingDescription = ""

    if ($existingDir) {
        # L'application existe déjà : on conserve son nom de dossier exact
        $appName = $existingDir.Name
        $existingYamlFile = Join-Path $existingDir.FullName "$appName.yaml"
        if (-not (Test-Path $existingYamlFile)) {
            $f = Get-ChildItem -Path $existingDir.FullName -Filter "*.yaml" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { $existingYamlFile = $f.FullName }
        }
        if ($existingYamlFile -and (Test-Path $existingYamlFile)) {
            $wasOverwritten = $true
            Write-Host "⚠️ L'application '$appName' existe déjà dans Git ($existingYamlFile)." -ForegroundColor Yellow
            Write-Host "   -> Le fichier sera écrasé et redéfini avec l'état réel d'Entra ID." -ForegroundColor Yellow
            try {
                $oldContent = Get-Content $existingYamlFile -Raw -Encoding UTF8
                if ($oldContent -match '(?m)^\s*app_description\s*:\s*["'']?(.*?)["'']?\s*$') {
                    $existingDescription = $Matches[1].Trim()
                }
            } catch {}
        }
    } else {
        # Nouvelle application : formatage propre en kebab-case / snake_case selon la saisie
        $appName = ($inputAppName -replace '[^a-zA-Z0-9_-]', '-').ToLowerInvariant().Trim('-').Trim('_')
        while ($appName.Contains("--")) { $appName = $appName.Replace("--", "-") }
        if ([string]::IsNullOrWhiteSpace($appName)) {
            $appName = "app-" + [Guid]::NewGuid().ToString().Substring(0, 8)
        }
    }

    Write-Host "🔍 Recherche du catalogue correspondant à l'application '$appName' dans Entra ID..." -ForegroundColor Cyan

    $allCatalogs = Get-CatalogueEntra
    if (-not $allCatalogs -or $allCatalogs.Count -eq 0) {
        throw "Aucun catalogue trouvé dans Microsoft Entra ID."
    }

    # Recherche multi-niveaux :
    # 1. Correspondance exacte ou insensible à la casse sur displayName
    # 2. Correspondance normalisée (sans séparateurs)
    $matchedCatalog = $null
    $targetNorm = ($appName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $inputNorm = ($inputAppName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()

    foreach ($cat in $allCatalogs) {
        if ($cat.displayName) {
            if ($cat.displayName.Equals($inputAppName, [StringComparison]::OrdinalIgnoreCase) -or
                $cat.displayName.Equals($appName, [StringComparison]::OrdinalIgnoreCase)) {
                $matchedCatalog = $cat
                break
            }
            $catNorm = ($cat.displayName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
            if ($catNorm -eq $targetNorm -or $catNorm -eq $inputNorm) {
                $matchedCatalog = $cat
            }
        }
    }

    if (-not $matchedCatalog) {
        $availableNames = ($allCatalogs | ForEach-Object { "- $($_.displayName)" }) -join "`n"
        throw "Le catalogue pour l'application '$appName' (recherche: '$inputAppName') est introuvable dans Entra ID.`n`nCatalogues disponibles :`n$availableNames"
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
        $nomCheck = Tester-NomenclatureAccessPackage -DisplayName $ap.displayName
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
        throw "Erreur de nomenclature obligatoire dans le catalogue '$catalogName' :`n- $errSummary`n`n👉 Pour corriger : Ajustez le nom des Access Packages directement dans le portail Entra ID pour respecter le format '[Contexte] [Privilège] - [Environnement]'."
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
        $policy = Get-PolitiqueAssignationEntra -AccessPackageId $apId

        if ($policy -and $policy.requestApprovalSettings -and $policy.requestApprovalSettings.stages) {
            foreach ($stage in $policy.requestApprovalSettings.stages) {
                if ($stage.primaryApprovers) {
                    foreach ($appr in $stage.primaryApprovers) {
                        $uid = $appr.userId
                        if ($uid) {
                            $userObj = Invoke-GraphRequest -Endpoint "/users/$uid" -Method GET -IgnoreNotFound
                            if ($userObj) {
                                $mail = if ($userObj.mail) { $userObj.mail } else { $userObj.userPrincipalName }
                                if ($mail) { $approverEmails.Add($mail.Trim()) }
                            }
                        }
                    }
                }
            }
        }

        # Fallback si aucun approbateur configuré
        if ($approverEmails.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($FallbackApproverEmail)) {
            Write-Verbose "Aucun approbateur dans la politique de '$($ap.displayName)'. Utilisation de l'approbateur de secours : $FallbackApproverEmail"
            $approverEmails.Add($FallbackApproverEmail.Trim())
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
                        app_role       = $roleName
                    })
                }
            }
        }

        # Si aucune ressource, ajout d'une ressource par défaut pour respecter le schéma
        if ($resourcesList.Count -eq 0) {
            $resourcesList.Add([ordered]@{
                resource_type = "EntraID Group"
                group_name    = "Group_Default"
            })
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

    # 3. Génération du fichier YAML (strictement app_name, AUCUN catalogue_name / catalog_name)
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
                $yamlLines.Add("    authorization_owners:")
                foreach ($email in $v) {
                    $yamlLines.Add("      - `"$email`"")
                }
            } elseif ($k -eq "resources") {
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
                $prefix = if ($first) { "  - " } else { "    " }
                $yamlLines.Add("$prefix$($k): `"$v`"")
                $first = $false
            }
        }
        $yamlLines.Add("")
    }

    $targetDir = Join-Path $DeclarationDir $appName
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $targetFile = Join-Path $targetDir "$appName.yaml"
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
