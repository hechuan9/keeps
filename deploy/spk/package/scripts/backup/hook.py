#!/usr/bin/python3
"""Offline Hyper Backup export and restore for Keeps application state."""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import uuid

VAR = Path('/var/packages/KeepsNativeProbe/var')
CONTROLLER = '/usr/syno/bin/synopkg'
DATABASES = ('db/control_plane.sqlite', 'db/jobs.sqlite')
CONFIGS = ('original-root', 'server-url', 'server-overrides', 'access-token')
VERSION = '1.0'


def state_root():
    root = VAR / 'state'
    overrides = VAR / 'server-overrides'
    if overrides.exists():
        for line in overrides.read_text().splitlines():
            key, separator, value = line.partition('=')
            if key == 'KEEPS_ROOT' and separator:
                root = Path(value)
    if not root.is_absolute():
        raise ValueError('KEEPS_ROOT must be absolute')
    return root


def require_stopped():
    result = subprocess.run([CONTROLLER, 'status', 'KeepsNativeProbe'],
                            capture_output=True, text=True)
    diagnostic = 'exit={}; stdout={!r}; stderr={!r}'.format(
        result.returncode, result.stdout, result.stderr)
    try:
        status = json.loads(result.stdout)
    except ValueError as error:
        raise RuntimeError('Cannot verify Keeps package status: ' + diagnostic) from error
    # DSM reports a stopped package with exit 17; only its explicit state is authoritative.
    if not isinstance(status, dict) or status.get('status') != 'stop' or result.returncode not in (0, 17):
        raise RuntimeError('Keeps must be stopped before backup or restore: ' + diagnostic)


def validate_db(path):
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as connection:
        if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise ValueError('SQLite integrity check failed: ' + str(path))
        return connection.execute('PRAGMA user_version').fetchone()[0]


def backup_db(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)) as src:
        with closing(sqlite3.connect(str(target))) as dst:
            src.backup(dst)
            dst.execute('PRAGMA journal_mode=DELETE')
    return validate_db(target)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def copy_maintenance(source, target):
    if source.exists():
        for path in source.rglob('*'):
            if path.is_symlink() or (not path.is_file() and not path.is_dir()):
                raise ValueError('Maintenance state must contain regular files and directories')
        shutil.copytree(source, target)


def require_export_space(temp, root):
    files = [root / name for name in DATABASES]
    files += [Path(str(root / name) + '-wal') for name in DATABASES]
    files += [VAR / name for name in CONFIGS]
    maintenance = root / 'maintenance'
    if maintenance.exists():
        files += [path for path in maintenance.rglob('*') if path.is_file()]
    size = sum(path.stat().st_size for path in files if path.exists())
    # Allow SQLite page overhead without filling the DSM system partition.
    required = size + max(64 * 1024 * 1024, size // 20)
    free = shutil.disk_usage(temp).free
    if free < required:
        raise RuntimeError('Insufficient backup destination space: requires {} bytes, available {} bytes at {}'.format(
            required, free, temp))


def export_state(temp):
    require_stopped()
    root = state_root()
    require_export_space(temp, root)
    destination = temp / 'keeps'
    destination.mkdir(mode=0o700)
    schemas = {name: backup_db(root / name, destination / name) for name in DATABASES}
    (destination / 'config').mkdir()
    for name in CONFIGS:
        if (VAR / name).exists():
            shutil.copyfile(VAR / name, destination / 'config' / name)
    copy_maintenance(root / 'maintenance', destination / 'maintenance')
    manifest = {'version': VERSION, 'files': {}, 'schema_versions': schemas}
    for path in destination.rglob('*'):
        if path.is_file():
            manifest['files'][path.relative_to(destination).as_posix()] = digest(path)
    (destination / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True))


def validate_backup(temp):
    source = temp / 'keeps'
    manifest = json.loads((source / 'manifest.json').read_text())
    if manifest['version'] != VERSION:
        raise ValueError('Unsupported Keeps backup version')
    required = set(DATABASES) | {'config/' + n for n in ('original-root', 'server-url', 'access-token')}
    if not required <= manifest['files'].keys():
        raise ValueError('Backup is missing required state')
    for name, expected in manifest['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid backup path')
        if name not in DATABASES and name not in {'config/' + n for n in CONFIGS} and not name.startswith('maintenance/'):
            raise ValueError('Unexpected backup content: ' + name)
        path = source / name
        if source.resolve() not in path.resolve().parents or not path.is_file() or digest(path) != expected:
            raise ValueError('Backup checksum mismatch: ' + name)
    for name in DATABASES:
        if validate_db(source / name) != manifest['schema_versions'][name]:
            raise ValueError('Backup schema version mismatch')
    return source, manifest


def reset_replica_generation(path):
    with closing(sqlite3.connect(str(path))) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='catalog_sync_state'").fetchone():
            return
        # A restored revision can equal a phone's cursor while describing different data.
        with db:
            libraries = db.execute('SELECT library_id FROM catalog_sync_state').fetchall()
            for (library,) in libraries:
                db.execute("UPDATE catalog_sync_state SET generation=?, floor=coalesce((SELECT revision FROM catalog_version_revision WHERE library_id=?),0) WHERE library_id=?",
                           (str(uuid.uuid4()), library, library))
            db.execute('DELETE FROM catalog_replicas')


def inherit_owner(path, reference):
    owner = reference.stat()
    os.chown(str(path), owner.st_uid, owner.st_gid)


def import_state(temp):
    require_stopped()
    source, manifest = validate_backup(temp)
    root = state_root()
    if not root.exists():
        root.mkdir(parents=True)
        inherit_owner(root, VAR)
    (root / 'backups').mkdir(exist_ok=True)
    saved = Path(tempfile.mkdtemp(prefix='restore-before-', dir=str(root / 'backups')))
    # Retain the complete previous state before replacing any live file.
    for name in DATABASES:
        if (root / name).exists():
            backup_db(root / name, saved / name)
    (saved / 'config').mkdir()
    for name in CONFIGS:
        if (VAR / name).exists():
            shutil.copyfile(VAR / name, saved / 'config' / name)
    if (root / 'maintenance').exists():
        os.rename(root / 'maintenance', saved / 'maintenance')
    for name in DATABASES:
        target = root / name
        if not target.parent.exists():
            target.parent.mkdir(parents=True)
            inherit_owner(target.parent, root)
        staged = target.with_suffix('.restore')
        backup_db(source / name, staged)
        if name == DATABASES[0]:
            reset_replica_generation(staged)
        staged.chmod(0o600)
        inherit_owner(staged, target if target.exists() else target.parent)
        for suffix in ('-wal', '-shm'):
            Path(str(target) + suffix).unlink(missing_ok=True)
        os.replace(staged, target)
    for name in CONFIGS:
        target = VAR / name
        if 'config/' + name not in manifest['files']:
            if name == 'server-overrides':
                target.write_text('KEEPS_ROOT=' + str(root) + '\n')
                target.chmod(0o600)
                inherit_owner(target, VAR)
            continue
        data = (source / 'config' / name).read_bytes()
        if name == 'server-overrides':
            lines = [line for line in data.decode().splitlines() if not line.startswith('KEEPS_ROOT=')]
            data = ('\n'.join(lines + ['KEEPS_ROOT=' + str(root)]) + '\n').encode()
        staged = target.with_name(target.name + '.restore')
        staged.write_bytes(data)
        staged.chmod(0o600)
        inherit_owner(staged, target if target.exists() else VAR)
        os.replace(staged, target)
    for name in manifest['files']:
        if name.startswith('maintenance/'):
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            for directory in target.parents:
                if directory == root:
                    break
                inherit_owner(directory, root)
            shutil.copyfile(source / name, target)
            inherit_owner(target, root)
    print('Previous state retained at ' + str(saved), file=sys.stderr)


def main():
    os.umask(0o077)
    action = sys.argv[1]
    request = json.loads(os.environ.get('SYNOPKG_BKP_INPUT', '{}'))
    if action == 'can_export':
        root = state_root()
        result = {'result': all((root / n).is_file() for n in DATABASES) and
                  all((VAR / n).is_file() for n in ('original-root', 'server-url', 'access-token'))}
    elif action == 'can_import':
        result = {'result': request.get('app_data_version') == VERSION}
    else:
        temp = Path(request['temp_path'])
        if not temp.is_absolute() or not temp.is_dir():
            raise ValueError('Backup temp_path must be an existing absolute directory')
        if action == 'export':
            export_state(temp)
        elif action == 'import':
            if request.get('app_data_version') != VERSION:
                raise ValueError('Unsupported application data version')
            import_state(temp)
        else:
            raise ValueError('Unknown backup action')
        result = {'app_data_version': VERSION}
    Path(os.environ['SYNOPKG_BKP_OUTPUT_PATH']).write_text(json.dumps(result))


if __name__ == '__main__':
    main()
