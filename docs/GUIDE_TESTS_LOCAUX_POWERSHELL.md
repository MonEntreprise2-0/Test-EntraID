# 📘 Guide Pratique : Réalisation et Démonstration des Tests PowerShell Locaux

Ce document détaille la démarche pas à pas pour tester et faire la démonstration des scripts PowerShell d'orchestration et de validation de l'architecture déclarative **Entitlement Management**, directement sur un poste de travail professionnel Windows, **sans nécessiter de droits de création de branche sur GitHub ni de faire de `git push`**.

---

## 🎯 Objectif et Philosophie

1. **Autonomie locale complète :** Valider l'intégrité déclarative, la nomenclature et le calcul différentiel directement depuis votre invite PowerShell.
2. **Architecture 100% PowerShell :** Zéro dépendance tierce (aucun binaire Terraform ni runtime Python requis).
3. **SSoT (Single Source of Truth) Microsoft Entra ID :** Git déclare l'état cible ; Entra ID contrôle la validité des ressources réelles.
4. **Zéro impact / Mode non destructif :** Les scripts de test fonctionnent en lecture seule et ne modifient aucune ressource sur le tenant Azure.

---

## 📁 1. Organisation de l'Arborescence

Le projet est structuré selon une séparation stricte des responsabilités :

```text
ardian-entitlement-mgmt/
│
├── modules/          📂 Modules métier réutilisables (.psm1 / .psd1)
│   ├── ConnexionGraph/          -> Authentification Graph API & OIDC
│   ├── ValidationSyntaxe/       -> Parsing YAML, conformité schéma & nomenclature
│   ├── GestionCatalogues/       -> CRUD Catalogues & ressources
│   ├── GestionAccessPackages/   -> CRUD Access Packages & politiques
│   ├── SynchronisationEntra/    -> Moteur différentiel Git vs Entra ID (Diff)
│   ├── ImportationEntra/        -> Rétro-ingénierie / Export vers YAML
│   └── RapportsEtNotifications/ -> Générateurs de synthèses Markdown
│
├── scripts/          📂 Scripts d'orchestration exécutables (.ps1)
│   ├── Tester-Declarations.ps1     -> Lance la validation CI (Schéma, SSoT, Plan)
│   ├── Deployer-Declarations.ps1   -> Déploiement CD vers Entra ID
│   ├── Importer-DepuisEntra.ps1    -> Aspiration d'un catalogue Entra ID en YAML
│   ├── Traiter-DemandeIssue.ps1    -> Parsing automatique des formulaires d'Issues
│   └── Synchroniser-Formulaires.ps1-> Alignement dynamique des menus GitHub
│
├── declaration/      📂 Déclarations YAML des applications
│   ├── _example/                -> Modèle de référence commenté
│   └── CAT-{app_name}/          -> Dossier d'une application
│       └── CAT-{app_name}.yaml  -> Fichier déclaratif de l'application
│
└── schemas/          📂 Schéma JSON v2 de gouvernance
    └── app-declaration.schema.json
```

### Où et comment déposer vos fichiers ?
- **Vos scripts de test personnels :** Déposez-les dans le dossier `scripts/`.
- **Vos déclarations d'application de test :** Déposez-les dans `declaration/CAT-{app_name}/CAT-{app_name}.yaml`.
  > 💡 **Astuce :** Pour créer un fichier de test, copiez simplement le modèle de référence déjà présent dans le dépôt sous `declaration/_example/_example.yaml` ou dupliquez l'un des fichiers existants dans `declaration/CAT-*/`.

---

## ⚙️ 2. Prérequis d'Exécution sur Poste Professionnel

### 2.1 Interpréteur PowerShell
- Les scripts sont optimisés pour **Windows PowerShell 5.1** (intégré par défaut dans toutes les versions de Windows 10/11) ainsi que pour **PowerShell 7+** (`pwsh`).

### 2.2 Pourquoi utiliser `-ExecutionPolicy Bypass` ?
Sur les ordinateurs d'entreprise, les stratégies de sécurité (GPO) interdisent généralement l'exécution de scripts `.ps1` non signés numériquement (`Restricted` ou `RemoteSigned`).
L'argument `-ExecutionPolicy Bypass` permet de lever temporairement cette restriction **uniquement pour le processus lancé**, sans modifier les paramètres système de la machine et **sans nécessiter de privilèges administrateur**.

### 2.3 Connexion Azure CLI (Optionnelle selon le test)
- Pour tester la **syntaxe et la nomenclature locale**, aucune connexion réseau n'est nécessaire.
- Pour tester le **contrôle SSoT, le calcul différentiel (Plan) ou l'import**, une session Azure CLI active est requise :
  ```powershell
  az login
  ```

---

## 🧪 3. Scénarios de Test Pas à Pas

---

### 🟢 Scénario 1 : Validation Syntaxe, Schéma et Nomenclature (100% Local & Hors-ligne)

> **Objectif :** Démontrer à votre manager la capacité du moteur à vérifier la grammaire YAML, le respect du schéma JSON v2 et les normes strictes de nommage Ardian en quelques secondes, sans aucun appel réseau.

#### Commande :
```powershell
powershell -ExecutionPolicy Bypass -File scripts\Tester-Declarations.ps1 -Stage SchemaOnly
```

#### Ce que le script effectue :
1. Détecte tous les fichiers `.yaml` sous `declaration/` (en ignorant les exemples commençant par `_`).
2. Vérifie la concordance stricte des noms : le dossier `CAT-{app_name}` et le fichier `CAT-{app_name}.yaml`.
3. Valide le contenu contre le schéma JSON v2 (`schemas/app-declaration.schema.json`).
4. Vérifie la nomenclature obligatoire de chaque Access Package :
   - Format : `{app_name} - [Contexte] [Privilège] - [Environnement]` ou `{app_name} - [Privilège] - [Environnement]`.
   - Environnement strictement limité à : `DEV`, `UAT`, `PRD`, `TST`, `GLB`.

#### Résultat attendu à l'écran :
```text
🔍 Analyse de 11 fichier(s) déclaratif(s)...

====================================================
📋 ÉTAPE 1 : SYNTAXE & CONFORMITÉ DU SCHÉMA YAML
====================================================
Validation en cours : ...\declaration\CAT-new_nomenclature\CAT-new_nomenclature.yaml
  ✅ Conforme au schéma Ardian v2.
...
✅ Étape 1 validée avec succès : tous les fichiers sont conformes.
```

---

### 🔴 Scénario 2 : Démonstration de la Sécurité et Blocage des Erreurs

> **Objectif :** Montrer comment le système intercepte immédiatement les erreurs humaines avant tout déploiement.

#### Déroulement de la manipulation :
1. Ouvrez un fichier déclaratif sous `declaration/CAT-.../*.yaml`.
2. Introduisez volontairement une anomalie, par exemple :
   - Modifier un environnement en `Production` (seul `PRD` est autorisé).
   - Ou retirer le préfixe applicatif sur le nom d'un Access Package.
3. Lancez la validation :
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\Tester-Declarations.ps1 -Stage SchemaOnly
   ```
4. **Observation :** Le script bloque immédiatement avec un message rouge explicite détaillant le fichier, la ligne et la règle violée.
5. Rétablissez la valeur correcte et relancez : le script repasse au vert.

---

### 🟡 Scénario 3 : Contrôle SSoT et Calcul du Plan Différentiel GitOps (Mode Lecture Seule)

> **Objectif :** Démontrer le fonctionnement du moteur différentiel (Git vs Entra ID) et la validation des prérequis SSoT, sans aucune modification dans Entra ID.

#### Prérequis :
Authentification via Azure CLI sur votre tenant :
```powershell
az login
```

#### Commande :
```powershell
powershell -ExecutionPolicy Bypass -File scripts\Tester-Declarations.ps1 -Stage SSoTAndPlan
```
*(ou `-Stage All` pour enchaîner l'Étape 1 et l'Étape 2)*.

#### Ce que le script effectue :
1. **Contrôle SSoT (Single Source of Truth) :**
   - Interroge Entra ID pour vérifier que chaque groupe de sécurité, utilisateur approbateur ou ressource déclarée dans le YAML existe déjà dans l'annuaire.
   - Si une ressource est manquante, la validation échoue en signalant la dépendance absente.
2. **Calcul du différentiel GitOps (Diff) :**
   - Compare l'état souhaité dans Git à l'état réel dans Entra ID.
   - Identifie précisément les catalogues et packages à créer, mettre à jour, supprimer ou inchangés.
3. **Génération du rapport :**
   - Génère un fichier local `plan_summary.md` contenant la synthèse Markdown exacte qui est publiée sur les Pull Requests GitHub en environnement d'intégration continue.

#### Résultat attendu :
- Message de succès `✅ Étape 2 validée avec succès`.
- Fichier `plan_summary.md` généré à la racine avec le récapitulatif des ressources validées.

---

### 🔄 Scénario 4 : Rétro-Ingénierie & Import depuis Entra ID

> **Objectif :** Démontrer l'aspiration automatique d'un catalogue existant depuis Entra ID vers un fichier YAML propre et standardisé.

#### Commande :
```powershell
powershell -ExecutionPolicy Bypass -File scripts\Importer-DepuisEntra.ps1 -Applications "CAT-<NomDuCatalogue>"
```
*(Exemple : `-Applications "CAT-new_nomenclature"`)*.

#### Ce que le script effectue :
1. Se connecte à Microsoft Graph API.
2. Recherche le catalogue cible dans Entra ID.
3. Vérifie que chaque Access Package respecte les normes de nommage.
4. Crée ou écrase le dossier et le fichier `declaration/CAT-<NomDuCatalogue>/CAT-<NomDuCatalogue>.yaml`.
5. Génère un résumé d'importation dans `imported_apps.txt` et `import_summary.md`.

---

## 🧹 4. Nettoyage Post-Démonstration

Si vous avez créé des fichiers ou dossiers temporaires pour votre démonstration et souhaitez remettre votre copie locale à l'état initial sans laisser de traces dans Git :

```powershell
# Supprimer un dossier de test éventuel créé manuellement
Remove-Item -Recurse -Force "declaration\CAT-demo-*" -ErrorAction SilentlyContinue

# Supprimer les rapports Markdown temporaires générés localement
Remove-Item "plan_summary.md", "import_summary.md", "imported_apps.txt" -ErrorAction SilentlyContinue

# Annuler les modifications éventuelles sur les fichiers suivis
git checkout .

# Vérifier que l'espace de travail est parfaitement propre
git status
```

---

## 📊 5. Fiche Synthétique pour la Réunion (Cheatsheet)

| Étape de la Démo | Commande à exécuter | Durée | Argument clé pour le Manager |
| :--- | :--- | :--- | :--- |
| **1. Contrôle Syntaxe & Schéma** | `powershell -ExecutionPolicy Bypass -File scripts\Tester-Declarations.ps1 -Stage SchemaOnly` | ~2 sec | *"Vérification instantanée 100% hors-ligne ; aucune donnée ne part dans le cloud sans validation préalable."* |
| **2. Test de Résilience / Erreur** | Même commande après modification d'un fichier YAML | ~2 sec | *"Garde-fou strict : impossible de déployer une nomenclature invalide ou un environnement non autorisé."* |
| **3. Contrôle SSoT & Plan GitOps** | `powershell -ExecutionPolicy Bypass -File scripts\Tester-Declarations.ps1 -Stage SSoTAndPlan` | ~20 sec | *"Lecture seule sur Entra ID : le script calcule les différences (Diff) sans risque pour la production."* |
| **4. Rétro-Ingénierie (Import)** | `powershell -ExecutionPolicy Bypass -File scripts\Importer-DepuisEntra.ps1 -Applications "CAT-..."` | ~15 sec | *"Génération automatique de code YAML à partir de l'existant Entra ID, facilitant la reprise historique (T0)."* |
