#!/usr/bin/env python3
"""Exercise the real installer awk and replacement gate against synthetic state. Never install."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
source = (repo / 'build.sh').read_text()
program = source.split('  awk -v age="$age" \'', 1)[1].split("\n  ' \"$log\"", 1)[0]
passed = 0

def check(log, age, expected):
    global passed
    actual = subprocess.run(['awk', '-v', f'age={age}', program], input=log, text=True, capture_output=True, check=True).stdout.strip()
    assert actual == expected, (log, age, actual, expected)
    passed += 1

recording = 't meeting: recording, mic test\n'
stopped = recording + 't meeting: stopped, me 10s\n'
check(recording, 1000, 'meeting notes')
check(recording + 't meeting: summary from 1 pieces\n', 0, 'meeting notes')
check(recording + 't meeting: summary failed (synthetic)\n', 0, 'meeting notes')
check(stopped + recording + 't meeting: notes saved, summary apple\n', 0, 'meeting notes')
for age in (121, 300, 359):
    check(stopped, age, 'a meeting summary')
check(stopped, 360, '')
check(stopped + 't meeting: notes saved, summary claude\n', 0, '')
check('t recording from synthetic\n', 119, 'a dictation')
check('t recording from synthetic\n', 120, '')
check(recording + 't launched 0.12.2 (14)\n', 0, '')
check(stopped + 't meeting: could not start\n', 1, 'a meeting summary')
check(recording + 't dictation 3s, 7 words\n', 1, 'meeting notes')

# Execute only the exact final gate, with voice_busy stubbed. rm/cp would be markers in a private temp folder.
gate = source.split('# Signing and the earlier wait take time.', 1)[1].split('rm -rf ~/Applications/', 1)[0]
with tempfile.TemporaryDirectory(prefix='voice-install-guard-') as temp:
    for busy, override, should_copy in [('meeting notes', '', False), ('a meeting summary', '', False), ('', '', True), ('meeting notes', '1', True)]:
        script = 'voice_busy() { print -r -- "$SYNTHETIC_BUSY"; }\n' + gate + '\nprint -r -- COPY_MARKER\n'
        result = subprocess.run(['zsh', '-c', script], env={'PATH': '/usr/bin:/bin', 'SYNTHETIC_BUSY': busy, 'REDPEN_INSTALL_WHILE_RECORDING': override}, text=True, capture_output=True, check=True, cwd=temp)
        assert ('COPY_MARKER' in result.stdout) == should_copy, result.stdout
        passed += 1
assert source.index('[[ -n "$REDPEN_SKIP_INSTALL" ]] && exit 0') < source.index('voice_busy()')
passed += 1
print(f'{passed} installer checks passed')
