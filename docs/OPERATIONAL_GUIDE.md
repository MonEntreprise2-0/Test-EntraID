# Guide Opérationnel — Run Entitlement Management

Ce guide est destiné aux équipes IAM, DevOps et aux Data Owners responsables de la gestion des accès applicatifs chez Ardian.

---

## 🟢 Cas 1 : Déclarer ou modifier une application (Via GitHub Issues)

### 1.1 Créer un Access Package (Nouvelle Application)
1. Allez sur l'onglet **Issues** du dépôt GitHub.
2. Cliquez sur **New Issue** et choisissez le template **📦 Demande Entitlement Management**.
3. Remplissez les champs (Nom d'app kebab-case, Type d'opération, Contenu YAML, Justification, Checklist).
4. Cliquez sur **Submit new issue**.

### 1.2 Traitement automatique
1. Le workflow `01-issue-to-pr.yml` parse l'Issue, crée la branche et ouvre la PR.
2. Le workflow `03-ci-validate-and-plan.yml` valide le JSON Schema et exécute `terraform plan`.
3. Le plan est posté en commentaire de PR.

### 1.3 Approbation & Déploiement
1. Après revue et merge sur `main`, le workflow `04-cd-apply.yml` applique les changements dans Entra ID.

---

## 🟡 Cas 2 : Modifier un YAML existant (Workflow Download)

1. Onglet **Actions** -> **📥 Télécharger un YAML existant** -> **Run workflow**.
2. Téléchargez l'artefact ZIP `<nom-app>-yaml`.
3. Modifiez localement et soumettez via une nouvelle Issue.
