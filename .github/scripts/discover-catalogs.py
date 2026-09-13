#!/usr/bin/env python3
"""
discover-catalogs.py - Decouverte automatique des catalogues dans Entra ID.

Ce script interroge l'API Microsoft Graph via Azure CLI (`az rest`) pour
recenser les catalogues d'Entitlement Management existants dans le tenant.

Il compare ensuite chaque fichier YAML declaratif :
  - Si le catalogue existe deja dans Entra ID (comparaison insensible a la casse) :
    -> Marque comme `exists: true` avec son ID reel.
  - Si le catalogue n'existe pas encore :
    -> Marque comme `exists: false` (Terraform le creera).

Sorties :
  - Un fichier JSON consomme par Terraform (`discovered_catalogs.json`)
  - Un fichier Markdown pour le resume de la PR / du CD (`discovered_summary.md`)
"""

import argparse
import json
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("Module pyyaml requis. Installation : pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def get_entraid_catalogs() -> list:
    """Interroge Microsoft Graph API pour lister les catalogues Entra ID.
    Teste les endpoints v1.0 (/catalogs) et beta (/accessPackageCatalogs).
    """
    endpoints = [
        "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?$top=999",
        "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs?$top=999",
        "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs?$top=999",
    ]

    for url in endpoints:
        cmd = ["az", "rest", "--method", "get", "--url", url, "--output", "json"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout)
                catalogs = data.get("value", [])
                print(f"📡 Reponse reussie depuis {url} ({len(catalogs)} catalogues trouves)")
                return catalogs
            else:
                err_snippet = result.stderr.strip() if result.stderr else "code non-zero"
                print(f"ℹ️ Endpoint {url} : {err_snippet[:120]}...", file=sys.stderr)
        except Exception as e:
            print(f"ℹ️ Exception sur {url} : {e}", file=sys.stderr)

    print("⚠️ Aucun endpoint Graph API n'a renvoye de donnees de catalogues.", file=sys.stderr)
    return []


def load_yaml_declarations(declarations_dir: str) -> dict:
    """Charge toutes les declarations d'applications YAML."""
    apps = {}
    if not os.path.isdir(declarations_dir):
        return apps

    for fname in os.listdir(declarations_dir):
        if fname.endswith(".yaml") or fname.endswith(".yml"):
            if fname.startswith("_"):
                continue
            fpath = os.path.join(declarations_dir, fname)
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    content = yaml.safe_load(f)
                    if content and isinstance(content, dict):
                        app_name = content.get("application_name")
                        if app_name:
                            apps[app_name] = content
            except Exception as e:
                print(f"⚠️ Erreur de lecture de {fname} : {e}", file=sys.stderr)

    return apps


def main():
    parser = argparse.ArgumentParser(description="Smart Discovery des catalogues Entra ID")
    parser.add_argument("--declarations-dir", required=True, help="Dossier declarations/apps")
    parser.add_argument("--output-file", required=True, help="Fichier JSON de sortie pour Terraform")
    args = parser.parse_args()

    print("====================================================")
    print("🔎 SMART DISCOVERY — Inventaire des catalogues Entra ID")
    print("====================================================")

    # 1. Recuperer les catalogues du tenant Entra ID
    entraid_catalogs = get_entraid_catalogs()
    print(f"📊 Catalogues recenses dans le tenant Entra ID : {len(entraid_catalogs)}")

    # Indexer par nom en minuscules pour comparaison insensible a la casse
    catalog_by_name = {}
    for c in entraid_catalogs:
        dname = c.get("displayName", "").strip()
        if dname:
            catalog_by_name[dname.lower()] = c

    # 2. Charger les YAMLs declares
    apps = load_yaml_declarations(args.declarations_dir)
    print(f"📄 Applications declarees dans le repo : {len(apps)}")
    print("----------------------------------------------------")

    discovered = {}
    summary_lines = [
        "### 🔎 Statut des catalogues (Smart Discovery)",
        ""
    ]

    for app_name, app_data in apps.items():
        catalog_cfg = app_data.get("catalog", {})
        target_name = str(catalog_cfg.get("display_name", "")).strip()
        target_id = str(catalog_cfg.get("id", "")).strip()

        matched = None

        # Priorite 1 : Recherche par ID explicite
        if target_id:
            for c in entraid_catalogs:
                if c.get("id", "").lower() == target_id.lower():
                    matched = c
                    break

        # Priorite 2 : Recherche par display_name insensible a la casse
        if not matched and target_name:
            matched = catalog_by_name.get(target_name.lower())

        if matched:
            cat_id = matched.get("id")
            actual_name = matched.get("displayName")
            discovered[app_name] = {
                "exists": True,
                "id": cat_id,
                "display_name": actual_name,
                "status": "found_in_entraid"
            }
            print(f"  ✅ [{app_name}] Catalogue '{actual_name}' trouve dans Entra ID")
            print(f"     -> Mode Consommateur actif (ID: {cat_id})")
            summary_lines.append(f"- 📦 **{actual_name}** : Déjà existant dans Entra ID (Mode Consommateur, ID: `{cat_id}`)")
        else:
            discovered[app_name] = {
                "exists": False,
                "id": None,
                "display_name": target_name,
                "status": "not_found"
            }
            print(f"  🆕 [{app_name}] Catalogue '{target_name}' non trouve dans Entra ID")
            print(f"     -> Mode Creation actif (Terraform va le creer)")
            summary_lines.append(f"- 🆕 **{target_name}** : Absent d'Entra ID (sera créé par Terraform)")

    print("----------------------------------------------------")

    # 3. Ecrire le fichier JSON pour Terraform
    out_dir = os.path.dirname(args.output_file)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(args.output_file, "w", encoding="utf-8") as f:
        json.dump(discovered, f, indent=2)

    # 4. Ecrire le fichier Markdown de resume
    summary_file = os.path.join(out_dir if out_dir else ".", "discovered_summary.md")
    with open(summary_file, "w", encoding="utf-8") as f:
        f.write("\n".join(summary_lines) + "\n\n")

    print(f"💾 Fichier JSON genere : {args.output_file}")
    print(f"📝 Resume Markdown genere : {summary_file}")
    print("====================================================\n")


if __name__ == "__main__":
    main()