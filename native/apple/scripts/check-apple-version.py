#!/usr/bin/env python3
"""Apple-only version check; the unchanged root contract remains a separate merge gate."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
build = (root / 'BUILD_NUMBER').read_text().strip()
project = (root / 'AssignmentApp2.xcodeproj/project.pbxproj').read_text()
assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'invalid Apple version'
assert re.fullmatch(r'[1-9]\d*', build), 'invalid build number'
assert set(re.findall(r'MARKETING_VERSION = ([^;]+);', project)) == {version}, 'Apple target versions differ'
assert set(re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project)) == {build}, 'Apple target builds differ'
assert f'## {version} (build {build})' in (root / 'CHANGELOG.md').read_text(), 'missing Apple changelog entry'
assert 'path = CHANGELOG.md;' in project, 'About must bundle Apple changelog'
if len(sys.argv) == 2:
    import plistlib
    info = plistlib.loads((Path(sys.argv[1]) / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == version
    assert info['CFBundleVersion'] == build
print(f'Apple version={version} build={build}; shared version contract checked separately')
