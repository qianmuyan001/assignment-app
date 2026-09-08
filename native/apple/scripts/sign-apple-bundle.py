#!/usr/bin/env python3
"""Sign nested code inside-out; --deep is used only for verification, never signing."""
import argparse
from pathlib import Path
import subprocess
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('app', type=Path)
p.add_argument('--identity', default='-')
p.add_argument('--entitlements', required=True, type=Path)
a = p.parse_args()
if a.identity != '-' and not a.identity.startswith('Developer ID Application:'):
    p.error('Use an explicit Developer ID Application identity, or - for internal ad-hoc')
app = a.app.resolve()
assert app.suffix == '.app' and (app / 'Contents/Info.plist').is_file()
magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
code = []
for path in app.rglob('*'):
    if path.is_symlink():
        assert path.resolve().is_relative_to(app), 'Code symlink escapes bundle'
        continue
    if path.is_dir() and path.suffix in {'.framework', '.app', '.xpc', '.appex', '.bundle'}:
        code.append(path)
    elif path.is_file() and path.parent != app / 'Contents/MacOS':
        with path.open('rb') as f:
            if f.read(4) in magic: code.append(path)
for path in sorted(set(code), key=lambda x: (-len(x.parts), str(x))) + [app]:
    command = ['codesign', '--force', '--sign', a.identity, '--options', 'runtime']
    command += ['--timestamp'] if a.identity != '-' else ['--timestamp=none']
    if path == app or path.suffix in {'.app', '.xpc', '.appex'}:
        command += ['--entitlements', str(a.entitlements)]
    subprocess.run(command + [str(path)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)
