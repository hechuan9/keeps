#!/usr/bin/env python3
"""Archived Docker-era NAS storage migration. Default is read-only planning.

Stop the container before --apply; this script never changes Docker configuration.
It is not part of the current SPK deployment or upgrade workflow. Pass --container
explicitly to identify the historical source service; no retired service is assumed.
Old Keeps data and standard photos are retained. On failure, keep using old data.
Rerun against the same destination to resume verified copies. Never start a service
on the destination until report.json says PASS and deployment checks pass.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import sys


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def inside(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def stat_identity(stat):
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)


def clone_file(source_stream, destination_stream):
    if sys.platform != 'linux':
        return False
    try:
        fcntl.ioctl(destination_stream.fileno(), 0x40049409, source_stream.fileno())
        return True
    except OSError as error:
        if error.errno not in (errno.EOPNOTSUPP, errno.EXDEV, errno.ENOTTY, errno.EINVAL, errno.ENOSYS):
            raise
        return False


def copy_verified(source, target):
    if source.is_symlink() or target.is_symlink():
        raise RuntimeError(f'Symlink rejected: {source} -> {target}')
    if target.exists():
        if digest(target) != digest(source):
            raise RuntimeError(f'Existing destination differs: {target}')
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    # The staged inode is independent from the source, including with Btrfs CoW.
    # Linking that inode into place publishes exclusively without overwriting files.
    with tempfile.NamedTemporaryFile(prefix='.keeps-migration-', dir=target.parent, delete=False) as dst:
        staged = Path(dst.name)
        try:
            with source.open('rb') as src:
                before = os.fstat(src.fileno())
                cloned = clone_file(src, dst)
                if not cloned:
                    dst.seek(0)
                    dst.truncate()
                    src.seek(0)
                    shutil.copyfileobj(src, dst)
                dst.flush()
                if not cloned:
                    os.fsync(dst.fileno())
                after = os.fstat(src.fileno())
                output = os.fstat(dst.fileno())
                if stat_identity(before) != stat_identity(after) or stat_identity(after) != stat_identity(source.stat()):
                    raise RuntimeError(f'Source changed while copying: {source}')
                if output.st_size != after.st_size or (output.st_dev, output.st_ino) == (after.st_dev, after.st_ino):
                    raise RuntimeError(f'Copy is not an independent complete file: {target}')
            shutil.copystat(source, staged)
            if not cloned and digest(staged) != digest(source):
                raise RuntimeError(f'Copy verification failed: {target}')
            os.link(staged, target)
        finally:
            staged.unlink()


def connect(path):
    return sqlite3.connect(f'file:{path}?mode=ro', uri=True)


def plan(args):
    with connect(args.source / 'db/control_plane.sqlite') as db:
        result = []
        for lib, asset, source_hash, raw in db.execute(
                'SELECT library_id,asset_id,source_hash,standard FROM media_cache WHERE standard IS NOT NULL'):
            standard = json.loads(raw)
            old = Path(standard['path'])
            if not inside(old, Path('/standard-photos')) and not inside(old, args.standards):
                continue
            physical = args.standards / old.relative_to('/standard-photos') if inside(old, Path('/standard-photos')) else old
            sources = list(db.execute("SELECT path FROM catalog_paths WHERE library_id=? AND asset_id=? AND content_hash=? AND role='raw_original' ORDER BY path", (lib, asset, source_hash)))
            candidates = [Path(row[0]) for row in sources if inside(Path(row[0]), args.photos) and Path(row[0]).is_file()]
            if not candidates:
                raise RuntimeError(f'No retained RAW source for generated standard: {asset}')
            source = candidates[0]
            if digest(source) != source_hash or digest(physical) != standard['version']:
                raise RuntimeError(f'Indexed content differs: {asset}')
            target = source.with_name(f'{source.name}.keeps-{source_hash}.heic')
            for table in ('catalog_paths', 'catalog_version_paths'):
                rows = list(db.execute(f'SELECT asset_id,content_hash FROM {table} WHERE library_id=? AND path=?', (lib, str(target))))
                if rows and rows != [(asset, standard['version'])]:
                    raise RuntimeError(f'Destination belongs to another version: {target}')
            if target.exists() and digest(target) != standard['version']:
                raise RuntimeError(f'Destination content conflict: {target}')
            result.append(dict(library=lib, asset=asset, sourceHash=source_hash, source=str(source), old=str(physical), target=str(target), standard=standard))
        return result


def register(db, item):
    lib, asset, desc = item['library'], item['asset'], dict(item['standard'])
    target = Path(item['target'])
    h = desc['version']
    desc.update(path=str(target), sizeBytes=target.stat().st_size, mtimeNs=str(target.stat().st_mtime_ns))
    db.execute('INSERT OR IGNORE INTO catalog_paths VALUES(?,?,?,?,?)', (lib, str(target), asset, h, 'jpeg_original'))
    db.execute('INSERT OR IGNORE INTO catalog_files VALUES(?,?,?,?,?,?,?)', (lib, asset, h, target.stat().st_size, 'jpeg_original', 'keeps-nas', 'online'))
    evidence = json.dumps({'generatedFrom': item['sourceHash']})
    db.execute('INSERT OR IGNORE INTO catalog_versions VALUES(?,?,?,?,?,?,?,?,?)', (lib, asset, h, None, None, desc['width'], desc['height'], 1, evidence))
    db.execute('INSERT OR IGNORE INTO catalog_version_paths VALUES(?,?,?,?,1)', (lib, str(target), asset, h))
    # Legacy assets can predate version indexing. Preserve their effective RAW
    # default when adding the generated version, including reruns of this migration.
    raw_path = db.execute("SELECT path FROM catalog_paths WHERE library_id=? AND asset_id=? AND content_hash=? AND role='raw_original' AND path=?", (lib, asset, item['sourceHash'], item['source'])).fetchone()
    if raw_path is None:
        raise RuntimeError('Generated standard has no matching indexed RAW source: ' + asset)
    snapshot = db.execute('SELECT snapshot FROM catalog_assets WHERE library_id=? AND id=?', (lib, asset)).fetchone()
    if snapshot is None:
        raise RuntimeError('Generated standard asset is missing: ' + asset)
    raw_evidence = json.dumps({'capture': json.loads(snapshot[0])})
    db.execute('INSERT OR IGNORE INTO catalog_versions VALUES(?,?,?,?,?,?,?,?,?)', (lib, asset, item['sourceHash'], None, None, 0, 0, 1, raw_evidence))
    existing_raw = db.execute('SELECT asset_id,content_hash FROM catalog_version_paths WHERE library_id=? AND path=?', (lib, item['source'])).fetchone()
    if existing_raw is not None and existing_raw != (asset, item['sourceHash']):
        raise RuntimeError('RAW version path belongs to a different asset: ' + item['source'])
    db.execute('INSERT INTO catalog_version_paths VALUES(?,?,?,?,1) ON CONFLICT(library_id,path) DO UPDATE SET available=1', (lib, item['source'], asset, item['sourceHash']))
    db.execute('INSERT INTO catalog_defaults VALUES(?,?,?,0) ON CONFLICT(library_id,asset_id) DO UPDATE SET content_hash=excluded.content_hash WHERE user_selected=0 AND content_hash=?', (lib, asset, item['sourceHash'], h))
    db.execute('UPDATE media_cache SET standard=? WHERE library_id=? AND asset_id=?', (json.dumps(desc), lib, asset))


def cache_files(subtree):
    for directory, folders, files in os.walk(subtree):
        # DSM search thumbnails are not Keeps objects; the old tree retains them.
        folders[:] = [name for name in folders if name != '@eaDir']
        for name in folders:
            if (Path(directory) / name).is_symlink():
                raise RuntimeError(f'Symlink rejected: {Path(directory) / name}')
        for name in files:
            yield Path(directory) / name


def copy_cache(args):
    manifest_path = args.destination / 'cache-copy-manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    count = 0
    for name in ('previews', 'cache'):
        subtree = args.source / name
        if subtree.is_symlink():
            raise RuntimeError(f'Symlink rejected: {subtree}')
        for source in cache_files(subtree):
            if source.is_symlink():
                raise RuntimeError(f'Symlink rejected: {source}')
            if not source.is_file():
                continue
            relative = str(source.relative_to(args.source))
            target = args.destination / relative
            source_stat = [source.stat().st_size, source.stat().st_mtime_ns]
            target_stat = [target.stat().st_size, target.stat().st_mtime_ns] if target.exists() else None
            if manifest.get(relative) != [source_stat, target_stat]:
                copy_verified(source, target)
                if source_stat != [source.stat().st_size, source.stat().st_mtime_ns]:
                    raise RuntimeError(f'Cache source changed while copying: {source}')
                manifest[relative] = [source_stat, [target.stat().st_size, target.stat().st_mtime_ns]]
                count += 1
                if count % 1000 == 0:
                    save_manifest(manifest_path, manifest)
    save_manifest(manifest_path, manifest)
    if sys.platform == 'linux':
        os.sync()
    return len(manifest)


def save_manifest(path, value):
    temporary = path.with_suffix('.partial')
    temporary.write_text(json.dumps(value))
    os.replace(temporary, path)


def apply(args, items):
    state = json.loads(subprocess.check_output([args.docker, 'inspect', args.container]))[0]
    if state['State']['Running'] and not args.precopy:
        raise RuntimeError('Stop the container before applying the migration')
    args.destination.mkdir(parents=True, exist_ok=True)
    marker = args.destination / 'storage-migration.json'
    identity = dict(source=str(args.source.resolve()), destination=str(args.destination.resolve()))
    if marker.exists():
        prior = json.loads(marker.read_text())
        if prior['identity'] != identity:
            raise RuntimeError('Destination belongs to a different migration')
        if prior['status'] == 'PASS':
            for item in prior['standards']:
                if digest(Path(item['target'])) != item['standard']['version']:
                    raise RuntimeError('Completed migration standard content differs')
            return prior
    elif any(args.destination.iterdir()):
        raise RuntimeError('Nonempty destination without a migration marker')
    marker.write_text(json.dumps(dict(identity=identity, status='IN_PROGRESS', standards=items), ensure_ascii=False, indent=2))
    # Historical data stays intact in the source tree; only runtime data moves.
    copied_cache = copy_cache(args)
    if args.precopy:
        return dict(status='PRECOPY_COMPLETE', verifiedCacheFiles=copied_cache)
    dbdir = args.destination / 'db'
    dbdir.mkdir(exist_ok=True)
    for source in (args.source / 'db').iterdir():
        if source.suffix != '.sqlite':
            if not source.name.endswith(('-wal', '-shm')) and source.is_file():
                copy_verified(source, dbdir / source.name)
            continue
        with connect(source) as old, sqlite3.connect(dbdir / source.name) as new:
            old.backup(new)
            if new.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
                raise RuntimeError(f'Database copy corrupt: {source}')
    for item in items:
        copy_verified(Path(item['old']), Path(item['target']))
    with sqlite3.connect(dbdir / 'control_plane.sqlite') as db:
        before = db.execute('SELECT COUNT(*) FROM catalog_assets').fetchone()[0]
        for item in items:
            register(db, item)
        db.commit()
        assert db.execute('SELECT COUNT(*) FROM catalog_assets').fetchone()[0] == before
        assert not db.execute('PRAGMA foreign_key_check').fetchall()
        assert db.execute('PRAGMA quick_check').fetchall() == [('ok',)]
        for item in items:
            actual = db.execute('SELECT asset_id,content_hash FROM catalog_paths WHERE library_id=? AND path=?', (item['library'], item['target'])).fetchone()
            assert actual == (item['asset'], item['standard']['version'])
    report = dict(identity=identity, status='PASS', copiedStandards=len(items), assets=before, standards=items,
                  boundaries='Old system data and original files retained; only generated standard copies added to photo directories. Docker configuration unchanged.')
    marker.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('/volume2/myphoto/keeps'))
    parser.add_argument('--destination', type=Path, default=Path('/volume2/docker/keeps/data'))
    parser.add_argument('--standards', type=Path, default=Path('/volume2/myphoto/standard-photos'))
    parser.add_argument('--photos', type=Path, default=Path('/volume2/photo'))
    parser.add_argument('--container', required=True, help='Explicit historical Docker service name; not the current SPK service')
    parser.add_argument('--docker', default='/usr/local/bin/docker')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--apply', action='store_true')
    modes.add_argument('--precopy', action='store_true', help='Copy and verify only stable caches while service remains online')
    args = parser.parse_args()
    if inside(args.destination, args.source) or inside(args.source, args.destination) or inside(args.destination, args.photos):
        raise RuntimeError('System destination must be separate from old data and photos')
    if args.apply:
        state = json.loads(subprocess.check_output([args.docker, 'inspect', args.container]))[0]
        if state['State']['Running']:
            raise RuntimeError('Stop the container before planning an applied migration')
    items = [] if args.precopy else plan(args)
    print(json.dumps(apply(args, items) if args.apply or args.precopy else dict(mode='PLAN', standards=items), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
