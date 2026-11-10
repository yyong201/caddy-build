import subprocess, tarfile, os

IMG = 'yyong201/caddy2-alpine:v2.11.9'
MODS = ['dns.providers.alidns', 'dns.providers.tencentcloud', 'dns.providers.cloudflare',
        'http.handlers.forward_proxy', 'security', 'http.handlers.webdav', 'layer4',
        'caddy.listeners.layer4']

def run(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

for plat, name in (('linux/arm64', 'arm64'), ('linux/arm/v7', 'armv7')):
    print('===', plat)
    run('docker rm -f verify-tmp')
    r = run('docker create --platform %s --name verify-tmp %s' % (plat, IMG))
    if r.returncode != 0:
        print('  create failed:', r.stderr.strip()[:150]); continue
    tar_path = '/tmp/rootfs-%s.tar' % name
    with open(tar_path, 'wb') as f:
        subprocess.run('docker export verify-tmp', shell=True, stdout=f, stderr=subprocess.DEVNULL)
    run('docker rm -f verify-tmp')
    data = None
    with tarfile.open(tar_path) as t:
        for m in t.getmembers():
            if m.name.endswith('usr/bin/caddy'):
                data = t.extractfile(m).read(); break
    os.remove(tar_path)
    if not data:
        print('  caddy binary not found'); continue
    machine = int.from_bytes(data[18:20], 'little')
    print('  binary size: %.1f MB, e_machine=%d (%s)' % (
        len(data)/1048576, machine,
        {0x3e: 'x86-64', 0xb7: 'AArch64', 0x28: 'ARM'}.get(machine, '?')))
    for mod in MODS:
        print('   %-32s %s' % (mod, 'OK' if mod.encode() in data else 'MISSING'))
