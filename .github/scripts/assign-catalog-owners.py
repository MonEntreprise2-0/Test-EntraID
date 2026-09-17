#!/usr/bin/env python3
"""
assign-catalog-owners.py - Assignation automatique des propriétaires de catalogues dans Entra ID.

Pour chaque application déclarée dans le repository :
1. Détecte les `authorization_owners` définis dans le fichier YAML.
2. Interroge Microsoft Graph pour localiser le catalogue correspondant et ses identifiants.
3. Assigne chaque utilisateur propriétaire au rôle "Catalog owner" (ID: ae79f266-94d4-4dab-b730-feca7e132178)
   sur le catalogue concerné (directoryScopeId = /AccessPackageCatalog/{catalog_id}).
"""

import json
import os
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

try:
    import yaml
except ImportError:
    print("Module pyyaml requis.")
    sys.exit(0)

# Built-in constant ID pour le rôle "Catalog owner" dans Entitlement Management Entra ID
CATALOG_OWNER_ROLE_ID = "ae79f266-94d4-4dab-b730-feca7e132178"


def az_rest_get(url: str):
    """Effectue un appel GET via az rest."""
    cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0 and proc.stdout:
            return json.loads(proc.stdout)
    except Exception:
        pass
    return None


def az_rest_post(url: str, body: dict):
    """Effectue un appel POST via az rest."""
    cmd = ["az", "rest", "--method", "post", "--url", url, "--headers", "Content-Type=application/json", "--body", json.dumps(body)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            return True
        else:
            print(f"  ⚠️ Erreur az rest post: {proc.stderr}", file=sys.stderr)
            return False
    except Exception as e:
        print(f"  ⚠️ Exception az rest post: {e}", file=sys.stderr)
        return False


def get_all_catalogs() -> dict:
    """Retourne une map {display_name_lower: catalog_obj} de tous les catalogues Entra ID."""
    url = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?$top=999"
    data = az_rest_get(url)
    catalogs = {}
    if data and "value" in data:
        for cat in data["value"]:
            dname = cat.get("displayName", "").strip().lower()
            if dname:
                catalogs[dname] = cat
    return catalogs


def resolve_user_id(email: str) -> str:
    """Résout l'object_id d'un utilisateur par son email ou UPN."""
    cleaned = email.strip()
    encoded = cleaned.replace("'", "''")
    url = f"https://graph.microsoft.com/v1.0/users?$filter=userPrincipalName eq '{encoded}' or mail eq '{encoded}'&$select=id,displayName,userPrincipalName"
    data = az_rest_get(url)
    if data and "value" in data and len(data["value"]) > 0:
        return data["value"][0].get("id", "")
    return ""


def get_existing_role_assignments(catalog_id: str) -> list:
    """Liste les assignations de rôles existantes pour ce catalogue."""
    url = f"https://graph.microsoft.com/v1.0/roleManagement/entitlementManagement/roleAssignments?$filter=directoryScopeId eq '/AccessPackageCatalog/{catalog_id}'"
    data = az_rest_get(url)
    if data and "value" in data:
        return data["value"]
    return []


def main():
    print("====================================================")
    print("👑 ASSIGNATION DES PROPRIÉTAIRES DE CATALOGUES (Entra ID)")
    print("====================================================")
    print(f"🔑 Rôle 'Catalog owner' (built-in ID) : {CATALOG_OWNER_ROLE_ID}")

    catalogs = get_all_catalogs()
    print(f"📊 Catalogues détectés dans Entra ID : {len(catalogs)}")

    dec_dir = "declaration"
    if not os.path.isdir(dec_dir):
        return

    for root, dirs, files in os.walk(dec_dir):
        dirs[:] = [d for d in dirs if not d.startswith("_")]
        for fn in files:
            if (fn.endswith(".yaml") or fn.endswith(".yml")) and not fn.startswith("_"):
                fpath = os.path.join(root, fn)
                try:
                    with open(fpath, "r", encoding="utf-8") as f:
                        doc = yaml.safe_load(f)
                    if not doc or not isinstance(doc, dict):
                        continue

                    app_name = doc.get("app_name") or doc.get("application_name")
                    cat_name = doc.get("catalog_name") or (doc.get("catalog", {}).get("display_name") if isinstance(doc.get("catalog"), dict) else None) or app_name
                    if not cat_name:
                        continue

                    # Recherche du catalogue dans Entra ID
                    matched_catalog = catalogs.get(cat_name.lower()) or catalogs.get(app_name.lower())
                    if not matched_catalog:
                        print(f"  ℹ️ Catalogue '{cat_name}'/'{app_name}' introuvable dans Entra ID.")
                        continue

                    catalog_id = matched_catalog.get("id")
                    actual_name = matched_catalog.get("displayName")

                    # Extraction de tous les authorization_owners
                    owners = set()
                    for ap in doc.get("access_packages", []):
                        for o in ap.get("authorization_owners", []):
                            if o and str(o).strip():
                                owners.add(str(o).strip())

                    if not owners:
                        continue

                    existing_assignments = get_existing_role_assignments(catalog_id)
                    assigned_principals = {
                        a.get("principalId") for a in existing_assignments
                        if a.get("roleDefinitionId") == CATALOG_OWNER_ROLE_ID
                    }

                    for owner_email in owners:
                        user_id = resolve_user_id(owner_email)
                        if not user_id:
                            print(f"  ℹ️ Utilisateur introuvable dans le tenant pour '{owner_email}'.")
                            continue

                        if user_id in assigned_principals:
                            print(f"  ✅ '{owner_email}' est déjà Catalog Owner sur '{actual_name}'.")
                            continue

                        body = {
                            "roleDefinitionId": CATALOG_OWNER_ROLE_ID,
                            "principalId": user_id,
                            "directoryScopeId": f"/AccessPackageCatalog/{catalog_id}"
                        }
                        if az_rest_post("https://graph.microsoft.com/v1.0/roleManagement/entitlementManagement/roleAssignments", body):
                            print(f"  🎉 '{owner_email}' assigné avec succès comme Catalog Owner sur '{actual_name}' (ID: {catalog_id})")
                        else:
                            print(f"  ⚠️ Échec de l'assignation de '{owner_email}' sur '{actual_name}'")

                except Exception as e:
                    print(f"⚠️ Erreur lors du traitement de {fn} : {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
