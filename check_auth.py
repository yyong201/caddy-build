import json, os, base64, urllib.request, urllib.error

cfg = json.load(open(os.path.expanduser('~/.docker/config.json')))
auth = cfg['auths']['https://index.docker.io/v1/']['auth']

url = ("https://auth.docker.io/token?service=registry.docker.io"
       "&scope=repository:yyong201/caddy2-alpine:pull,push")
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({'http': 'http://127.0.0.1:18080',
                                 'https': 'http://127.0.0.1:18080'}))
req = urllib.request.Request(url, headers={'Authorization': 'Basic ' + auth})
try:
    body = opener.open(req, timeout=25).read().decode()
except urllib.error.HTTPError as e:
    print('HTTP ERROR', e.code, e.read()[:200])
    raise SystemExit(1)

tok = json.loads(body).get('token', '')
print('token length:', len(tok))
pl = tok.split('.')[1]
pl += '=' * (-len(pl) % 4)
claims = json.loads(base64.urlsafe_b64decode(pl))
acc = claims.get('access') or []
print('granted access:', acc)
print('HAS PUSH:', any('push' in (a.get('actions') or []) for a in acc))
