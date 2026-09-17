#!/usr/bin/env python3
"""
reverse-engineer-entra.py - Aspiration et traduction declarative Entra ID vers GitOps.

Scenario D (Admin - Import depuis Entra ID) :
1. Recupere les noms d'applications cibles (separateurs virgules, insensible a la casse).
2. Interroge Microsoft Graph API pour trouver les catalogues et paquets d'acces correspondants.
3. Extrait les paquets d'acces, ressources liees et politiques d'approbation.
4. Genere l'arborescence : declaration/<nomapplication>/<nomapplication>.yaml.
5. Regle d'ecrasement : si l'application existe deja dans Git, son fichier est ecrase par la version extraite.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import yaml

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def query_graph_api(url: str) -> dict:
    """Execute un appel REST vers Microsoft Graph API via Azure CLI."""
    cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return json.loads(res.stdout) if res.stdout else {}
    except Exception as e:
        print(f"⚠️ Erreur lors de l'appel Graph API ({url}) : {e}", file=sys.stderr)
        return {}


def parse_target_applications(target_str: str) -> list:
    """Parse la liste des applications cibles en séparant par des virgules."""
    apps = [a.strip() for a in target_str.split(",") if a.strip()]
    return list(dict.fromkeys(apps))  # Dédoublonnage en conservant l'ordre


def reverse_engineer(target_apps: list, declaration_dir: str = "declaration") -> list:
    """Exécute l'extraction ciblée depuis Entra ID."""
    declaration_dir = os.path.abspath(declaration_dir)
    os.makedirs(declaration_dir, exist_ok=True)

    print("📡 Récupération de la liste des catalogues Entra ID...")
    cat_url = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?$top=999"
    cat_data = query_graph_api(cat_url)
    all_catalogs = cat_data.get("value", [])

    print(f"ℹ️ {len(all_catalogs)} catalogue(s) trouvé(s) dans l'annuaire Entra ID.")

    # Indexation insensible à la casse
    catalog_map = {}
    for cat in all_catalogs:
        display_name = cat.get("displayName", "").strip()
        if display_name:
            catalog_map[display_name.lower()] = cat

    imported_apps = []
    missing_apps = []

    for app_query in target_apps:
        query_norm = app_query.lower()
        matched_cat = catalog_map.get(query_norm)

        if not matched_cat:
            print(f"⚠️ Catalogue introuvable dans Entra ID pour : '{app_query}'")
            missing_apps.append(app_query)
            continue

        cat_id = matched_cat.get("id")
        cat_display_name = matched_cat.get("displayName")
        cat_description = matched_cat.get("description") or f"Catalogue pour {cat_display_name}"

        print(f"\n📥 Traitement de l'application : {cat_display_name} (ID: {cat_id})")

        # 1. Récupération des paquets d'accès
        ap_url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages?$filter=catalogId eq '{cat_id}'"
        ap_data = query_graph_api(ap_url)
        access_packages = ap_data.get("value", [])

        yaml_access_packages = []

        for ap in access_packages:
            ap_id = ap.get("id")
            ap_display_name = ap.get("displayName", "").strip()
            ap_description = ap.get("description") or f"Accès {ap_display_name}"

            # Décomposition du nom d'AP [Context/Subapp] [Privilege Level] - [Env]
            # Si le pattern standard est trouvé
            m = re.match(r"^(?:(.+?)\s+)?([^-]+?)\s*-\s*(.+)$", ap_display_name)
            if m:
                context_subapp = m.group(1).strip() if m.group(1) else ""
                privilege_level = m.group(2).strip()
                env = m.group(3).strip()
            else:
                context_subapp = ""
                privilege_level = ap_display_name
                env = "Prod"

            # 2. Récupération des ressources rattachées
            res_url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/{ap_id}/accessPackageResourceRoleScopes?$expand=accessPackageResourceRole,accessPackageResourceScope"
            res_data = query_graph_api(res_url)
            role_scopes = res_data.get("value", [])

            resources = []
            for rs in role_scopes:
                scope = rs.get("accessPackageResourceScope", {})
                res_info = scope.get("accessPackageResource", {})
                res_type = res_info.get("resourceType", "").lower()
                res_name = res_info.get("displayName", "")

                if "group" in res_type:
                    resources.append({
                        "resource_type": "EntraID Group",
                        "group_name": res_name
                    })
                elif "application" in res_type or "serviceprincipal" in res_type:
                    role_info = rs.get("accessPackageResourceRole", {})
                    resources.append({
                        "resource_type": "Application Role",
                        "enterprise_app": res_name,
                        "app_role": role_info.get("displayName", "Default Access")
                    })
                elif "sharepoint" in res_type:
                    resources.append({
                        "resource_type": "Sharepoint Group",
                        "catalog_id": cat_id,
                        "sharepoint_url": res_info.get("url", "https://sharepoint.com")
                    })

            # Fallback ressource par défaut si aucune ressource n'est encore liée
            if not resources:
                resources.append({
                    "resource_type": "EntraID Group",
                    "group_name": "GRP-DEFAULT-ACCESS"
                })

            ap_entry = {
                "context_subapp": context_subapp,
                "privilege_level": privilege_level,
                "env": env,
                "description": ap_description,
                "authorization_owners": ["iam-team@monentreprise123.onmicrosoft.com"],
                "resources": resources
            }
            if ap_display_name:
                ap_entry["display_name"] = ap_display_name

            yaml_access_packages.append(ap_entry)

        # Si aucun access package n'existait, on crée un package par défaut
        if not yaml_access_packages:
            yaml_access_packages.append({
                "context_subapp": "",
                "privilege_level": "Standard",
                "env": "Prod",
                "description": f"Package standard pour {cat_display_name}",
                "authorization_owners": ["iam-team@monentreprise123.onmicrosoft.com"],
                "resources": [
                    {
                        "resource_type": "EntraID Group",
                        "group_name": "GRP-DEFAULT-ACCESS"
                    }
                ]
            })

        # Normalisation du nom d'application kebab-case
        app_slug = re.sub(r"[^a-z0-9-]", "-", cat_display_name.lower()).strip("-")
        app_slug = re.sub(r"-+", "-", app_slug)

        doc = {
            "app_name": app_slug,
            "catalog_name": cat_display_name,
            "app_description": cat_description,
            "access_packages": yaml_access_packages
        }

        # 3. Création du dossier et écriture (1 application = 1 dossier contenant 1 fichier)
        app_folder = os.path.join(declaration_dir, app_slug)
        os.makedirs(app_folder, exist_ok=True)
        target_file = os.path.join(app_folder, f"{app_slug}.yaml")

        with open(target_file, "w", encoding="utf-8") as f:
            yaml.dump(doc, f, sort_keys=False, allow_unicode=True)

        print(f"✅ Fichier généré/écrasé avec succès : {target_file}")
        imported_apps.append(app_slug)

    print("\n========================================")
    print("📊 BILAN DU REVERSE ENGINEERING :")
    print(f"   Applications importées : {len(imported_apps)} ({', '.join(imported_apps)})")
    if missing_apps:
        print(f"   Applications non trouvées : {len(missing_apps)} ({', '.join(missing_apps)})")
    print("========================================")

    return imported_apps


def main():
    parser = argparse.ArgumentParser(description="Importation déclarative depuis Entra ID (Reverse Engineering)")
    parser.add_argument("--applications", required=True, help="Noms des applications séparés par des virgules")
    parser.add_argument("--declaration-dir", default="declaration", help="Répertoire cible (défaut: declaration)")
    parser.add_argument("--output-list", help="Fichier texte pour enregistrer la liste des apps importées")
    args = parser.parse_args()

    targets = parse_target_applications(args.applications)
    imported = reverse_engineer(targets, args.declaration_dir)

    if args.output_list:
        with open(args.output_list, "w", encoding="utf-8") as f:
            for app in imported:
                f.write(f"{app}\n")


if __name__ == "__main__":
    main()
