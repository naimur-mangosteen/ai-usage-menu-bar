#!/usr/bin/python3
"""Read-only Codex RPC bridge. Credentials remain managed by Codex."""
import json, os, selectors, shutil, subprocess, time, sys

def fetch():
    # Login items get a minimal PATH. Prefer the native standalone build; the Homebrew/npm
    # shim is a `#!/usr/bin/env node` script that fails (and used to time out) without node on PATH.
    candidates = [os.path.expanduser('~/.local/bin/codex'), '/opt/homebrew/bin/codex', '/usr/local/bin/codex', shutil.which('codex')]
    exe = next((p for p in candidates if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)
    if not exe: raise RuntimeError('Install Codex CLI and sign in using codex login.')
    env = os.environ.copy()
    env['PATH'] = ':'.join([os.path.expanduser('~/.local/bin'), '/opt/homebrew/bin', '/usr/local/bin', env.get('PATH') or '/usr/bin:/bin:/usr/sbin:/sbin'])
    p = subprocess.Popen([exe, 'app-server', '--listen', 'stdio://'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    selector = selectors.DefaultSelector(); selector.register(p.stdout, selectors.EVENT_READ)
    buffer = b''; deadline = time.monotonic()+35
    def send(value):
        p.stdin.write(json.dumps(value).encode()+b'\n'); p.stdin.flush()
    def receive(wanted):
        nonlocal buffer
        while time.monotonic()<deadline:
            while b'\n' in buffer:
                raw, buffer = buffer.split(b'\n', 1)
                try: response = json.loads(raw)
                except ValueError: continue
                if response.get('id') == wanted:
                    if 'error' in response: raise RuntimeError('Codex usage unavailable. Check Codex sign-in and connection.')
                    return response.get('result', {})
            if not selector.select(max(0,deadline-time.monotonic())): break
            data=os.read(p.stdout.fileno(),65536)
            if not data: break
            buffer+=data
            if len(buffer)>4_000_000: raise RuntimeError('Unexpected Codex response.')
        raise RuntimeError('Codex usage request timed out.')
    try:
        send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'local_usage_menubar','title':'Codex Usage','version':'1.0.0'}}})
        receive(1); send({'method':'initialized','params':{}})
        send({'id':2,'method':'account/rateLimits/read','params':{}})
        result=receive(2)
        bucket=(result.get('rateLimitsByLimitId') or {}).get('codex') or result.get('rateLimits') or {}
        windows=[bucket.get('primary'),bucket.get('secondary')]
        def window(minutes):
            w=next((w for w in windows if w and w.get('windowDurationMins')==minutes),None)
            if not w:return None
            percent=w.get('usedPercent')
            if isinstance(percent,bool) or not isinstance(percent,(int,float)) or not 0<=percent<=100:raise RuntimeError('Unexpected usage value.')
            return {'utilization':percent,'resets_at':str(w['resetsAt']) if w.get('resetsAt') else None}
        if not bucket:raise RuntimeError('No Codex usage limits available. Sign in with your ChatGPT account.')
        return {'five_hour':window(300),'seven_day':window(10080)}
    finally:
        selector.close()
        p.terminate()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.kill();p.wait()
if __name__=='__main__':
    try: print(json.dumps(fetch()))
    except RuntimeError as e: print(json.dumps({'error':str(e)}));sys.exit(1)
    except Exception: print(json.dumps({'error':'Could not read Codex usage.'}));sys.exit(1)
