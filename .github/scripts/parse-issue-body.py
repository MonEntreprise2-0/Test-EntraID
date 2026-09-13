#!/usr/bin/env python3
"""
parse-issue-body.py - Extrait les champs structures des formulaires d'Issues GitHub.

Supporte les 3 formulaires dedies :
  1. Creation (01-create-access-package.yml)
  2. Modification (02-modify-access-package.yml)
  3. Suppression (03-delete-access-package.yml)

Gere automatiquement :
  - Le glisser-deposer de fichier YAML (telechargement de la piece jointe GitHub)
  - Le copier-coller de code YAML brut ou bloc markdown
  - La detection automatique de l'operation (creation, modification, suppression)
"""

import argparse
import os
import re
import sys
import urllib.request


def parse_issue_body(body: str) -> dict:
    """Decoupe le corps de l'issue en dictionnaire cle -> contenu."""
    sections = {}
    current_section = None
    current_content = []

    for line in body.split("\n"):
        header_match = re.match(r"^###\s+(.+)$", line.strip())
        if header_match:
            if current_section is not None:
                sections[current_section] = "\n".join(current_content).strip()
            current_section = header_match.group(1).strip()
            current_content = []
        else:
            current_content.append(line)

    if current_section is not None:
        sections[current_section] = "\n".join(current_content).strip()

    return sections


def extract_yaml_content(raw_content: str) -> str:
    """Extrait le contenu YAML : soit depuis une URL de fichier joint,
    soit depuis un bloc Markdown ```yaml, soit du texte brut.
    """
    # 1. Verification si un fichier a ete glisse-depose (URL GitHub attachment)
    url_match = re.search(r"https://github\.com/[^\s\)\"\'>]+", raw_content)
    if url_match:
        file_url = url_match.group(0)
        print(f"📥 Fichier joint detecte : {file_url}")
        try:
            req = urllib.request.Request(file_url, headers={"User-Agent": "GitHub-Actions-CI"})
            with urllib.request.urlopen(req, timeout=15) as response:
                content = response.read().decode("utf-8")
                if content.strip():
                    print("✅ Fichier YAML telecharge avec succes depuis la piece jointe.")
                    return content.strip()
        except Exception as e:
            print(f"⚠️ Impossible de telecharger l'URL jointe ({e}), fallback sur le texte brut.", file=sys.stderr)

    # 2. Verification si le contenu est entoure de balises ```yaml
    fence_match = re.search(r"```(?:yaml|yml)?\s*\n(.*?)```", raw_content, re.DOTALL)
    if fence_match:
        return fence_match.group(1).strip()

    # 3. Fallback : contenu brut
    return raw_content.strip()


def validate_app_name(app_name: str) -> bool:
    """Valide la convention kebab-case."""
    return bool(re.match(r"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", app_name))


def extract_app_name_from_path(file_path: str) -> str:
    """Extrait le nom d'application depuis un chemin (ex: declarations/apps/cat-test03.yaml -> cat-test03)."""
    clean_path = file_path.strip().replace("\\", "/")
    basename = os.path.basename(clean_path)
    if basename.endswith(".yaml") or basename.endswith(".yml"):
        basename = os.path.splitext(basename)[0]
    return basename.strip()


def main():
    parser = argparse.ArgumentParser(description="Parse GitHub Issue body")
    parser.add_argument("--body", required=True, help="Issue body Markdown")
    parser.add_argument("--output-dir", required=True, help="Output directory")
    args = parser.parse_args()

    sections = parse_issue_body(args.body)

    # Identifier le type d'operation
    operation = "creation"
    app_name = ""
    yaml_content = ""

    # Cas 3 : Suppression
    if "Application à supprimer" in sections:
        operation = "suppression"
        target_file = sections["Application à supprimer"]
        app_name = extract_app_name_from_path(target_file)
        justification = sections.get("Justification de la suppression", "").strip()

    # Cas 2 : Modification
    elif "Fichier à modifier dans declarations/apps/" in sections:
        operation = "modification"
        target_file = sections["Fichier à modifier dans declarations/apps/"]
        app_name = extract_app_name_from_path(target_file)
        raw_yaml = sections.get("Fichier YAML modifié (Glisser-déposer)", "")
        yaml_content = extract_yaml_content(raw_yaml)
        justification = sections.get("Justification métier", "").strip()

    # Cas 1 : Création (ou template par défaut)
    else:
        operation = "creation"
        app_name = sections.get("Nom de l'application", "").strip()
        raw_yaml = sections.get("Fichier YAML déclaratif (Glisser-déposer)", "")
        if not raw_yaml:
            # Fallback rétro-compatible ancien formulaire
            raw_yaml = sections.get("Contenu YAML", "")
        yaml_content = extract_yaml_content(raw_yaml)
        justification = sections.get("Justification métier", sections.get("Justification", "")).strip()

    # Validations
    if not app_name:
        print("❌ Erreur : Impossible de determiner le nom de l'application.", file=sys.stderr)
        sys.exit(1)

    if not validate_app_name(app_name):
        print(f"❌ Erreur : Le nom '{app_name}' ne respecte pas la convention kebab-case.", file=sys.stderr)
        sys.exit(1)

    if operation != "suppression" and not yaml_content:
        print("❌ Erreur : Le fichier YAML est manquant ou vide. Veuillez glisser-deposer votre fichier .yaml.", file=sys.stderr)
        sys.exit(1)

    # Ecriture des sorties
    os.makedirs(args.output_dir, exist_ok=True)

    with open(os.path.join(args.output_dir, "app_name.txt"), "w", encoding="utf-8") as f:
        f.write(app_name)

    with open(os.path.join(args.output_dir, "operation_type.txt"), "w", encoding="utf-8") as f:
        f.write(operation)

    if operation != "suppression":
        with open(os.path.join(args.output_dir, "app.yaml"), "w", encoding="utf-8") as f:
            f.write(yaml_content + "\n")

    print("========================================")
    print("✅ Issue parsee avec succes :")
    print(f"   Operation   : {operation}")
    print(f"   Application : {app_name}")
    if operation != "suppression":
        print(f"   YAML        : {len(yaml_content)} caracteres")
    print("========================================")

    return 0


if __name__ == "__main__":
    main()