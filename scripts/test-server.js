const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = process.env.PORT || 8080;
const ROOT_DIR = path.resolve(__dirname, '..');
const APPS_DIR = path.join(ROOT_DIR, 'declarations', 'apps');
const SCHEMA_PATH = path.join(ROOT_DIR, 'schemas', 'app-declaration.schema.json');

// --- Helper Functions ---
function getAppFiles() {
  if (!fs.existsSync(APPS_DIR)) return [];
  return fs.readdirSync(APPS_DIR)
    .filter(f => f.endsWith('.yaml') || f.endsWith('.yml'))
    .map(f => ({
      filename: f,
      name: path.basename(f, path.extname(f)),
      isExample: f.startsWith('_'),
      content: fs.readFileSync(path.join(APPS_DIR, f), 'utf8')
    }));
}

function basicYamlValidate(yamlText, filename = '') {
  const errors = [];
  const lines = yamlText.split('\n');

  // Check key fields via regex / basic parsing
  const hasAppName = /^application_name:\s*"([^"]+)"/m.exec(yamlText);
  const hasOwner = /^owner:\s*"([^"]+)"/m.exec(yamlText);
  const hasCatalog = /catalog:/m.test(yamlText);
  const hasResources = /resources:/m.test(yamlText);
  const hasAccessPackages = /access_packages:/m.test(yamlText);

  if (!hasAppName) {
    errors.push("Champ obligatoire manquant : 'application_name'");
  } else {
    const appName = hasAppName[1];
    if (!/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(appName)) {
      errors.push(`Format application_name invalide ('${appName}'). Doit être en kebab-case.`);
    }
    if (filename && !filename.startsWith('_') && path.basename(filename, path.extname(filename)) !== appName) {
      errors.push(`Incohérence : le nom du fichier ('${filename}') ne correspond pas à application_name ('${appName}').`);
    }
  }

  if (!hasOwner) errors.push("Champ obligatoire manquant : 'owner'");
  if (!hasCatalog) errors.push("Section obligatoire manquante : 'catalog'");
  if (!hasResources) errors.push("Section obligatoire manquante : 'resources'");
  if (!hasAccessPackages) errors.push("Section obligatoire manquante : 'access_packages'");

  return {
    valid: errors.length === 0,
    errors,
    appName: hasAppName ? hasAppName[1] : null
  };
}

// --- HTML Template for Dashboard ---
function renderDashboardHTML() {
  const apps = getAppFiles();
  return `<!DOCTYPE html>
<html lang="fr" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Ardian — Entitlement Management Local Test Server</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
  <style>
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; }
  </style>
</head>
<body class="bg-slate-900 text-slate-100 min-h-screen">
  <!-- Header -->
  <header class="bg-slate-800 border-b border-slate-700 px-6 py-4 flex items-center justify-between">
    <div class="flex items-center space-x-3">
      <div class="bg-blue-600 text-white p-2 rounded-lg font-bold">
        <i class="fa-solid fa-shield-halved text-xl"></i>
      </div>
      <div>
        <h1 class="text-xl font-bold tracking-tight text-white">Ardian Entitlement Management</h1>
        <p class="text-xs text-slate-400">Serveur de Test Local & Validation GitOps Entra ID</p>
      </div>
    </div>
    <div class="flex items-center space-x-3">
      <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-900 text-emerald-300 border border-emerald-700">
        <span class="w-2 h-2 mr-1.5 bg-emerald-400 rounded-full animate-pulse"></span>
        Serveur Actif : http://localhost:${PORT}
      </span>
    </div>
  </header>

  <!-- Main Content -->
  <main class="max-w-7xl mx-auto p-6 grid grid-cols-1 lg:grid-cols-12 gap-6">

    <!-- Left Column: App List & Status -->
    <div class="lg:col-span-4 space-y-6">
      <div class="bg-slate-800 rounded-xl p-5 border border-slate-700 shadow-lg">
        <div class="flex items-center justify-between mb-4">
          <h2 class="font-semibold text-slate-200 flex items-center">
            <i class="fa-solid fa-folder-open text-blue-400 mr-2"></i>
            Applications Déclarées (${apps.length})
          </h2>
          <button onclick="newYaml()" class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-1.5 rounded-md font-medium transition">
            <i class="fa-solid fa-plus mr-1"></i> Nouveau
          </button>
        </div>
        <div class="space-y-2 max-h-[400px] overflow-y-auto pr-1">
          ${apps.map(app => `
            <div onclick="loadApp('${app.name}')" class="p-3 bg-slate-900 hover:bg-slate-750 border border-slate-700/60 rounded-lg cursor-pointer transition flex items-center justify-between group">
              <div>
                <span class="text-sm font-medium text-slate-200 group-hover:text-blue-400 transition">${app.name}</span>
                <span class="block text-xs text-slate-500">${app.filename}</span>
              </div>
              <span class="text-xs px-2 py-0.5 rounded ${app.isExample ? 'bg-amber-900/60 text-amber-300 border border-amber-700/50' : 'bg-blue-900/60 text-blue-300 border border-blue-700/50'}">
                ${app.isExample ? 'Exemple' : 'App'}
              </span>
            </div>
          `).join('')}
        </div>
      </div>

      <!-- Quick Controls -->
      <div class="bg-slate-800 rounded-xl p-5 border border-slate-700 shadow-lg space-y-3">
        <h3 class="font-semibold text-slate-200 text-sm">Contrôles du Lab</h3>
        <div class="space-y-2">
          <button onclick="runValidation()" class="w-full bg-slate-700 hover:bg-slate-600 text-slate-200 text-xs py-2 px-3 rounded-lg font-medium flex items-center justify-center transition border border-slate-600">
            <i class="fa-solid fa-check-double text-emerald-400 mr-2"></i> Valider la syntaxe du YAML actif
          </button>
          <button onclick="viewTerraform()" class="w-full bg-slate-700 hover:bg-slate-600 text-slate-200 text-xs py-2 px-3 rounded-lg font-medium flex items-center justify-center transition border border-slate-600">
            <i class="fa-solid fa-cubes text-purple-400 mr-2"></i> Inspecter la structure Terraform IaC
          </button>
        </div>
      </div>
    </div>

    <!-- Right Column: Editor & Validation Results -->
    <div class="lg:col-span-8 space-y-6">
      <div class="bg-slate-800 rounded-xl border border-slate-700 shadow-lg overflow-hidden flex flex-col h-[580px]">
        <div class="bg-slate-750 px-4 py-3 border-b border-slate-700 flex items-center justify-between">
          <span id="editor-title" class="text-sm font-medium text-slate-300">Éditeur YAML Déclaratif</span>
          <div class="flex items-center space-x-2">
            <button onclick="saveYaml()" class="bg-emerald-600 hover:bg-emerald-500 text-white text-xs px-3 py-1.5 rounded-md font-medium transition flex items-center">
              <i class="fa-solid fa-floppy-disk mr-1.5"></i> Enregistrer
            </button>
          </div>
        </div>
        <div class="flex-1 relative">
          <textarea id="yaml-editor" class="w-full h-full bg-slate-950 text-slate-200 font-mono text-xs p-4 focus:outline-none resize-none" spellcheck="false" placeholder="Collez votre contenu YAML déclaratif ici..."></textarea>
        </div>
      </div>

      <!-- Validation Output Box -->
      <div id="result-box" class="hidden bg-slate-800 rounded-xl p-4 border border-slate-700 shadow-lg">
        <h3 id="result-title" class="font-bold text-sm mb-2"></h3>
        <div id="result-content" class="text-xs font-mono space-y-1"></div>
      </div>
    </div>

  </main>

  <script>
    const apps = ${JSON.stringify(apps)};

    function loadApp(appName) {
      const app = apps.find(a => a.name === appName);
      if (app) {
        document.getElementById('yaml-editor').value = app.content;
        document.getElementById('editor-title').innerText = 'Fichier : declarations/apps/' + app.filename;
      }
    }

    function newYaml() {
      const template = \`application_name: "nouvelle-app"
owner: "equipe-it@ardian.com"
description: "Description de la nouvelle application"
catalog:
  display_name: "Nouvelle App"
  description: "Catalogue pour la nouvelle application"
  published: true
resources:
  - type: "group"
    display_name: "GRP-APP-NouvelleApp-Users"
access_packages:
  - display_name: "Accès Standard"
    description: "Accès standard"
    resource_roles:
      - resource_display_name: "GRP-APP-NouvelleApp-Users"
        resource_type: "group"
        role: "Member"
    policies:
      - display_name: "Politique par défaut"
        requestor:
          scope_type: "all_members"
        approval:
          required: false
        assignment:
          type: "expiring"
          duration_in_days: 365\`;
      document.getElementById('yaml-editor').value = template;
      document.getElementById('editor-title').innerText = 'Nouveau Fichier YAML';
    }

    async function runValidation() {
      const content = document.getElementById('yaml-editor').value;
      const res = await fetch('/api/validate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ yaml: content })
      });
      const data = await res.json();
      
      const box = document.getElementById('result-box');
      const title = document.getElementById('result-title');
      const out = document.getElementById('result-content');
      box.classList.remove('hidden');

      if (data.valid) {
        title.className = 'font-bold text-sm text-emerald-400';
        title.innerText = '✅ Validation réussie !';
        out.innerHTML = '<p class="text-emerald-300">Le YAML est conforme à la structure requise pour Entra ID Entitlement Management.</p>';
      } else {
        title.className = 'font-bold text-sm text-rose-400';
        title.innerText = '❌ Erreurs de validation détectées :';
        out.innerHTML = data.errors.map(e => '<p class="text-rose-300">• ' + e + '</p>').join('');
      }
    }

    async function saveYaml() {
      const content = document.getElementById('yaml-editor').value;
      const res = await fetch('/api/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ yaml: content })
      });
      const data = await res.json();
      if (data.success) {
        alert('Fichier enregistré avec succès sous : declarations/apps/' + data.filename);
        location.reload();
      } else {
        alert('Erreur : ' + data.error);
      }
    }

    async function viewTerraform() {
      const res = await fetch('/api/terraform/summary');
      const data = await res.json();
      const box = document.getElementById('result-box');
      const title = document.getElementById('result-title');
      const out = document.getElementById('result-content');
      box.classList.remove('hidden');
      title.className = 'font-bold text-sm text-purple-400';
      title.innerText = '📦 Modules Terraform IaC détectés (' + data.files.length + ' fichiers) :';
      out.innerHTML = data.files.map(f => '<p class="text-slate-300">• <strong>' + f.name + '</strong> (' + f.size + ' octets)</p>').join('');
    }

    // Load first app by default
    if (apps.length > 0) loadApp(apps[0].name);
  </script>
</body>
</html>`;
}

// --- Request Handler ---
const server = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url, true);

  // Serve Dashboard HTML
  if (parsedUrl.pathname === '/' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderDashboardHTML());
    return;
  }

  // API: Get app list
  if (parsedUrl.pathname === '/api/apps' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getAppFiles()));
    return;
  }

  // API: Validate YAML
  if (parsedUrl.pathname === '/api/validate' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        const result = basicYamlValidate(payload.yaml || '');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ valid: false, errors: [err.message] }));
      }
    });
    return;
  }

  // API: Save YAML
  if (parsedUrl.pathname === '/api/save' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        const validation = basicYamlValidate(payload.yaml || '');
        if (!validation.valid || !validation.appName) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: false, error: validation.errors.join(', ') }));
          return;
        }

        const filename = `${validation.appName}.yaml`;
        const targetPath = path.join(APPS_DIR, filename);
        fs.writeFileSync(targetPath, payload.yaml, 'utf8');

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, filename, appName: validation.appName }));
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: false, error: err.message }));
      }
    });
    return;
  }

  // API: Terraform Summary
  if (parsedUrl.pathname === '/api/terraform/summary' && req.method === 'GET') {
    const tfDir = path.join(ROOT_DIR, 'terraform');
    let files = [];
    if (fs.existsSync(tfDir)) {
      files = fs.readdirSync(tfDir)
        .filter(f => f.endsWith('.tf'))
        .map(f => ({
          name: f,
          size: fs.statSync(path.join(tfDir, f)).size
        }));
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ files }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

server.listen(PORT, () => {
  console.log(`===========================================================`);
  console.log(`🚀 SERVEUR LOCAL DE TEST — Entitlement Management Ardian`);
  console.log(`===========================================================`);
  console.log(`URL Dashboard : http://localhost:${PORT}`);
  console.log(`Dossier YAML  : ${APPS_DIR}`);
  console.log(`Appuyez sur Ctrl+C pour arrêter le serveur.`);
  console.log(`===========================================================`);
});
