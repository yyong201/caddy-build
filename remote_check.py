import json, os, urllib.request, urllib.error

cfg = json.load(open(os.path.expanduser('~/.docker/config.json')))
auth = cfg['auths']['https://index.docker.io/v1/']['auth']
px = {'http': 'http://127.0.0.1:18080', 'https': 'http://127.0.0.1:18080'}
op = urllib.request.build_opener(urllib.request.ProxyHandler(px))

def token(scope):
    u = ("https://auth.docker.io/token?service=registry.docker.io&scope=repository:"
         + scope)
    r = urllib.request.Request(u, headers={'Authorization': 'Basic ' + auth})
    return json.load(op.open(r, timeout=25))['token']

tk = token('yyong201/caddy2-alpine:pull')

def get(path, tok=tk, accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/json'):
    req = urllib.request.Request('https://registry-1.docker.io/v2/' + path,
                                 headers={'Authorization': 'Bearer ' + tok,
                                          'Accept': accept})
    try:
        return op.open(req, timeout=30).read().decode()
    except urllib.error.HTTPError as e:
        return 'HTTP %d %s' % (e.code, e.read()[:200].decode(errors='replace'))

print('TAGS:', get('yyong201/caddy2-alpine/tags/list'))
for t in ('v2.11.9', 'latest'):
    body = get('yyong201/caddy2-alpine/manifests/' + t)
    try:
        idx = json.loads(body)
        ms = idx.get('manifests')
        if ms:
            print(t, '-> index with platforms:', [(m['platform']['os'] + '/' + m['platform']['architecture'], m.get('platform', {}).get('variant')) for m in ms])
        else:
            print(t, '-> single manifest, mediaType', idx.get('mediaType'))
    except Exception:
        print(t, '->', body[:160])
