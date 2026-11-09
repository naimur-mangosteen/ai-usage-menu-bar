#!/usr/bin/python3
"""Ask Claude Code to renew its own login. Never read credentials or send a prompt."""
import json,os,selectors,shutil,subprocess,time
from pathlib import Path

def renew():
    candidates=[Path.home()/'.local/bin/claude',Path('/opt/homebrew/bin/claude'),Path('/usr/local/bin/claude')]
    # fnm installs are stable under node-versions; ephemeral multishell links are avoided.
    candidates+=sorted((Path.home()/'.local/share/fnm/node-versions').glob('*/installation/bin/claude'),key=lambda p:p.stat().st_mtime,reverse=True)
    if shutil.which('claude'):candidates.append(Path(shutil.which('claude')))
    exe=next((p.resolve() for p in candidates if p.is_file() and os.access(p,os.X_OK)),None)
    if exe is None:return False
    args=[str(exe),'-p','--input-format','stream-json','--output-format','stream-json','--verbose',
          '--no-session-persistence','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--setting-sources','']
    env=os.environ.copy()
    for key in ['CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_API_KEY']:
        env.pop(key,None)
    env['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC']='1'
    p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,cwd='/private/tmp',env=env)
    selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ)
    try:
        p.stdin.write(json.dumps({'type':'control_request','request_id':'usage-renew','request':{'subtype':'initialize'}}).encode()+b'\n');p.stdin.flush()
        deadline=time.monotonic()+45;buffer=b''
        while time.monotonic()<deadline:
            if not selector.select(max(0,deadline-time.monotonic())):break
            data=os.read(p.stdout.fileno(),65536)
            if not data:break
            buffer+=data
            if len(buffer)>4_000_000:return False
            while b'\n' in buffer:
                raw,buffer=buffer.split(b'\n',1)
                try:msg=json.loads(raw)
                except ValueError:continue
                response=msg.get('response',{})
                if msg.get('type')=='control_response' and response.get('request_id')=='usage-renew':
                    return response.get('subtype')=='success'
        return False
    finally:
        selector.close();p.terminate()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.kill();p.wait()
if __name__=='__main__':
    try:ok=renew()
    except Exception:ok=False
    print('renewal initialization completed' if ok else 'renewal unavailable')
    raise SystemExit(0 if ok else 1)
