#!/usr/bin/env python3
"""
cleanup-stale-state.py - Nettoyage automatique des ressources orphelines dans le state Terraform.

Lorsqu'un Access Package ou un catalogue est recréé ou supprimé hors Terraform (ou lors de tests),
Microsoft Graph renvoie une erreur 403 UnAuthorized ou 404 NotFound lorsqu'on interroge les politiques
d'assignation associées à l'ancien objet.
Le provider AzureAD Terraform plante alors lors du refresh initial avant d'exécuter le plan.

Ce script :
1. Liste les ressources d'Entitlement Management dans le State Terraform (`terraform state list`).
2. Interroge Microsoft Graph pour vérifier si la ressource existe toujours.
3. Supprime du State (`terraform state rm`) toute ressource inaccessible afin de permettre à Terraform
   de la recréer proprement lors du plan / apply.
"""

import argparse
import os
import re
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


def get_terraform_state_list(working_dir: str) -> list:
    """Récupère la liste des ressources gérées dans le state Terraform."""
    try:
        res = subprocess.run(
            ["terraform", "state", "list"],
            cwd=working_dir,
            capture_output=True,
            text=True
        )
        if res.returncode == 0 and res.stdout:
            return [line.strip() for line in res.stdout.strip().split("\n") if line.strip()]
    except Exception as e:
        print(f"⚠️ Impossible de lister le state Terraform : {e}", file=sys.stderr)
    return []


def get_resource_id_from_state(resource_name: str, working_dir: str) -> str:
    """Extrait l'ID de la ressource depuis le state Terraform."""
    try:
        res = subprocess.run(
            ["terraform", "state", "show", resource_name],
            cwd=working_dir,
            capture_output=True,
            text=True
        )
        if res.returncode == 0 and res.stdout:
            for line in res.stdout.split("\n"):
                m = re.match(r'^\s*id\s*=\s*"([^"]+)"', line)
                if m:
                    return m.group(1).strip()
    except Exception:
        pass
    return ""


def check_resource_in_graph(resource_type: str, resource_id: str) -> bool:
    """Vérifie si la ressource est accessible dans Microsoft Graph."""
    if resource_type == "policy":
        url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/{resource_id}"
    elif resource_type == "access_package":
        url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/{resource_id}"
    elif resource_type == "catalog":
        url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/{resource_id}"
    else:
        return True

    cmd = ["az", "rest", "--method", "get", "--url", url]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            return True
        
        combined_err = (proc.stdout + " " + proc.stderr).lower()
        if any(err_token in combined_err for err_token in ["unauthorized", "notfound", "resourcenotfound", "403", "404"]):
            return False
    except Exception:
        return True

    return True


def remove_from_state(resource_name: str, working_dir: str):
    """Retire la ressource du state Terraform."""
    print(f"🧹 Suppression de la ressource orpheline du state : {resource_name}")
    try:
        subprocess.run(["terraform", "state", "rm", resource_name], cwd=working_dir, check=False)
    except Exception as e:
        print(f"⚠️ Erreur lors du terraform state rm : {e}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Nettoyage du state Terraform des ressources Entra ID orphelines")
    parser.add_argument("--working-dir", default="terraform", help="Dossier contenant le projet Terraform")
    args = parser.parse_args()

    working_dir = args.working_dir
    if not os.path.isdir(working_dir):
        print(f"Dossier {working_dir} introuvable.")
        sys.exit(0)

    state_resources = get_terraform_state_list(working_dir)
    if not state_resources:
        print("Aucune ressource dans le state Terraform ou state vide.")
        sys.exit(0)

    print(f"🔍 Examen de {len(state_resources)} ressource(s) dans le state Terraform...")

    for res in state_resources:
        if res.startswith("azuread_access_package_assignment_policy."):
            r_id = get_resource_id_from_state(res, working_dir)
            if r_id and not check_resource_in_graph("policy", r_id):
                print(f"⚠️ Politique d'assignation orpheline détectée (ID: {r_id}) -> suppression du state")
                remove_from_state(res, working_dir)

        elif res.startswith("azuread_access_package."):
            r_id = get_resource_id_from_state(res, working_dir)
            if r_id and not check_resource_in_graph("access_package", r_id):
                print(f"⚠️ Access Package orphelin détecté (ID: {r_id}) -> suppression du state")
                remove_from_state(res, working_dir)

        elif res.startswith("azuread_access_package_catalog."):
            r_id = get_resource_id_from_state(res, working_dir)
            if r_id and not check_resource_in_graph("catalog", r_id):
                print(f"⚠️ Catalogue orphelin détecté (ID: {r_id}) -> suppression du state")
                remove_from_state(res, working_dir)

    print("✅ Nettoyage du state Terraform terminé.")


if __name__ == "__main__":
    main()
