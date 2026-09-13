#!/usr/bin/env python3
"""
sync-dropdowns.py - Synchronise la liste deroulante des fichiers d'applications
dans les templates d'Issues (02-modify et 03-delete).

Ce script est execute automatiquement par le workflow CD lors d'un merge sur main.
"""

import os
import re
import sys


def get_available_apps(declarations_dir: str) -> list:
    """Retourne la liste des fichiers declarations/apps/<app>.yaml disponibles."""
    apps = []
    if not os.path.isdir(declarations_dir):
        return apps

    for fname in sorted(os.listdir(declarations_dir)):
        if (fname.endswith(".yaml") or fname.endswith(".yml")) and not fname.startswith("_"):
            apps.append(f"declarations/apps/{fname}")

    return apps


def update_template_dropdown(template_path: str, options: list) -> bool:
    """Met a jour la section options: du champ target_file dans un template d'Issue."""
    if not os.path.isfile(template_path):
        return False

    with open(template_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Formatter les options en YAML
    if not options:
        formatted_options = '      options:\n        - "Aucune application disponible"'
    else:
        formatted_options = "      options:\n" + "\n".join(f'        - "{opt}"' for opt in options)

    pattern = r"      options:\n(?:        - [^\n]+\n)+"
    if re.search(pattern, content):
        new_content = re.sub(pattern, formatted_options + "\n", content)
    else:
        # Fallback de remplacement
        pattern_fallback = r"      options:\n(?:        - [^\n]+)+"
        new_content = re.sub(pattern_fallback, formatted_options, content)

    if new_content != content:
        with open(template_path, "w", encoding="utf-8") as f:
            f.write(new_content)
        print(f"✅ Template mis a jour : {os.path.basename(template_path)} ({len(options)} options)")
        return True
    else:
        print(f"ℹ️ Template deja a jour : {os.path.basename(template_path)}")
        return False


def main():
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    declarations_dir = os.path.join(root_dir, "declarations", "apps")
    templates_dir = os.path.join(root_dir, ".github", "ISSUE_TEMPLATE")

    apps = get_available_apps(declarations_dir)
    print(f"📂 Applications decouvertes dans declarations/apps/ : {len(apps)}")
    for a in apps:
        print(f"   - {a}")

    t2 = os.path.join(templates_dir, "02-modify-access-package.yml")
    t3 = os.path.join(templates_dir, "03-delete-access-package.yml")

    update_template_dropdown(t2, apps)
    update_template_dropdown(t3, apps)

    return 0


if __name__ == "__main__":
    sys.exit(main())