#!/usr/bin/env python3
"""Prepare synthetic fixtures now; installation/launch/uninstall require later acceptance authorization.

Never accepts an arbitrary database path. Stable internal identity preserves a container
across versions. Closing the WAL producer leaves its on-disk committed WAL intentionally.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys

APPLE = Path(__file__).resolve().parents[1]
ROOT = APPLE.parents[1]
ID = 'com.qianmuyan.assignmentapp.internal.upgrade'
DATA = Path.home() / f'Library/Containers/{ID}/Data/Library/Application Support/AssignmentApp2'

def run(*args): subprocess.run([str(x) for x in args], check=True)
def fingerprint(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['prepare', 'package', 'install', 'launch', 'seed', 'check', 'uninstall'])
    p.add_argument('--fixture', type=Path)
    p.add_argument('--app', type=Path)
    p.add_argument('--destination', type=Path)
    p.add_argument('--output', type=Path)
    p.add_argument('--authorize-acceptance', action='store_true')
    a = p.parse_args()
    if a.action == 'prepare':
        if not a.fixture or a.fixture.exists(): p.error('Provide a new synthetic fixture directory')
        a.fixture.mkdir(parents=True)
        sql = (ROOT / 'shared/migrations/002_assignment_v2.sql').read_text().replace('assignments_v2_reference', 'assignments')
        database = a.fixture / 'assignments.db'
        # A separate process exits without closing SQLite to preserve committed WAL bytes.
        # This models a killed old client; its OS handles are released before any copying.
        child = '''import os, sqlite3, sys
c=sqlite3.connect(sys.argv[1]); c.executescript(sys.stdin.read()); c.commit()
c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("INSERT INTO assignments(id,course_name,title,description,due_date,status,priority,created_at,updated_at) VALUES (1,?,?,?,?,?,?,?,?)", ('Synthetic / 合成','Upgrade fixture','Description / 描述','2026-11-01 01:30:00','completed','high','2026-08-01 09:00:00','2026-08-02 10:00:00'))
c.commit(); os._exit(0)
'''
        subprocess.run([sys.executable, '-c', child, str(database)], input=sql, text=True, check=True)
        assert database.with_name('assignments.db-wal').stat().st_size > 0
        (a.fixture / 'SYNTHETIC-ONLY.json').write_text(json.dumps({'identity': ID, 'schema': 2, 'wal': True, 'files': fingerprint(a.fixture)}, indent=2) + '\n')
        print('Synthetic v2 + committed WAL prepared; no app installed or launched')
        return
    if a.action == 'package':
        if not a.app or not a.output or a.output.exists(): p.error('Existing source .app and new --output .app required')
        info = plistlib.loads((a.app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] in [ID, 'com.qianmuyan.assignmentapp'] or info['CFBundleIdentifier'].startswith('com.qianmuyan.assignmentapp.rcsmoke.')
        run('ditto', '--norsrc', '--noextattr', '--noqtn', a.app, a.output)
        run('plutil', '-replace', 'CFBundleIdentifier', '-string', ID, a.output / 'Contents/Info.plist')
        run('python3', APPLE / 'scripts/sign-apple-bundle.py', a.output, '--entitlements', APPLE / 'AssignmentApp2/AssignmentApp2.entitlements')
        print('Prepared stable INTERNAL upgrade app; never use as formal distribution')
        return
    if not a.authorize_acceptance: p.error('Not executed during development: wait for 开始验收 before passing --authorize-acceptance')
    if a.action in ['seed', 'uninstall', 'install']:
        handles = subprocess.run(['lsof', '-t', '+D', str(DATA)], capture_output=True, text=True) if DATA.exists() else None
        if handles and (handles.stdout or handles.stderr or handles.returncode not in [0,1]): p.error('Quit app and release all data handles before mutation')
        # No broad process termination: the operator quits the identified internal app.
        if subprocess.run(['pgrep', '-f', str(a.destination) if a.destination else ID], capture_output=True).returncode == 0:
            p.error('Internal application still running; quit it first')
    if a.action in ['install', 'uninstall']:
        if not a.destination or a.destination.name != 'Assignment Upgrade Internal.app' or a.destination.parent.resolve() != (Path.home() / 'Applications').resolve():
            p.error('Destination must be ~/Applications/Assignment Upgrade Internal.app')
    if a.action == 'install':
        assert a.app and plistlib.loads((a.app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == ID
        if a.destination.exists():
            assert plistlib.loads((a.destination / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == ID
            # ditto replaces payload; refuse stale resources by moving the old app to a new sibling first.
            old = a.destination.with_name(a.destination.stem + '.previous.app')
            assert not old.exists(), 'Archive the previous rehearsal app first'
            a.destination.rename(old)
        run('ditto', '--norsrc', '--noextattr', '--noqtn', a.app, a.destination)
    elif a.action == 'launch':
        assert a.app and plistlib.loads((a.app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == ID
        run('open', '-n', a.app)
    elif a.action == 'seed':
        assert a.fixture
        receipt = json.loads((a.fixture / 'SYNTHETIC-ONLY.json').read_text())
        assert receipt['identity'] == ID
        actual = fingerprint(a.fixture); actual.pop('SYNTHETIC-ONLY.json', None)
        assert actual == receipt['files'], 'Synthetic fixture bytes changed; create a fresh fixture'
        assert DATA.parent.exists(), 'Launch and quit the stable internal app once to create its sandbox'
        assert not DATA.exists(), 'Archive existing internal data first; never overwrite a previous rehearsal'
        run('ditto', a.fixture, DATA)
    elif a.action == 'check':
        assert DATA.exists() and (DATA / 'SYNTHETIC-ONLY.json').is_file()
        with sqlite3.connect((DATA / 'assignments.db').as_uri() + '?mode=ro', uri=True) as db:
            assert db.execute('PRAGMA user_version').fetchone()[0] == 4
            assert db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
            assert not db.execute('PRAGMA foreign_key_check').fetchall()
            row = db.execute('SELECT description,due_date,status,completed_at FROM assignments WHERE id=1').fetchone()
            assert row[:3] == ('Description / 描述', '2026-11-01 01:30:00', 'completed') and row[3]
        print('Synthetic legacy payload and v4 integrity verified; attachment/relationship matrix uses Alpha checklist')
    elif a.action == 'uninstall':
        assert plistlib.loads((a.destination / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] == ID
        archived = a.destination.with_name(a.destination.stem + '.uninstalled.app')
        assert not archived.exists()
        a.destination.rename(archived)
        print('Removed app from installation path; internal user data retained. Archive can be deleted manually.')

if __name__ == '__main__': main()
