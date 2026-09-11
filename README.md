# Ardian — Entitlement Management Entra ID

> Automatisation GitOps de l'Entitlement Management Azure AD / Entra ID via Terraform et GitHub Actions.

## 🎯 Objectif

Ce repository implémente une chaîne CI/CD déclarative où un fichier YAML par application pilote automatiquement les ressources d'Entitlement Management dans Entra ID :
- **Catalogues** (`azuread_access_package_catalog`)
- **Access Packages** (`azuread_access_package`)
- **Politiques d'assignation** (`azuread_access_package_assignment_policy`)

## 📐 Principes d'architecture

| Principe | Description |
|---|---|
| **Entra ID = SSoT** | Entra ID est la Source Unique de Vérité. Le repo stocke les intentions de déploiement. |
| **1 App = 1 YAML** | Chaque application a son propre fichier dans `declarations/apps/` |
| **Mode Consommateur** | Terraform ne crée pas les groupes/applications sous-jacentes. Il les interroge via des blocs `data`. |

## 🚀 Workflows

| Action | Comment |
|---|---|
| **Créer un Access Package** | Ouvrir une Issue via le template *📦 Demande Entitlement Management* |
| **Modifier un Access Package** | 1. Télécharger le YAML via Actions → *📥 Télécharger un YAML existant* 2. Modifier localement 3. Re-soumettre via Issue |
| **Suivre le déploiement** | Consulter la Pull Request générée automatiquement |

## 📁 Structure du repository

```
├── .github/             # Workflows GitHub Actions & Issue Templates
├── declarations/apps/   # Fichiers YAML déclaratifs (1 par application)
├── terraform/           # Code Terraform (IaC)
├── schemas/             # JSON Schema pour la validation
└── docs/                # Documentation utilisateur
```

## 📋 Pré-requis

Voir [docs/PREREQUISITES.md](docs/PREREQUISITES.md) pour la liste complète.
