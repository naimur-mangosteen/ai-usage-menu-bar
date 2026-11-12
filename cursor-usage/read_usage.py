#!/usr/bin/python3
"""Read Cursor plan usage with the login the Cursor app already stores.

The access token is read from Cursor's own state database (read-only), sent only to
cursor.com, and never printed, logged or written anywhere. The app never renews it:
when it expires, the menu asks you to open Cursor, which renews it itself.
Prints {"plan","on_demand","resets_at","cycle_start","membership","unlimited"} or {"error"}.
"""
import base64, json, os, signal, sqlite3, sys, time, urllib.error, urllib.parse, urllib.request

DB = os.path.expanduser('~/Library/Application Support/Cursor/User/globalStorage/state.vscdb')
URL = 'https://cursor.com/api/usage-summary'   # undocumented: the endpoint Cursor's own usage dashboard calls

def read_token(path=DB):
    if not os.path.isfile(path): raise RuntimeError('Cursor login not found. Install Cursor and sign in.')
    try:
        con = sqlite3.connect('file:%s?mode=ro' % urllib.parse.quote(path), uri=True, timeout=5)
        try: row = con.execute("SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'").fetchone()
        finally: con.close()
    except sqlite3.Error:
        raise RuntimeError('Could not read the Cursor login. Refresh again in a moment.')
    token = row[0] if row else None
    if isinstance(token, bytes): token = token.decode('utf-8', 'replace')
    token = (token or '').strip()
    if token.startswith('"'):
        try: token = json.loads(token)
        except ValueError: token = ''
    if not token: raise RuntimeError('Not signed in to Cursor. Open Cursor and sign in.')
    return token

def claims(token):
    try:
        part = token.split('.')[1]; part += '=' * (-len(part) % 4)
        data = json.loads(base64.urlsafe_b64decode(part))
        if isinstance(data, dict): return data
    except (IndexError, ValueError): pass
    raise RuntimeError('Unexpected Cursor login format.')

def session_cookie(token, now=None):
    data = claims(token)
    exp = data.get('exp')
    if isinstance(exp, (int, float)) and exp <= (now or time.time()):
        raise RuntimeError('Cursor login expired. Open Cursor to renew it, then Refresh.')
    user = str(data.get('sub') or '').split('|')[-1]
    if not user: raise RuntimeError('Unexpected Cursor login format.')
    return 'WorkosCursorSessionToken=%s%%3A%%3A%s' % (user, token)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None   # never resend the cookie elsewhere

def percent(section):
    """Percent used from used/limit. The ratio is the same whether Cursor counts cents or requests."""
    if not isinstance(section, dict): return None
    used, limit = section.get('used'), section.get('limit')
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) for v in (used, limit)) or limit <= 0: return None
    if used < 0: raise RuntimeError('Unexpected usage value.')
    return round(min(used / limit * 100, 100), 2)

def summarize(obj):
    if not isinstance(obj, dict): raise RuntimeError('Unexpected Cursor response.')
    individual = obj.get('individualUsage') if isinstance(obj.get('individualUsage'), dict) else {}
    unlimited = obj.get('isUnlimited') is True
    plan = percent(individual.get('plan'))
    if plan is None and not unlimited:
        raise RuntimeError('No Cursor plan usage returned. Team-only plans are not supported yet.')
    text = lambda key: obj.get(key) if isinstance(obj.get(key), str) and obj.get(key) else None
    return {'plan': plan, 'on_demand': percent(individual.get('onDemand')), 'resets_at': text('billingCycleEnd'),
            'cycle_start': text('billingCycleStart'), 'membership': text('membershipType'), 'unlimited': unlimited}

def fetch():
    request = urllib.request.Request(URL, headers={'Cookie': session_cookie(read_token()), 'Accept': 'application/json',
                                                   'User-Agent': 'CursorUsageMenuBar/1.0'})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            body = response.read(2_000_001)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308, 401, 403): raise RuntimeError('Cursor did not accept the login. Open Cursor, sign in again, then Refresh.')
        if e.code == 429: raise RuntimeError('Rate limited by Cursor — waiting before retrying.')
        if e.code == 404: raise RuntimeError('Cursor usage endpoint unavailable.')
        raise RuntimeError('Cursor usage service unavailable — retrying automatically.')
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RuntimeError('Could not reach Cursor — check your connection.')
    if len(body) > 2_000_000: raise RuntimeError('Unexpected Cursor response.')
    try: return summarize(json.loads(body))
    except ValueError: raise RuntimeError('Unexpected Cursor response.')

def self_test():
    sample = {'billingCycleStart': '2026-11-01T00:00:00.000Z', 'billingCycleEnd': '2026-12-01T00:00:00.000Z', 'membershipType': 'pro',
              'isUnlimited': False, 'individualUsage': {'plan': {'used': 680, 'limit': 2000, 'remaining': 1320},
                                                        'onDemand': {'used': 0, 'limit': 0}}}
    out = summarize(sample)
    assert out['plan'] == 34.0 and out['on_demand'] is None and out['resets_at'] == '2026-12-01T00:00:00.000Z' and out['membership'] == 'pro'
    assert summarize({**sample, 'individualUsage': {'plan': {'used': 2500, 'limit': 2000}}})['plan'] == 100
    assert summarize({'isUnlimited': True})['plan'] is None
    for bad in ({}, {'individualUsage': {'plan': {'used': -1, 'limit': 10}}}, []):
        try: summarize(bad); raise AssertionError('bad payload accepted')
        except RuntimeError: pass
    # A fake, unsigned token: header.payload.signature with sub and exp.
    body = base64.urlsafe_b64encode(json.dumps({'sub': 'auth0|user_123', 'exp': 2_000_000_000}).encode()).decode().rstrip('=')
    fake = 'e30.%s.sig' % body
    assert session_cookie(fake, now=1_000_000_000) == 'WorkosCursorSessionToken=user_123%3A%3A' + fake
    try: session_cookie(fake, now=2_000_000_001); raise AssertionError('expired token accepted')
    except RuntimeError as e: assert fake not in str(e)
    try: session_cookie('not-a-jwt'); raise AssertionError('bad token accepted')
    except RuntimeError as e: assert 'not-a-jwt' not in str(e)

if __name__ == '__main__':
    if '--self-test' in sys.argv:
        self_test(); print('ok'); sys.exit(0)
    # Overall deadline: urlopen's timeout is per socket read, so a trickling response could run on.
    def expire(signum, frame): raise RuntimeError('Cursor usage check timed out — retrying automatically.')
    signal.signal(signal.SIGALRM, expire); signal.alarm(45)
    try: print(json.dumps(fetch()))
    except RuntimeError as e: print(json.dumps({'error': str(e)})); sys.exit(1)
    except Exception: print(json.dumps({'error': 'Could not read Cursor usage.'})); sys.exit(1)
