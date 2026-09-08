#!/usr/bin/env python3
"""Explicit, separate Developer ID and notarization operations. Default is read-only preflight."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

APPLE = Path(__file__).resolve().parents[1]
ROOT = APPLE.parents[1]
FORMAL_ID = 'com.qianmuyan.assignmentapp'

def run(*args, capture=False):
    return subprocess.run([str(x) for x in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout

def verify(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == FORMAL_ID, 'Random/internal identity is not a distribution app'
    run('python3', APPLE / 'scripts/check-apple-version.py', app)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=4', app)
    details = subprocess.run(['codesign', '-dvvv', str(app)], check=True, capture_output=True, text=True).stderr
    assert 'Authority=Developer ID Application:' in details
    assert 'runtime' in details and 'Timestamp=' in details, 'Hardened Runtime and timestamp required'
    data = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], check=True, capture_output=True).stdout
    entitlements = plistlib.loads(data)
    assert entitlements.get('com.apple.security.app-sandbox') is True
    assert not entitlements.get('com.apple.security.get-task-allow', False)
    return info

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['preflight', 'build', 'verify', 'submit', 'status', 'staple'])
    p.add_argument('--identity')
    p.add_argument('--profile', type=Path, help='Optional already-provisioned Developer ID profile for restricted capabilities')
    p.add_argument('--output', type=Path)
    p.add_argument('--app', type=Path)
    p.add_argument('--dmg', type=Path)
    p.add_argument('--keychain-profile')
    p.add_argument('--submission-id')
    p.add_argument('--authorize-signing', action='store_true')
    p.add_argument('--authorize-notarization-upload', action='store_true')
    a = p.parse_args()
    developer = os.environ.get('DEVELOPER_DIR')
    if not developer or not (Path(developer) / 'usr/bin/xcodebuild').exists(): p.error('Set DEVELOPER_DIR to the real Xcode developer directory')
    if a.action in ['preflight', 'build']:
        print(run('xcodebuild', '-version', capture=True))
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True)
        print(identities)
        if not a.identity or not a.identity.startswith('Developer ID Application:') or f'"{a.identity}"' not in identities:
            p.error('A valid, explicitly selected Developer ID Application identity is required; no key is exported')
        if a.profile:
            profile = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', str(a.profile)], check=True, capture_output=True).stdout)
            assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            entitlement = profile['Entitlements']
            assert entitlement.get('com.apple.application-identifier') == profile['TeamIdentifier'][0] + '.' + FORMAL_ID
            assert not entitlement.get('get-task-allow', False)
            assert '(' + profile['TeamIdentifier'][0] + ')' in a.identity
        if a.action == 'preflight': return
        if not a.authorize_signing: p.error('Signing is a separately authorized acceptance/distribution action; pass --authorize-signing only after approval')
        if not a.output or a.output.exists(): p.error('Choose a new output directory')
        status = run('git', '-C', ROOT, 'status', '--porcelain', capture=True)
        assert not status, 'Freeze a clean source commit before a distribution build'
        a.output.mkdir(parents=True)
        archive = a.output / 'AssignmentApp.xcarchive'
        run('xcodebuild', '-project', APPLE / 'AssignmentApp2.xcodeproj', '-scheme', 'AssignmentApp2',
            '-configuration', 'Release', '-destination', 'generic/platform=macOS,variant=Mac Catalyst',
            '-archivePath', archive, '-derivedDataPath', a.output / 'derived', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO',
            'CODE_SIGNING_ALLOWED=NO', 'CLANG_ENABLE_CODE_COVERAGE=NO', 'SKIP_INSTALL=NO',
            'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox', 'archive')
        a.app = a.output / 'Assignment App.app'
        run('ditto', '--norsrc', '--noextattr', '--noqtn', archive / 'Products/Applications/Assignment App.app', a.app)
        if a.profile: run('cp', a.profile, a.app / 'Contents/embedded.provisionprofile')
        run('python3', APPLE / 'scripts/sign-apple-bundle.py', a.app, '--identity', a.identity,
            '--entitlements', APPLE / 'AssignmentApp2/AssignmentApp2.entitlements')
        info = verify(a.app)
        version = info['CFBundleShortVersionString']
        zip_path = a.output / f'Assignment-App-{version}-Catalyst-Release-arm64.zip'
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', a.app, zip_path)
        dmg = a.output / f'Assignment-App-{version}-Catalyst-Release-arm64.dmg'
        dmg_root = a.output / 'dmg-root'
        dmg_root.mkdir()
        run('ditto', '--norsrc', '--noextattr', '--noqtn', a.app, dmg_root / a.app.name)
        (dmg_root / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-volname', f'Assignment App {version}', '-srcfolder', dmg_root, '-format', 'UDZO', dmg)
        run('codesign', '--sign', a.identity, '--timestamp', dmg)
        run('hdiutil', 'verify', dmg)
        record = dict(source_sha=run('git', '-C', ROOT, 'rev-parse', 'HEAD', capture=True).strip(), source_tree='clean',
                      version=version, build=info['CFBundleVersion'], configuration='Release', bundle_id=FORMAL_ID,
                      architecture=run('lipo', '-archs', a.app / 'Contents/MacOS/Assignment App', capture=True).strip(),
                      minimum_system=info['LSMinimumSystemVersion'], sdk=run('xcrun', '--sdk', 'macosx', '--show-sdk-version', capture=True).strip(),
                      xcode=run('xcodebuild', '-version', capture=True).strip(), signing=a.identity,
                      notarization='not-submitted', formal_acceptance='not-executed-by-this-script', tests='see frozen commit test evidence',
                      sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in [zip_path, dmg]})
        (a.output / 'build-info.json').write_text(json.dumps(record, indent=2) + '\n')
    elif a.action == 'verify':
        if not a.app: p.error('--app required')
        verify(a.app)
    elif a.action == 'submit':
        if not a.authorize_notarization_upload: p.error('Explicit upload authorization required independently of acceptance/signing')
        if not a.dmg or not a.keychain_profile or not a.app: p.error('--app, --dmg and --keychain-profile required')
        verify(a.app)
        run('codesign', '--verify', '--strict', a.dmg)
        # Verify the actual disk-image payload before an authorized upload.
        with tempfile.TemporaryDirectory(prefix='assignment-distribution-') as mount:
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, a.dmg)
            try:
                payload = Path(mount) / 'Assignment App.app'
                verify(payload)
                executable = Path('Contents/MacOS/Assignment App')
                assert hashlib.sha256((payload / executable).read_bytes()).digest() == hashlib.sha256((a.app / executable).read_bytes()).digest()
            finally:
                run('hdiutil', 'detach', mount)
        result = json.loads(run('xcrun', 'notarytool', 'submit', a.dmg, '--keychain-profile', a.keychain_profile,
                                '--wait', '--output-format', 'json', capture=True))
        a.dmg.with_suffix('.notary.json').write_text(json.dumps(result, indent=2) + '\n')
        assert result.get('status') == 'Accepted', 'Notarization failed; inspect the submission log, do not staple or distribute'
    elif a.action == 'status':
        if not a.submission_id or not a.keychain_profile: p.error('--submission-id and --keychain-profile required')
        print(run('xcrun', 'notarytool', 'info', a.submission_id, '--keychain-profile', a.keychain_profile, '--output-format', 'json', capture=True))
    elif a.action == 'staple':
        if not a.dmg or not a.app or not a.keychain_profile or not a.submission_id: p.error('--app, --dmg, --submission-id and --keychain-profile required')
        result = json.loads(run('xcrun', 'notarytool', 'info', a.submission_id, '--keychain-profile', a.keychain_profile, '--output-format', 'json', capture=True))
        assert result.get('status') == 'Accepted'
        for artifact in [a.app, a.dmg]:
            run('xcrun', 'stapler', 'staple', artifact)
            run('xcrun', 'stapler', 'validate', artifact)
        verify(a.app)
        run('spctl', '--assess', '--type', 'execute', '--verbose=4', a.app)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', a.dmg)
        stapled_zip = a.dmg.with_name(a.dmg.stem + '-stapled.zip')
        assert not stapled_zip.exists(), 'Do not overwrite a previous distribution artifact'
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', a.app, stapled_zip)
        record = dict(notarization='Accepted', submission_id=a.submission_id, stapling='validated', gatekeeper='passed',
                      sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in [a.dmg, stapled_zip]},
                      note='Final hashes supersede pre-staple build-info hashes; retain both records')
        a.dmg.with_suffix('.distribution-status.json').write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record, indent=2))

if __name__ == '__main__': main()
