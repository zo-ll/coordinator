import json
import os
from pathlib import Path
import subprocess
import tempfile


SCRIPT = Path(__file__).with_name('check-aborted.sh').resolve()

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    fixtures = {
        '%1': 'Error: Retry failed after 3 attempts\n── Working ──',
        '%2': '• Working (2s)\nError: rate_limit_exceeded\nAborted after 3 retry attempts\n>',
        '%3': 'Error: rate_limit_exceeded\nRetrying in 10 seconds',
        '%4': 'Completed assignment.\n>',
        '%5': '$ echo "Aborted after 3 retry attempts"\n>',
        '%6': '── Thinking ──',
    }
    (root / 'fixtures.json').write_text(json.dumps(fixtures))
    fake = root / 'tmux'
    fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['ABORT_TEST_ROOT'])
arguments = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as output:
    output.write(json.dumps(arguments) + '\\n')
if arguments[0] == 'list-panes':
    if arguments[arguments.index('-t') + 1] == 'missing':
        sys.exit(1)
    print('%0|coordinator|pi')
    for number in range(1, 7):
        print(f'%{number}|worker{number}|pi')
    print('%7|shell|bash')
    if (root / 'capture-error').exists():
        print('%8|critic|pi')
elif arguments[0] == 'capture-pane':
    pane = arguments[arguments.index('-t') + 1]
    if pane == '%8':
        sys.exit(1)
    print(json.loads((root / 'fixtures.json').read_text())[pane])
else:
    sys.exit(99)
''')
    fake.chmod(0o755)
    environment = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                       ABORT_TEST_ROOT=str(root))

    def run(*arguments):
        return subprocess.run(['bash', str(SCRIPT), *arguments], env=environment,
                              text=True, capture_output=True, timeout=5)

    result = run('personal')
    assert result.returncode == 0, result.stderr
    assert [line.split('\t')[-1] for line in result.stdout.splitlines()] == [
        'working', 'aborted-at-idle', 'retry-wait', 'idle-ok', 'idle-ok', 'working']
    (root / 'capture-error').touch()
    result = run('personal')
    assert result.returncode == 1
    assert '%8\tcritic\tcapture-error' in result.stdout
    assert run('missing').returncode == 1
    assert run().returncode == 2
    calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
    assert all(call[0] in ('list-panes', 'capture-pane') for call in calls)
    assert not any('%0' in call or '%7' in call for call in calls)
    print('PASS: working/abort/retry/idle cues, cue ordering, quoted command exclusion, '
          'coordinator/shell exclusion, capture/session failures, usage, read-only calls')
