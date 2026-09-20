#!/usr/bin/env python3
"""
cleanup-stale-state.py - Nettoyage automatique et réconciliation des ressources Entra ID / Terraform.

Fonctionnalités :
1. Détection et suppression proactive des ressources obsolètes (--delete-obsolete) :
   Compare le state Terraform avec les déclarations YAML actuelles.
   Si un Access Package ou une Politique a été supprimé ou renommé, le script le supprime
   directement via Microsoft Graph API (az rest --method delete) puis purge le state Terraform.
   Cela évite le bug connu du provider AzureAD où le polling GET post-suppression
   renvoie un statut HTTP 403 au lieu de 404, ce qui interrompait brutalement Terraform apply.

2. Détection des ressources orphelines (Self-Healing) :
   Vérifie si les politiques, packages ou catalogues présents dans le state existent toujours
   dans Microsoft Graph. Si une ressource renvoie 403 ou 404, elle est immédiatement purgée
   du state (terraform state rm) pour permettre une réconciliation propre.
"""

import argparse
import glob
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


def delete_resource_in_graph(resource_type: str, resource_id: str) -> bool:
    """Supprime une ressource directement via Microsoft Graph API."""
    if resource_type == "policy":
        url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/{resource_id}"
    elif resource_type == "access_package":
        url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/{resource_id}"
    elif resource_type == "catalog":
        url = f"https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/{resource_id}"
    else:
        return True

    cmd = ["az", "rest", "--method", "delete", "--url", url]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            print(f"🗑️ Ressource {resource_type} (ID: {resource_id}) supprimée d'Entra ID.")
            return True
        combined_err = (proc.stdout + " " + proc.stderr).lower()
        if any(err_token in combined_err for err_token in ["notfound", "resourcenotfound", "404"]):
            return True
        print(f"⚠️ az rest delete pour {resource_type} {resource_id} : {proc.stderr.strip()}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"⚠️ Exception lors de la suppression Graph de {resource_id} : {e}", file=sys.stderr)
        return False


def remove_from_state(resource_name: str, working_dir: str):
    """Retire la ressource du state Terraform."""
    print(f"🧹 Suppression de la ressource du state Terraform : {resource_name}")
    try:
        subprocess.run(["terraform", "state", "rm", resource_name], cwd=working_dir, check=False)
    except Exception as e:
        print(f"⚠️ Erreur lors du terraform state rm : {e}", file=sys.stderr)


def get_declared_resources(declarations_dir: str):
    """
    Charge toutes les déclarations YAML et extrait les clés d'Access Packages
    et de Politiques attendues dans Terraform.
    """
    try:
        import yaml
    except ImportError:
        print("⚠️ pyyaml non installé, extraction des déclarations ignorée.", file=sys.stderr)
        return set(), set()

    expected_ap_keys = set()
    expected_policy_keys = set()

    if not os.path.isdir(declarations_dir):
        print(f"⚠️ Dossier de déclarations {declarations_dir} introuvable.", file=sys.stderr)
        return set(), set()

    search_path = os.path.join(declarations_dir, "**", "*.yaml")
    yaml_files = glob.glob(search_path, recursive=True)

    for fpath in yaml_files:
        if os.path.basename(fpath).startswith("_"):
            continue
        try:
            with open(fpath, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            if not data or not isinstance(data, dict):
                continue

            app_name = (
                data.get("app_name")
                or data.get("application_name")
                or os.path.splitext(os.path.basename(fpath))[0]
            ).strip()

            for ap in data.get("access_packages", []):
                if not isinstance(ap, dict):
                    continue

                if ap.get("display_name"):
                    ap_display_name = str(ap["display_name"]).strip()
                else:
                    subapp = str(ap.get("context_subapp", "")).strip()
                    priv = str(ap.get("privilege_level", "")).strip()
                    env = str(ap.get("env", "")).strip()
                    prefix = f"{subapp} " if subapp else ""
                    ap_display_name = f"{prefix}{priv} - {env}".strip()

                ap_key = f"{app_name}|{ap_display_name}"
                expected_ap_keys.add(ap_key)
                expected_policy_keys.add(f"{ap_key}|Politique")

        except Exception as e:
            print(f"⚠️ Erreur lors de la lecture de {fpath}: {e}", file=sys.stderr)

    return expected_ap_keys, expected_policy_keys


def clean_obsolete_resources(state_resources: list, expected_ap_keys: set, expected_policy_keys: set, working_dir: str):
    """
    Identifie et supprime les ressources qui ne sont plus déclarées dans le YAML
    (Access Packages renommés ou supprimés).
    Les supprime d'abord via Microsoft Graph API pour éviter les bugs 403 du provider Terraform,
    puis purge le state Terraform.
    """
    # 1. Associations de packages obsolètes
    for res in state_resources:
        if res.startswith("azuread_access_package_resource_package_association.this"):
            m = re.search(r'\["([^"]+)"\]', res)
            if m:
                key = m.group(1)
                parts = key.split("|")
                if len(parts) >= 2:
                    ap_key = f"{parts[0]}|{parts[1]}"
                    if ap_key not in expected_ap_keys:
                        print(f"🧹 Association obsolète détectée : {key}")
                        remove_from_state(res, working_dir)

    # 2. Politiques d'assignation obsolètes
    for res in state_resources:
        if res.startswith("azuread_access_package_assignment_policy.this"):
            m = re.search(r'\["([^"]+)"\]', res)
            if m:
                policy_key = m.group(1)
                if policy_key not in expected_policy_keys:
                    r_id = get_resource_id_from_state(res, working_dir)
                    print(f"🗑️ Politique obsolète détectée (Key: {policy_key}, ID: {r_id})")
                    if r_id:
                        delete_resource_in_graph("policy", r_id)
                    remove_from_state(res, working_dir)

    # 3. Access Packages obsolètes
    for res in state_resources:
        if res.startswith("azuread_access_package.this"):
            m = re.search(r'\["([^"]+)"\]', res)
            if m:
                ap_key = m.group(1)
                if ap_key not in expected_ap_keys:
                    r_id = get_resource_id_from_state(res, working_dir)
                    print(f"🗑️ Access Package obsolète détecté (Key: {ap_key}, ID: {r_id})")
                    if r_id:
                        delete_resource_in_graph("access_package", r_id)
                    remove_from_state(res, working_dir)


def clean_orphan_resources(working_dir: str):
    """Vérifie si les ressources restantes dans le state existent toujours dans Graph."""
    state_resources = get_terraform_state_list(working_dir)
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


def main():
    parser = argparse.ArgumentParser(description="Nettoyage et réconciliation du state Terraform des ressources Entra ID")
    parser.add_argument("--working-dir", default="terraform", help="Dossier contenant le projet Terraform")
    parser.add_argument("--declarations-dir", default="declaration", help="Dossier contenant les déclarations YAML")
    parser.add_argument("--delete-obsolete", action="store_true", help="Supprime de Graph et purge du state les ressources qui ne sont plus dans les YAML")
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

    # Étape 1 : Réconciliation proactive des ressources supprimées/renommées
    if args.delete_obsolete and args.declarations_dir:
        expected_aps, expected_policies = get_declared_resources(args.declarations_dir)
        if expected_aps:
            print(f"📋 {len(expected_aps)} Access Package(s) attendu(s) d'après les déclarations.")
            clean_obsolete_resources(state_resources, expected_aps, expected_policies, working_dir)

    # Étape 2 : Purge des ressources orphelines (Self-Healing)
    clean_orphan_resources(working_dir)

    print("✅ Nettoyage et réconciliation du state Terraform terminés.")


if __name__ == "__main__":
    main()
