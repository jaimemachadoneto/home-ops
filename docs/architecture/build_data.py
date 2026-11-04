#!/usr/bin/env python3
"""Scan kubernetes/apps and hosts/ai; write data.json for the architecture page."""
import json, glob, re, os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
os.chdir(ROOT)
DESC = json.load(open('docs/architecture/descriptions.json'))
INFRA = {  # id: (label, group, note, evidence path, line)
 'nas': ('NAS (NFS + MinIO)', 'storage', 'NFS shares /mnt/Data1, MinIO S3 for Postgres backups', 'kubernetes/apps/downloads/sonarr/app/helmrelease.yaml', 117),
 'ceph': ('Rook Ceph', 'storage', 'ceph-block PVCs', 'kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml', 4),
 'openebs': ('OpenEBS hostpath', 'storage', 'Local disk volumes', 'kubernetes/apps/openebs/openebs/app/helmrelease.yaml', 34),
 'volsync': ('VolSync + Kopia', 'storage', 'Hourly PVC snapshots to a Kopia repo on the NAS', 'kubernetes/components/volsync/replicationsource.yaml', 8),
 'postgres': ('CloudNativePG', 'data', 'postgres16, 2 instances', 'kubernetes/apps/database/cloudnative-pg/cluster/cluster16.yaml', 4),
 'dragonfly': ('Dragonfly', 'data', 'Redis-compatible cache, 3 replicas', 'kubernetes/apps/database/dragonfly/cluster/cluster.yaml', 4),
 'litellm': ('LiteLLM', 'ai', 'Model and MCP gateway', 'kubernetes/apps/ai/litellm/app/litellmproxy.yaml', 4),
 'aihost': ('AI host (3 GPUs)', 'ai', 'Off-cluster Docker host: Ollama, TEI, speech', 'hosts/ai/README.md', 3),
 'igpu': ('Intel GPU (DRA)', 'ai', 'Claimed by Frigate only', 'kubernetes/components/gpu/resourceclaimtemplate.yaml', 1),
 'eso': ('External Secrets', 'platform', '1Password-backed secrets', 'kubernetes/apps/external-secrets/kustomization.yaml', 11),
 'route': ('Gateways (Envoy/nginx)', 'platform', 'HTTPRoutes behind cloudflared and Authentik', 'kubernetes/apps/network/cloudflared/app/helmrelease.yaml', 18),
 'keda': ('KEDA NAS scaler', 'platform', 'Scales apps on an NFS probe', 'kubernetes/components/keda/nas-nfs-scaler/scaledobject.yaml', 20),
}
SHORT = {'nas': 'NAS', 'ceph': 'Ceph', 'openebs': 'OpenEBS', 'volsync': 'VolSync', 'postgres': 'Postgres', 'dragonfly': 'Dragonfly', 'litellm': 'LiteLLM', 'aihost': 'AI host', 'igpu': 'iGPU', 'eso': 'Secrets', 'route': 'Gateway', 'keda': 'KEDA'}
PAT = {'nas': r'nas\.jaimenet\.com', 'ceph': r'ceph-block|ceph-filesystem', 'openebs': r'openebs-hostpath',
 'volsync': r'components/volsync', 'postgres': r'postgres16|postgres-init', 'dragonfly': r'dragonfly\.database',
 'litellm': r'litellm\.ai\.svc|litellm:4000', 'aihost': r'ai\.local|10\.30\.50\.13', 'igpu': r'components/gpu',
 'eso': r'kind: ExternalSecret', 'route': r'kind: HTTPRoute|kind: Ingress|gethomepage\.dev/enabled', 'keda': r'components/keda'}
NS, svcs = [], []
for ks in sorted(glob.glob('kubernetes/apps/*/kustomization.yaml')):
    ns = ks.split('/')[2]; NS.append(ns)
    for i, l in enumerate(open(ks), 1):
        m = re.match(r'\s*(#\s*)?-\s*\./([\w.-]+)/ks\.yaml', l)
        if not m: continue
        n, off = m.group(2), bool(m.group(1))
        uses = {}
        if not off:
            for f in sorted(glob.glob(f'kubernetes/apps/{ns}/{n}/**/*.yaml', recursive=True)):
                for j, line in enumerate(open(f), 1):
                    for k, p in PAT.items():
                        if k not in uses and re.search(p, line): uses[k] = [f, j]
        svcs.append({'ns': ns, 'name': n, 'desc': DESC.get(f'{ns}/{n}', ''), 'off': off,
                     'src': [ks, i], 'uses': uses})
readme = open('hosts/ai/README.md').read().splitlines()
for n in sorted(os.listdir('hosts/ai/stacks')):
    line = next((i for i, l in enumerate(readme, 1) if 15 < i < 34 and (f'`{n}`' in l or f'(`{n}`)' in l)), 3)
    svcs.append({'ns': 'ai-host', 'name': n, 'desc': DESC.get(f'ai-host/{n}', ''), 'off': False,
                 'src': ['hosts/ai/README.md', line], 'uses': {'aihost': ['hosts/ai/README.md', line]}})
NS.append('ai-host')
data = {'repo': 'https://github.com/jaimemachadoneto/home-ops', 'rev': os.popen('git rev-parse HEAD').read().strip(),
        'infra': {k: {'short': SHORT[k], 'label': v[0], 'group': v[1], 'note': v[2], 'src': [v[3], v[4]]} for k, v in INFRA.items()},
        'namespaces': NS, 'services': svcs}
js = json.dumps(data, indent=1, ensure_ascii=False)
open('docs/architecture/data.js', 'w').write('window.DATA = ' + js + ';\n')
from collections import Counter
print(len(svcs), 'services;', Counter(s['ns'] for s in svcs)['ai-host'], 'ai-host stacks')
print('per infra:', dict(Counter(k for s in svcs for k in s['uses'])))
