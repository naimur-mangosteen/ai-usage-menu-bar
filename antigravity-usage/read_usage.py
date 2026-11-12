#!/usr/bin/python3
"""Read Antigravity quota by asking the agy CLI for /usage. Credentials remain managed by agy.

Prints {"groups":[{"name","five_hour","seven_day"}]} with percent used, or {"error"}.
Exit 1 is a normal failure. Exit 3 means agy treated /usage as a model turn, so the app must
stop polling: checking usage must never spend the quota it reports.
"""
import json, os, re, shutil, signal, subprocess, sys, tempfile

# Print-mode /usage starts no agent turn from 1.3.1 (reported on 1.3.1 and 1.3.3). Older builds
# were reported to run it as an ordinary task that spent quota, so they are refused.
MIN_VERSION = (1, 3, 1)
HALT = 3

class Halt(RuntimeError): pass

def find_agy():
    # Login items get a minimal PATH, so look in the usual install locations first.
    paths = [os.path.expanduser('~/.local/bin/agy'), '/opt/homebrew/bin/agy', '/usr/local/bin/agy', shutil.which('agy')]
    return next((p for p in paths if p and os.path.isfile(p) and os.access(p, os.X_OK)), None)

def environment():
    env = os.environ.copy()
    env['PATH'] = ':'.join([os.path.expanduser('~/.local/bin'), '/opt/homebrew/bin', '/usr/local/bin', env.get('PATH') or '/usr/bin:/bin:/usr/sbin:/sbin'])
    return env

def parse_version(text):
    match = re.search(r'(\d+)\.(\d+)\.(\d+)', text or '')
    return tuple(int(part) for part in match.groups()) if match else None

CHILD = None   # the running agy, so a timeout or SIGTERM can stop it and anything it started

def kill_child():
    if CHILD and CHILD.poll() is None:
        try: os.killpg(CHILD.pid, signal.SIGKILL)
        except OSError: pass
        CHILD.wait()

def run(exe, args, timeout, cwd):
    """Run agy in its own process group; on timeout kill the whole group, not just agy."""
    global CHILD
    CHILD = subprocess.Popen([exe, *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=environment(), cwd=cwd, start_new_session=True)
    try: out, _ = CHILD.communicate(timeout=timeout)
    except subprocess.TimeoutExpired: kill_child(); raise
    return subprocess.CompletedProcess(CHILD.args, CHILD.returncode, out, None)

def window_kind(bucket):
    """Which window a bucket is. A bucket without a window is the 5-hour one, as other agy readers found."""
    raw = str(bucket.get('window') or '').strip().lower()
    compact = re.sub(r'[\s_-]', '', raw)
    if not raw or 'five' in compact or compact in ('5h', '5hour', '5hours', '300m', '300min'): return 'five_hour'
    if 'week' in compact or compact in ('7d', '7day', '7days', '168h'): return 'seven_day'
    return None

def field(bucket, snake, camel):
    return bucket[snake] if snake in bucket else bucket.get(camel)

def window(bucket):
    fraction = field(bucket, 'remaining_fraction', 'remainingFraction')
    reset = field(bucket, 'reset_time', 'resetTime')
    reset = reset if isinstance(reset, str) and reset else None
    if fraction is None:
        # Proto-style JSON drops zero values, so a missing fraction means nothing is left — but only
        # when the bucket otherwise looks as expected. Without a reset time it is schema drift, not 0.
        if reset is None: raise RuntimeError('Unexpected Antigravity response.')
        fraction = 0
    if isinstance(fraction, bool) or not isinstance(fraction, (int, float)) or not 0 <= fraction <= 1:
        raise RuntimeError('Unexpected usage value.')
    return {'utilization': round((1 - fraction) * 100, 2), 'resets_at': reset}

def nonzero(value):
    if isinstance(value, bool): return value
    if isinstance(value, (int, float)): return value != 0
    if isinstance(value, str):
        try: return float(value) != 0
        except ValueError: return bool(value.strip())
    return False

def turn_evidence(obj):
    """Any sign that agy ran /usage as a model turn: a non-zero turn count or any token count."""
    sections = [obj] + [v for v in obj.values() if isinstance(v, dict)]
    return any(('turn' in k.lower() or 'token' in k.lower()) and nonzero(v)
               for section in sections for k, v in section.items() if not isinstance(v, (dict, list)))

def find_groups(obj):
    for path in (('command', 'data', 'groups'), ('data', 'groups'), ('groups',)):
        node = obj
        for key in path: node = node.get(key) if isinstance(node, dict) else None
        if isinstance(node, list): return node
    return None

TURN_HALT = 'Antigravity ran /usage as a model turn, so automatic checks are paused to protect your quota. Update agy, then choose Check Again.'
UNKNOWN_HALT = ('Antigravity gave an unexpected reply, so automatic checks are paused to protect your quota. '
                'Run agy in Terminal (sign in or agy update), then choose Check Again.')

def summarize(obj):
    """Fails closed: any sign of a model turn halts, and so does a text answer instead of quota groups."""
    if not isinstance(obj, dict): raise Halt(UNKNOWN_HALT)
    if turn_evidence(obj): raise Halt(TURN_HALT)
    groups = find_groups(obj)
    if not groups:
        if nonzero(obj.get('result')): raise Halt(UNKNOWN_HALT)   # an answer, not the /usage panel
        raise RuntimeError('No Antigravity quota returned. Run agy in Terminal to sign in.')
    result = []
    for group in groups:
        if not isinstance(group, dict): continue
        entry = {'name': str(group.get('name') or 'Models'), 'five_hour': None, 'seven_day': None}
        for bucket in group.get('buckets') or []:
            kind = window_kind(bucket) if isinstance(bucket, dict) else None
            if not kind: continue
            current = window(bucket)
            # Several buckets in one window: show the most-used, never hide an exhausted one.
            if entry[kind] is None or current['utilization'] > entry[kind]['utilization']: entry[kind] = current
        result.append(entry)
    if not result: raise RuntimeError('Unexpected Antigravity response.')
    return {'groups': result}

def parse_output(text):
    """The JSON document agy printed, allowing log lines before or after it (pretty-printed or not)."""
    decoder = json.JSONDecoder()
    starts = [0] + [m.start() + 1 for m in re.finditer(r'\n', text)]
    for start in starts:
        if text[start:start + 1] != '{': continue
        try: return decoder.raw_decode(text, start)[0]
        except ValueError: continue
    raise Halt(UNKNOWN_HALT)   # non-JSON output could be a model answer; don't keep calling

def fetch():
    exe = find_agy()
    if not exe: raise RuntimeError('Install Antigravity CLI (agy) and sign in.')
    with tempfile.TemporaryDirectory(prefix='agy-usage-') as workdir:   # keep agy away from any project folder
        try: version = parse_version(run(exe, ['--version'], 20, workdir).stdout.decode('utf-8', 'replace'))
        except subprocess.TimeoutExpired: raise RuntimeError('agy did not respond.')
        if version is None: raise RuntimeError('Could not read the agy version.')
        if version < MIN_VERSION:
            raise RuntimeError('agy %s is too old; run agy update (needs %s or later).' % ('.'.join(map(str, version)), '.'.join(map(str, MIN_VERSION))))
        try: done = run(exe, ['-p', '/usage', '--output-format', 'json', '--log-file', '/dev/null'], 60, workdir)
        except subprocess.TimeoutExpired: raise RuntimeError('Antigravity did not answer. Run agy in Terminal to check sign-in.')
    if len(done.stdout) > 4_000_000: raise Halt(UNKNOWN_HALT)
    text = done.stdout.decode('utf-8', 'replace').strip()
    if not text: raise RuntimeError('Antigravity returned nothing. Run agy in Terminal to check sign-in.')
    return summarize(parse_output(text))

def self_test():
    sample = {'num_turns': 0, 'usage': {'total_tokens': 0}, 'command': {'data': {'groups': [
        {'name': 'Gemini Models', 'buckets': [{'id': 'a', 'remaining_fraction': 0.69, 'reset_time': '2026-11-12T18:00:00Z'},
                                              {'id': 'b', 'window': 'weekly', 'remaining_fraction': 0.28, 'reset_time': '2026-11-16T00:00:00Z'}]},
        {'name': 'Claude and GPT models', 'buckets': [{'id': 'c', 'window': 'weekly', 'reset_time': '2026-11-16T00:00:00Z'}]}]}}}
    out = summarize(sample)['groups']
    assert out[0]['five_hour'] == {'utilization': 31.0, 'resets_at': '2026-11-12T18:00:00Z'}
    assert out[0]['seven_day']['utilization'] == 72.0
    assert out[1]['five_hour'] is None and out[1]['seven_day']['utilization'] == 100.0   # missing fraction = exhausted
    # Fail closed: any turn or token count halts, whatever the field is called or typed as.
    for bad in ({**sample, 'num_turns': 1}, {**sample, 'num_turns': '1'}, {**sample, 'usage': {'total_tokens': 12}},
                {'usage': {'input_tokens': 500, 'output_tokens': 80}, 'result': 'Here is your usage'},
                {'result': 'Here is your usage'}, []):
        try: summarize(bad); raise AssertionError('turn not detected')
        except Halt: pass
    for bad in ({'groups': []}, {'groups': [{'name': 'x', 'buckets': [{'remaining_fraction': 1.5}]}]},
                {'groups': [{'name': 'x', 'buckets': [{'id': 'drifted'}]}]}):
        try: summarize(bad); raise AssertionError('bad payload accepted')
        except Halt: raise AssertionError('wrong error')
        except RuntimeError: pass
    # camelCase keys, and the most-used bucket wins within a window.
    camel = summarize({'groups': [{'name': 'g', 'buckets': [{'remainingFraction': 0.9, 'resetTime': 'r1'}, {'remaining_fraction': 0.1, 'reset_time': 'r2'}]}]})
    assert camel['groups'][0]['five_hour'] == {'utilization': 90.0, 'resets_at': 'r2'}
    assert window_kind({'window': '5-hour'}) == 'five_hour' and window_kind({'window': 'Weekly'}) == 'seven_day' and window_kind({'window': 'monthly'}) is None
    assert parse_version('agy 1.3.3 (abc)') == (1, 3, 3) and parse_version('dev') is None and (1, 2, 9) < MIN_VERSION <= (1, 3, 1)
    assert parse_output('log line\n{"groups":[]}') == {'groups': []}
    assert parse_output('{\n "groups": [\n  1\n ]\n}\nlog: done') == {'groups': [1]}
    try: parse_output('Sure! Your usage is fine.'); raise AssertionError('text accepted')
    except Halt: pass

if __name__ == '__main__':
    if '--self-test' in sys.argv:
        self_test(); print('ok'); sys.exit(0)
    def stop(signum, frame):   # the app's watchdog sends SIGTERM; take agy down with us
        kill_child(); print(json.dumps({'error': 'Antigravity usage check timed out.'})); os._exit(1)
    signal.signal(signal.SIGTERM, stop)
    try: print(json.dumps(fetch()))
    except Halt as e: print(json.dumps({'error': str(e)})); sys.exit(HALT)
    except RuntimeError as e: print(json.dumps({'error': str(e)})); sys.exit(1)
    except Exception: print(json.dumps({'error': 'Could not read Antigravity usage.'})); sys.exit(1)
