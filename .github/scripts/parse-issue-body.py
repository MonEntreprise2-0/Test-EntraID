#!/usr/bin/env python3
"""
parse-issue-body.py - Extrait les champs structures des formulaires d'Issues GitHub.

Supporte les 4 scenarios officiels :
  - Scenario A (User)  : Modification d'une application existante (user_modify)
  - Scenario B (Admin) : Creation d'une nouvelle application avec Team GitHub (admin_create)
  - Scenario C (Admin) : Modification de masse via archive ZIP (admin_bulk)
  - Scenario D (Admin) : Import depuis Entra ID / Reverse Engineering (admin_import)
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
                sections[current_section.lower()] = "\n".join(current_content).strip()
            current_section = header_match.group(1).strip()
            current_content = []
        else:
            current_content.append(line)

    if current_section is not None:
        sections[current_section.lower()] = "\n".join(current_content).strip()

    return sections


def get_section_value(sections: dict, *candidates) -> str:
    """Recherche la premiere valeur non vide correspondant aux cles candidates (insensible a la casse)."""
    for cand in candidates:
        cand_lower = cand.lower()
        for k, v in sections.items():
            if cand_lower in k and v:
                return v.strip()
    return ""


def extract_url(raw_content: str, extension: str = None) -> str:
    """Extrait une URL depuis du texte Markdown (liens ou pieces jointes)."""
    urls = re.findall(r"https://github\.com/[^\s\)\"\'>]+", raw_content)
    if not urls:
        urls = re.findall(r"https://[^\s\)\"\'>]+", raw_content)
    if extension and urls:
        for u in urls:
            if extension in u.lower():
                return u
    return urls[0] if urls else ""


def extract_yaml_content(raw_content: str) -> str:
    """Extrait le contenu YAML : soit depuis un fichier joint, soit bloc markdown, soit texte brut."""
    # 1. Piece jointe YAML GitHub
    yaml_url = extract_url(raw_content, ".yaml") or extract_url(raw_content, ".yml")
    if yaml_url:
        print(f"📥 Fichier YAML joint detecte : {yaml_url}")
        try:
            req = urllib.request.Request(yaml_url, headers={"User-Agent": "GitHub-Actions-CI"})
            with urllib.request.urlopen(req, timeout=15) as response:
                content = response.read().decode("utf-8")
                if content.strip():
                    return content.strip()
        except Exception as e:
            print(f"⚠️ Erreur de telechargement ({e}), repli sur le texte.", file=sys.stderr)

    # 2. Bloc Markdown ```yaml
    fence_match = re.search(r"```(?:yaml|yml)?\s*\n(.*?)```", raw_content, re.DOTALL)
    if fence_match:
        return fence_match.group(1).strip()

    # 3. Texte brut
    return raw_content.strip()


def validate_app_name(app_name: str) -> bool:
    """Valide la convention kebab-case (insensible a la casse pour validation)."""
    return bool(re.match(r"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", app_name.lower()))


def main():
    parser = argparse.ArgumentParser(description="Parse GitHub Issue body")
    parser.add_argument("--body", required=True, help="Issue body Markdown")
    parser.add_argument("--output-dir", required=True, help="Output directory")
    args = parser.parse_args()

    sections = parse_issue_body(args.body)
    os.makedirs(args.output_dir, exist_ok=True)

    operation = "unknown"
    app_name = ""
    yaml_content = ""
    github_team = ""
    zip_url = ""
    target_applications = ""

    # Detection du scenario
    # Scenario C : Modification de masse (ZIP)
    zip_section = get_section_value(sections, "archive zip", "fichier zip", "zip")
    if zip_section:
        operation = "admin_bulk"
        zip_url = extract_url(zip_section)

    # Scenario D : Import depuis Entra ID (Reverse Engineering)
    apps_import_section = get_section_value(sections, "applications à importer", "applications a importer", "noms exacts des applications")
    if apps_import_section and not zip_section:
        operation = "admin_import"
        target_applications = apps_import_section

    # Scenario B : Creation d'application (avec Team GitHub obligatoire)
    team_section = get_section_value(sections, "team github", "équipe github", "equipe github", "propriétaire")
    if team_section and not zip_section and not apps_import_section:
        operation = "admin_create"
        github_team = team_section
        app_name = get_section_value(sections, "nom de l'application", "application_name", "app_name")
        raw_yaml = get_section_value(sections, "fichier yaml", "contenu yaml", "yaml")
        yaml_content = extract_yaml_content(raw_yaml)

    # Scenario A : Modification utilisateur (si aucune des operations speciales ci-dessus)
    if operation == "unknown":
        operation = "user_modify"
        app_name = get_section_value(sections, "nom de l'application", "application_name", "app_name", "application à modifier")
        raw_yaml = get_section_value(sections, "fichier yaml", "contenu yaml", "yaml")
        yaml_content = extract_yaml_content(raw_yaml)

    # Ecriture des fichiers de sortie
    with open(os.path.join(args.output_dir, "operation_type.txt"), "w", encoding="utf-8") as f:
        f.write(operation)

    if app_name:
        with open(os.path.join(args.output_dir, "app_name.txt"), "w", encoding="utf-8") as f:
            f.write(app_name.strip())

    if github_team:
        # Nettoie d'eventuels @ ou URL de team
        cleaned_team = re.sub(r"^@?https?://github\.com/orgs/[^/]+/teams/", "", github_team.strip())
        cleaned_team = cleaned_team.lstrip("@").strip()
        with open(os.path.join(args.output_dir, "github_team.txt"), "w", encoding="utf-8") as f:
            f.write(cleaned_team)

    if yaml_content:
        with open(os.path.join(args.output_dir, "app.yaml"), "w", encoding="utf-8") as f:
            f.write(yaml_content + "\n")

    if zip_url:
        with open(os.path.join(args.output_dir, "zip_url.txt"), "w", encoding="utf-8") as f:
            f.write(zip_url)

    if target_applications:
        with open(os.path.join(args.output_dir, "target_applications.txt"), "w", encoding="utf-8") as f:
            f.write(target_applications)

    print("========================================")
    print("✅ Parsing de l'Issue termine :")
    print(f"   Operation           : {operation}")
    if app_name:
        print(f"   Application         : {app_name}")
    if github_team:
        print(f"   Team GitHub (Owner) : {github_team}")
    if zip_url:
        print(f"   Archive ZIP detectee: {zip_url}")
    if target_applications:
        print(f"   Apps ciblees import : {target_applications}")
    if yaml_content:
        print(f"   YAML                : {len(yaml_content)} octets")
    print("========================================")

    return 0


if __name__ == "__main__":
    main()