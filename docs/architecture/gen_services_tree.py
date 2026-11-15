#!/usr/bin/env python3
"""Write the archify tree candidate for services.html from the current services.

Use:
  python3 docs/architecture/gen_services_tree.py candidate.json
  node <archify>/skills/archify/bin/archify.mjs finalize tree candidate.json \
      services.html --quality showcase --json
  cp services.html docs/architecture/services.html

The data comes from build_data.py, the same scan as the explorer page.
"""
import json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DATA = os.path.join(ROOT, 'docs', 'architecture', 'data.js')
out_path = sys.argv[1] if len(sys.argv) > 1 else 'candidate.json'

# build_data.py writes data.js. Keep the file only if it was there before.
existed = os.path.exists(DATA)
subprocess.run([sys.executable, '-I', os.path.join(ROOT, 'docs', 'architecture', 'build_data.py')],
               check=True, stdout=subprocess.DEVNULL)
raw = open(DATA).read()
if not existed:
    os.remove(DATA)
data = json.loads(raw[len('window.DATA = '):].rstrip().rstrip(';'))


def ident(*parts):
    return re.sub(r'[^a-z0-9_]+', '_', '_'.join(parts).lower()).strip('_')


nodes = [{'id': 'root', 'label': 'home-ops', 'sublabel': 'Every service by namespace'}]
by_ns = {}
for s in data['services']:
    by_ns.setdefault(s['ns'], []).append(s)
for ns in data['namespaces']:
    items = by_ns.get(ns, [])
    if not items:
        continue
    host = ns == 'ai-host'
    branch = ident('ns', ns)
    nodes.append({'id': branch, 'label': 'AI host (off-cluster)' if host else ns, 'parent': 'root',
                  'sublabel': 'Docker stacks, 3 GPUs' if host else f'{len(items)} service(s)'})
    for s in items:
        desc = s['desc'] or ''
        if s['off']:
            desc = ('Disabled: ' + desc).strip().rstrip(':')
        node = {'id': ident('svc', ns, s['name']), 'label': s['name'], 'parent': branch}
        if desc:
            node['sublabel'] = desc
        nodes.append(node)

candidate = {'schema_version': 1, 'diagram_type': 'tree',
             'meta': {'title': 'Home-Ops Services by Namespace', 'output': 'services.html',
                      'quality_profile': 'showcase'},
             'layout': {'direction': 'right'}, 'nodes': nodes}
with open(out_path, 'w') as f:
    json.dump(candidate, f, indent=1, ensure_ascii=False)
print(len(nodes), 'nodes ->', out_path)
