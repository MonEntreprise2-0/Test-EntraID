# Architecture Technique — GitOps Entitlement Management

Ce document décrit les principes d'architecture et la conception technique de la solution d'industrialisation du run d'Entitlement Management pour Ardian.

## 📐 Principes fondateurs

- **Entra ID = Source Unique de Vérité (SSoT)** : Le repo GitHub contient les *intentions* de configuration. Entra ID contient la vérité absolue.
- **1 Application = 1 Catalogue = 1 Fichier YAML** : Isolation complète des droits par application dans `declarations/apps/<nom-app>.yaml`.
- **Mode Consommateur Strict** : Terraform ne crée JAMAIS de groupe ou d'application Entra ID. Toutes les dépendances sont lues via des blocs `data`. Si un groupe manque dans Entra ID, `terraform plan` échoue.

## 🔄 Flux de données & Cycle de vie (GitOps)

1. **Utilisateur / Métier** : Ouvre une Issue via le template d'Issue Form.
2. **Workflow 01-issue-to-pr.yml** : Extrait le YAML via `parse-issue-body.py`, crée une branche et ouvre une PR.
3. **Workflow 03-ci-validate-and-plan.yml** : Valide le schéma YAML via `validate-schema.py`, exécute `terraform plan` via OIDC pour valider les dépendances SSoT dans Entra ID.
4. **Approbation** : L'équipe IAM & Data Owner révisent le plan et approuvent la PR.
5. **Workflow 04-cd-apply.yml** : Sur merge dans `main`, exécute `terraform apply -auto-approve` pour déployer dans Entra ID.
