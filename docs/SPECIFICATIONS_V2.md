# Spécifications Techniques & Orientations de Design — Version 2.0 (V2)
## Modèle Opérationnel Cible "Run" — Entitlement Management Entra ID sous GitOps
### Ardian — Architecture Cloud IAM & Sécurité des Accès

---

| Métadonnée | Valeur |
|:---|:---|
| **Client** | Ardian |
| **Projet** | Industrialisation GitOps de l'Identity Governance Microsoft Entra ID |
| **Document** | Spécifications Techniques d'Architecture & Nouveaux Scénarios de Design (V2) |
| **Rôle / Auteur** | Architecte Cloud IAM & DevOps Platform |
| **Destinataires** | Architecture Review Board, Équipes IAM, Lead DevOps & Security Ardian |
| **Statut** | **Spécification V2 — Validée pour Implémentation** |
| **Version** | 2.0 (Ajustements Bulk, Fail-Safe Reverse Eng, Omni-Form & CODEOWNERS) |

---

## Synthèse des Nouveaux Arbitrages de Design (V2)

Ce document formalise les spécifications techniques d'architecture révisées (Version 2.0) pour répondre aux exigences opérationnelles réelles d'Ardian :

1. **Séparation User / Admin & Modification en masse** : Processus d'auto-validation préalable (Dry-Run / Preview d'impact avant toute modification de fichier), structure YAML dédiée avec support des listes séparées par virgule, et exécution en local via script PowerShell sécurisé.
2. **Workflow de validation à 3 niveaux** : Validation syntaxique CI, détection bloquante des ressources cibles avec relance possible sans resoumission de fichier (bouton *Re-run* ou ChatOps `/replan`), et double approbation humaine formelle avant le merge.
3. **Gouvernance `CODEOWNERS`** : Présentation et comparaison des deux options (Option 1 : Co-gouvernance IT Owners + IAM vs Option 2 : Gouvernance centralisée IAM Only).
4. **Rétro-Ingénierie ($T_0$)** : Aspiration directe sans création de PRs multiples, règle de rejet strict (*Fail-Safe*) sur non-conformité de nomenclature avec rapport d'audit avant export, et mode réinitialisation complète (*Full Resync*).
5. **Formulaire Unique (*Omni-Form*)** : Suppression de la saisie manuelle du nom d'application, et format minimaliste pour le décommissionnement (`app_name` + `action: delete_application`).
6. **Complémentarité Smart Discovery vs Terraform Plan** : Démonstration technique de la nécessité d'associer l'introspection Graph API au moteur d'orchestration IaC.

---

## 1. Séparation User / Admin & Modifications en Masse (*Bulk Operations*)

### 1.1. Principes et Périmètre
* **Utilisateurs Métiers** : Réalisent des opérations unitaires (1 application = 1 modification ciblée via le formulaire unique).
* **Administrateurs IAM** : Peuvent réaliser des modifications transverses en masse sur plusieurs fichiers YAML simultanément (ex: mise à jour du nom ou de l'email d'un approbateur ayant quitté l'entreprise sur plusieurs catalogues).
* **Périmètre strict** : Les modifications en masse sont restreintes aux **champs scalaires / unitaires** (ex: `authorization_owners`, `env`, `privilege_level`). Les associations complexes de ressources restent traitées via les fichiers unitaires.

### 1.2. Processus de Sécurisation : Le Sas d'Auto-Validation (Dry-Run & Confirmation)
Pour interdire toute modification à l'aveugle sur les fichiers déclaratifs, le processus impose une étape préalable d'analyse d'impact :

```
┌─────────────────────────────────┐
│     ÉTAPE 1 : SIMULATION        │  L'admin fournit le YAML de changement en masse.
│   (Dry-Run & Impact Analysis)   │  Le moteur calcule le delta sans toucher aux fichiers.
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│     ÉTAPE 2 : PRÉVISUALISATION  │  Rapport clair : "X fichiers impactés, Y occurrences".
│        & CONFIRMATION           │  Question explicite : "Êtes-vous sûr de vouloir appliquer ces changements ?"
└────────────────┬────────────────┘
                 │ (Oui formel)
                 ▼
┌─────────────────────────────────┐
│     ÉTAPE 3 : APPLICATION       │  Modification effective des fichiers YAML sur le disque.
│        SUR LE DISQUE            │  Création de la branche Git et commit.
└─────────────────────────────────┘
```

1. **Étape 1 : Simulation (Dry-Run)** : Le moteur parcourt les applications cibles, identifie les correspondances exactes sans altérer les fichiers sur le disque, et génère un rapport de prévisualisation.
2. **Étape 2 : Confirmation explicite de l'administrateur** : Le rapport présente le nombre exact de fichiers et d'occurrences qui vont être modifiés et sollicite un accord formel (*"Êtes-vous sûr de vouloir appliquer ces changements ?"*).
3. **Étape 3 : Application effective** : Les fichiers sur le disque sont modifiés uniquement après cette validation.

### 1.3. Structure du Fichier de Déclaration en Masse (`bulk-change.yaml`)
L'administrateur déclare ses intentions dans un fichier au format suivant :

```yaml
# ==============================================================================
# DÉCLARATION DE MODIFICATION EN MASSE (BULK CHANGE) — USAGE ADMIN IAM
# ==============================================================================
bulk_change:
  description: "Remplacement du Data Owner suite au départ de Sophie Martin"

  # Applications cibles :
  # - Vous pouvez lister les applications séparées par une virgule sur une ligne
  # - Ou mettre "all" pour cibler l'ensemble du référentiel
  target_apps: "catalogue-test-v1, catalogue-test-v2, salesforce-crm"

  # Champ unitaire ciblé :
  target_field: "authorization_owners"   # Ex: authorization_owners, env, privilege_level

  # Règle de remplacement :
  old_value: "sophie.martin@ardian.com"
  new_value: "alexandre.leroy@ardian.com"
```

### 1.4. Implémentation en Local via Script PowerShell
Sur le poste administrateur, le script PowerShell `Invoke-BulkUpdate.ps1` opère de bout en bout :
1. **Parsing** : Lit `bulk-change.yaml` et découpe `target_apps` par virgule (`.Split(',').Trim()`).
2. **Simulation (`-WhatIf`)** : Inspecte les fichiers dans `declarations/apps/`, compte les occurrences de `old_value` et affiche un rapport à l'écran :
   ```text
   ------------------------------------------------------------
   RAPPORT DE PRÉVISUALISATION (DRY-RUN)
   ------------------------------------------------------------
   [OK] catalogue-test-v1.yaml : 2 occurrences trouvées
   [OK] catalogue-test-v2.yaml : 4 occurrences trouvées
   [IGNORÉ] salesforce-crm.yaml : 0 occurrence (valeur absente)
   ------------------------------------------------------------
   Total : 2 fichiers seront modifiés (6 remplacements au total).
   ------------------------------------------------------------
   ```
3. **Sas d'Auto-Validation** : Sollicite l'accord via `Read-Host "Confirmez-vous l'application de ces modifications sur les fichiers ? (O/N)"`. En cas de réponse négative, le script s'arrête sans toucher aux fichiers.
4. **Exécution & Git** : En cas de confirmation positive, remplace les chaînes, crée la branche `admin/bulk-update-<date>` et génère le commit prêt à être poussé sur GitHub.

---

## 2. Le Workflow de Validation à 3 Niveaux

```
┌─────────────────────────────────┐
│          VALIDATION 1           │  Automatique (CI)
│  Syntaxe & Conformité Schéma v2 │  Bloquant technique (exit 1 si invalide)
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│          VALIDATION 2           │  IT Owner / Demandeur
│   Détection Dépendances SSoT    │  Vérification de l'existence des actifs cibles
│ (Groupes, App Roles, SP Sites)  │  Bloquant technique si ressource absente
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│          VALIDATION 3           │  IT Owner + Responsable IAM
│     Double Approbation Merge    │  Validation formelle SoD avant Terraform Apply
└─────────────────────────────────┘
```

### 2.1. Validation 1 — Automatique (CI)
* Contrôle syntaxique et validation structurelle stricte via `schemas/app-declaration.schema.json`.
* Si un champ obligatoire manque ou si le format d'un email est incorrect, le job `validate-schema` échoue immédiatement. Aucun appel n'est émis vers Entra ID.

### 2.2. Validation 2 — IT Owner & Détection Bloquante des Ressources
* **Comment rendre cette étape techniquement bloquante ?**
  1. Lors du step de *Smart Discovery* et d'exécution du plan Terraform, les blocs `data` interrogent Microsoft Entra ID pour chaque ressource déclarée (`EntraID Group`, `Application Role`, `Sharepoint Group`).
  2. Si un actif est introuvable :
     * Le rapport CI classe l'asset dans la section d'alerte :
       `### 🚫 Assets bloquants à créer avant de lancer le merge :`
     * Le script positionne `has_blocking_assets=true` et termine le step avec `exit 1`.
     * Le GitHub Check de la PR passe à l'état **Échec (Failed ❌)**.
     * La règle de protection de branche (`Branch Protection Rule` sur `main` avec `Require status checks to pass before merging`) **grise et verrouille physiquement le bouton "Merge"**. Aucun utilisateur ne peut forcer le déploiement.
* **Comment relancer la PR une fois l'asset créé dans Entra ID (SANS resoumettre le YAML) ?**
  Dès que l'administrateur a provisionné le groupe ou le rôle manquant dans Entra ID :
  * **Option 1 (Native GitHub UI)** : Le demandeur clique sur le bouton **"Re-run failed jobs"** (ou "Re-run all jobs") dans l'onglet *Checks* de la PR.
  * **Option 2 (ChatOps — Expérience fluide sans friction)** :
    * Un workflow léger `pr-chatops.yml` écoute l'événement `on: issue_comment`.
    * Le demandeur poste simplement un commentaire `/replan` ou `/check` dans la PR.
    * Le workflow redéclenche automatiquement le pipeline de validation. La CI réinterroge Entra ID via OIDC, constate que le groupe est désormais présent, génère un plan avec $0$ ressource bloquante, et passe le Check au vert (✅).

### 2.3. Validation 3 — IT Owner + IAM : Double Approbation Formelle avant Merge
Pour exiger techniquement les deux approbations distinctes :
1. **Via GitHub Branch Protection & CODEOWNERS** :
   * Activation de `Require pull request reviews before merging` avec `Required approvals: 2`.
   * Activation de l'option stricte `Require review from Code Owners`.
   * Le fichier `CODEOWNERS` attribue la propriété du fichier modifié au groupe métier (`@ardian/it-owners-<app>`) et à l'équipe sécurité (`@ardian/cloud-iam-team`).
   * Le bouton de merge reste bloqué tant qu'au moins un membre de chacune de ces deux équipes n'a pas formellement cliqué sur "Approve".
2. **Via GitHub Deployment Environments (Sécurité renforcée au niveau CD)** :
   * Le job de déploiement `04-cd-apply` est associé à l'environnement GitHub `production-entraid`.
   * Cet environnement est configuré avec des **Required Reviewers** :
     - Équipe IT Owner de l'application
     - Équipe Sécurité IAM
   * Le runner suspend l'exécution de `terraform apply` jusqu'à validation solennelle dans l'interface de déploiement GitHub.

---

## 3. La Gouvernance via le Fichier `CODEOWNERS`

Deux options d'implémentation sont soumises à l'arbitrage d'Ardian :

### Option 1 : Gouvernance Déléguée & Double Validation (IT Owners + IAM)
Chaque application a pour propriétaires formels son équipe métier ET l'équipe IAM :
```text
*                                       @ardian/cloud-iam-team
declarations/apps/salesforce-crm.yaml   @ardian/it-owners-salesforce @ardian/cloud-iam-team
declarations/apps/sap-s4hana.yaml       @ardian/it-owners-sap        @ardian/cloud-iam-team
```
* **Bénéfice** : Ségrégation stricte des tâches (*SoD*), chaque département reste garant exclusif de ses habilitations.
* **Contrainte** : Nécessite de maintenir des équipes GitHub pour chaque domaine applicatif métier.

### Option 2 : Gouvernance Centralisée IAM (Recommandée pour le Run Initial)
Seule l'équipe IAM est déclarée propriétaire de l'ensemble des fichiers déclaratifs :
```text
*                                       @ardian/cloud-iam-team
declarations/apps/*.yaml                @ardian/cloud-iam-team
```
* **Bénéfice** : Simplicité d'administration maximale au démarrage du Run, pas de dépendance envers les équipes métiers sur GitHub. L'équipe IAM agit comme guichet unique de validation technique et sécurité.

---

## 4. Rétro-Ingénierie (Reverse Engineering) : Récupération de l'Existant

### 4.1. Principes et Absence de PRs Multiples
Le workflow de rétro-ingénierie a pour vocation d'amorcer ou de resynchroniser le référentiel Git à $T_0$. Il **ne crée pas de Pull Request par application** : il génère directement les fichiers et commite sur la branche de travail ou de synchronisation.

### 4.2. Règle Fail-Safe sur la Nomenclature des Access Packages
* Si un seul Access Package au sein d'un catalogue ne respecte pas la convention stricte `[Context/Subapp] [Privilege Level] - [Env]` :
  * **Le chargement de l'application complète échoue** et l'application est exclue de l'export.
* **Rapport de Pré-Audit explicatif** :
  Avant validation de l'export, le workflow dresse la liste des applications rejetées et affiche le motif précis de non-conformité :
  ```text
  ------------------------------------------------------------
  RAPPORT DE PRÉ-AUDIT REVERSE ENGINEERING
  ------------------------------------------------------------
  ✅ APPLICATIONS CONFORMES (EXPORTABLES) : 12
  ❌ APPLICATIONS EN ÉCHEC (REJETÉES) : 1
     • Application : cat-legacy-finance
       Motif : L'Access Package 'Finance-Old-Profile' ne respecte pas le pattern [Context] [Privilege] - [Env].
       Action : Corriger le nom dans Entra ID avant de relancer l'export.
  ------------------------------------------------------------
  ```

### 4.3. Intégration GitHub Actions & Mode Réinitialisation Complète (*Full Resync*)
* **Fichier de workflow** : `.github/workflows/05-reverse-engineering.yml`.
* **Déclencheur** : `workflow_dispatch` (manuel uniquement).
* **Sécurité & Droits** : Accessible exclusivement aux administrateurs du repository (équipe IAM).
* **Comportement Full Resync (Gestion de l'existant GitHub vs Entra ID)** :
  Si Entra ID contient `APP1`, `APP2`, `APP3` et que GitHub ne contient que `APP1` (ou des fichiers obsolètes) :
  1. Le workflow vide d'abord le répertoire `declarations/apps/*.yaml` (en préservant `_example.yaml` et `.gitkeep`).
  2. Il reconstruit et écrit l'intégralité des applications conformes aspirées depuis Entra ID (`APP1`, `APP2`, `APP3`).
  3. Il commite l'état propre et aligné, garantissant qu'aucun fichier orphelin ne subsiste dans Git.

---

## 5. Restructuration UX : Le Formulaire Unique (*Omni-Form*)

### 5.1. Point d'Entrée Unique
Remplacement des formulaires séparés par un formulaire d'Issue unique dans `.github/ISSUE_TEMPLATE/entitlement-management.yml`.
* **Zéro saisie redondante** : Le champ "Nom de l'application" est supprimé de l'Issue ; il est extrait dynamiquement du champ `app_name` du fichier YAML déposé.
* **Bloc Didactique Intégré** : Explication claire des règles (Nouveau fichier = Création ; Fichier existant = Modification ; Décommissionnement = voir ci-dessous).

### 5.2. Cas Spécifique du Décommissionnement
Pour décommissionner une application et son catalogue, l'utilisateur soumet un fichier YAML **volontairement épuré de tout rôle ou ressource** :

```yaml
app_name: "catalogue-test-v1"
action: "delete_application"
```

* **Traitement Automatisé dans `01-issue-to-pr.yml`** :
  1. La CI détecte le champ `action: delete_application`.
  2. Elle supprime le fichier `declarations/apps/${app_name}.yaml` via `git rm`.
  3. Elle ouvre la PR de décommissionnement avec le titre `[Entitlement] <app_name> — 🗑️ Décommissionnement`.
  4. La CI calcule le plan de destruction propre du catalogue et des packages associés dans Entra ID.

---

## 6. Clarification Technique : Smart Discovery vs Terraform Plan

### 6.1. Rôles Respectifs et Différences Fondamentales

| Dimension | Smart Discovery (Script Graph API pré-Terraform) | Terraform Plan (Moteur d'Orchestration HashiCorp) |
|:---|:---|:---|
| **Périmètre d'observation** | **L'annuaire Microsoft Entra ID réel** en direct via Graph API (y compris les ressources créées hors Terraform). | **Uniquement le state distant** (`terraform.tfstate`) confronté au code HCL (`.tf`). |
| **Mission principale** | **Introspection et Préparation de l'adoption** :<br>1. Détecte si le catalogue ou les packages existent déjà dans Entra ID.<br>2. Détecte les ressources déjà associées au catalogue.<br>3. Génère dynamiquement `terraform/imports.tf` (`import {}`).<br>4. Vérifie l'existence préalable des groupes et rôles cibles. | **Calcul Différentiel et Idempotence** :<br>1. Compare l'état désiré (YAML) avec l'état importé.<br>2. Calcule les attributs précis à modifier (durée, approbateurs, paramètres).<br>3. Établit le graphe d'exécution ordonné.<br>4. Garantit l'exécution atomique. |
| **Comportement si exécuté SEUL** | **Insuffisant** : Ne sait pas orchestrer, ni gérer les rollbacks, ni maintenir l'idempotence des politiques complexes. | **Échec critique** : Renvoie une erreur `HTTP 409 Conflict (Object already exists)` si le catalogue existe déjà sans être dans le state. |

### 6.2. Peut-on se contenter d'un seul des deux ?
* **NON, ils sont fondamentalement indissociables** :
  * **Sans Smart Discovery** : Terraform est aveugle face aux actifs préexistants dans Azure. Il tente systématiquement de les recréer, provoquant des erreurs 409 ou des destructions intempestives.
  * **Sans Terraform Plan** : Il faudrait coder un moteur de réconciliation complet en Python (gestion de l'état, dépendances, rollbacks, concurrence de verrous), ce qui équivaudrait à réécrire Terraform.
* **Synergie Ardian** : La Smart Discovery prépare le terrain en instruisant Terraform sur l'existant (`import {}`), et Terraform exécute la convergence d'état avec une rigueur absolue.
* **Optimisation de performance** : Le script de Smart Discovery ne scanne que les applications identifiées dans la PR (et non tout l'annuaire de l'entreprise), garantissant une exécution rapide en moins de 30 secondes.

---

## 7. Plan d'Implémentation & Prochaines Étapes

Les développements du modèle V2 seront orchestrés selon les étapes suivantes :

1. **Étape 1** : Implémentation de l'Omni-Form (`entitlement-management.yml`) avec prise en charge du format minimaliste `action: delete_application` dans `01-issue-to-pr.yml`.
2. **Étape 2** : Configuration du fichier `.github/CODEOWNERS` (selon l'Option 1 ou Option 2 retenue) et activation des règles de protection sur la branche `main`.
3. **Étape 3** : Intégration du mécanisme de blocage strict des assets manquants et de la relance ChatOps (`/replan`) dans `03-ci-validate-and-plan.yml`.
4. **Étape 4** : Développement du script PowerShell `Invoke-BulkUpdate.ps1` et du modèle `bulk-change.yaml` avec simulation Dry-Run et confirmation interactive.
5. **Étape 5** : Développement du workflow `05-reverse-engineering.yml` avec rapport de pré-audit des nomenclatures non conformes et mode Full Resync.
