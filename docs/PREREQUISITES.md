# Pré-requis d'Infrastructure et Configuration OIDC

Ce document détaille les éléments requis dans Azure AD / Entra ID et Azure Subscriptions pour exécuter la chaîne automatisée d'Entitlement Management.

## 1. Authentication OIDC (Federated Credentials)

Le pipeline GitHub Actions s'authentifie auprès de Microsoft Graph et Azure ARM sans secret client permanent (Secret-less via OIDC).

### Application Registration dans Entra ID
Créez une Application Registration dédiée à la CI/CD (ex: `app-github-entitlement-cicd`).

### Rôles Entra ID requis
Attribuez les rôles suivants au Service Principal de cette application :
- **Identity Governance Administrator** : requis pour lire/créer/modifier les catalogues, Access Packages, et assignment policies dans Entra ID.
- **Directory Readers** : requis pour interroger les groupes de sécurité et Service Principals via Graph API (blocs `data`).

### Configuration des Federated Credentials
Dans l'App Registration -> **Certificates & secrets** -> **Federated credentials**, ajoutez 2 identifiants fédérés :

1. **Pull Requests (CI - Plan)** :
   - Entity: `Pull Request`
   - Organization: `<votre-org-github>`
   - Repository: `ardian-entitlement-mgmt`

2. **Main Branch (CD - Apply)** :
   - Entity: `Branch`
   - Organization: `<votre-org-github>`
   - Repository: `ardian-entitlement-mgmt`
   - Branch: `main`

## 2. Backend Terraform (State Storage)

Le state Terraform est conservé de façon centralisée et sécurisée dans un Azure Blob Storage.

- **Resource Group** : `rg-terraform-state`
- **Storage Account** : `stardiantfstate` (Accès public désactivé, TLS 1.2 min)
- **Blob Container** : `entitlement-mgmt`

### Rôle Azure RBAC pour le Backend
Attribuez le rôle RBAC Azure suivant au Service Principal OIDC sur le Storage Account ou le conteneur :
- **Storage Blob Data Contributor**

## 3. GitHub Repository Secrets

Dans votre dépôt GitHub, sous **Settings** -> **Secrets and variables** -> **Actions**, configurez les secrets suivants :

| Nom du Secret | Description | Exemple |
|---|---|---|
| `AZURE_CLIENT_ID` | Application (client) ID de l'App Registration OIDC | `00000000-0000-0000-0000-000000000000` |
| `AZURE_TENANT_ID` | Directory (tenant) ID Entra ID | `11111111-1111-1111-1111-111111111111` |
| `AZURE_SUBSCRIPTION_ID` | ID de la souscription Azure hébergeant le backend | `22222222-2222-2222-2222-222222222222` |

## 4. Pré-requis sur la machine locale (pour dev/test local)

- **Terraform** >= 1.5.0
- **Azure CLI** (`az login`)
- **Python** >= 3.10 (pour exécution locale des scripts de validation)
- Dépendances Python : `pip install pyyaml jsonschema`
