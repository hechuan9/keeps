#!/usr/bin/env python3
"""逐层检查追踪目录，只合并同一直接父目录内有精确内容证据的资产。

plan 默认只读生产数据库与原片；apply 要求停止指定 Keeps 容器并自动备份双库。
检查器复用 keeps-inspect 的 NDJSON 协议。详情见 docs/folder-merge.md。
"""
import argparse
from collections import defaultdict, deque
from contextlib import closing
import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import traceback
import uuid

POLICY = 'same-directory-exact-v1'
PHOTO_EXTENSIONS = set('3fr ari arw bay cr2 cr3 crw dcr dng erf fff iiq k25 kdc mef mos mrw nef nrw orf pef raf raw rw2 rwl sr2 srf srw jpg jpeg heic heif hif png tif tiff'.split())
ORIGINAL_ROLES = ('jpeg_original', 'raw_original')
ASSET_TABLES = ('catalog_files', 'catalog_versions', 'catalog_version_paths', 'catalog_defaults', 'derivative_objects')
USER_FIELDS = ('rating', 'flagState', 'colorLabel', 'caption', 'tags', 'trashed')


def encoded(value):
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(',', ':'))


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def under(path, root):
    return path == root or root in path.parents


def physical(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('需要无 .. 的绝对路径: ' + str(path))
    for part in reversed((path, *path.parents)):
        if part.is_symlink():
            raise ValueError('不跟随符号链接: ' + str(part))
    return path


def stamp(path):
    info = physical(path).stat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('不是普通文件: ' + str(path))
    return dict(size=info.st_size, mtime_ns=info.st_mtime_ns, ctime_ns=info.st_ctime_ns, dev=info.st_dev, ino=info.st_ino)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def connect_ro(path):
    return sqlite3.connect(Path(path).as_uri() + '?mode=ro', uri=True, timeout=30)


def integrity(db, schema='main'):
    rows = db.execute('PRAGMA ' + schema + '.integrity_check').fetchall()
    if rows != [('ok',)]:
        raise ValueError('数据库完整性检查失败: ' + str(rows))


def copy_database(source, target):
    with closing(connect_ro(source)) as src, closing(sqlite3.connect(target)) as dst:
        src.backup(dst, pages=1024)
        integrity(dst)


def layout(container):
    data = json.loads(subprocess.check_output(['docker', 'inspect', container], text=True))[0]
    env = dict(item.split('=', 1) for item in data['Config']['Env'])
    keeps = next(Path(m['Source']) for m in data['Mounts'] if m['Destination'] == env['KEEPS_ROOT'])
    originals = []
    for mount in data['Mounts']:
        if mount['RW'] or not under(Path(mount['Destination']), Path(env['ORIGINAL_ROOT'])):
            continue
        if mount['Source'] != mount['Destination']:
            raise ValueError('整理要求原片使用宿主同路径挂载')
        originals.append(Path(mount['Source']))
    if not originals:
        raise ValueError('未找到原片只读挂载')
    return keeps, originals, data['State']['Running']


def stopped(container, keeps, roots):
    actual_keeps, actual_roots, running = layout(container)
    if running or actual_keeps != keeps or set(actual_roots) != set(roots):
        raise ValueError('apply 要求同一 Keeps 容器已停止，且数据目录/只读原片挂载与计划一致')


def tracked(db):
    return [list(r) for r in db.execute('SELECT id,library_id,path FROM jobsdb.folders WHERE active=1 ORDER BY library_id,path,id')]


def walk_roots(folders, allowed):
    selected = defaultdict(set)
    for _, library, value in folders:
        folder = physical(value)
        for mount in allowed:
            if under(folder, mount):
                selected[library].add(folder)
            elif under(mount, folder):
                selected[library].add(mount)
    return [(lib, p) for lib in sorted(selected) for p in sorted(selected[lib])
            if not any(other != p and under(p, other) for other in selected[lib])]


class Inspector:
    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def inspect(self, path):
        self.process.stdin.write(encoded({'path': str(path)}) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('媒体检查器意外结束: ' + str(self.process.poll()))
        result = json.loads(line)
        if result.get('path') != str(path):
            raise ValueError('媒体检查器响应路径不匹配')
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=10)
        self.process.stdout.close()


def cached_inspect(cache, inspector, path):
    state = stamp(path)
    # Sidecar metadata is re-read by the inspector; only cache originals without sidecars.
    sidecars = [candidate for ext in ('xmp', 'XMP') for candidate in (path.with_suffix('.' + ext), Path(str(path) + '.' + ext)) if candidate.exists()]
    row = cache.execute('SELECT stamp,evidence FROM evidence WHERE path=?', (str(path),)).fetchone()
    if not sidecars and row and row[0] == encoded(state) and not json.loads(row[1]).get('sidecar_stamp'):
        return json.loads(row[1])
    result = inspector.inspect(path)
    if 'error' not in result:
        if result['stamp'] != state or stamp(path) != state:
            raise ValueError('检查期间文件发生变化: ' + str(path))
        cache.execute('INSERT OR REPLACE INTO evidence VALUES(?,?,?)', (str(path), encoded(state), encoded(result)))
        cache.commit()
    return result


def asset_state(db, library, asset):
    row = db.execute('SELECT * FROM catalog_assets WHERE library_id=? AND id=?', (library, asset)).fetchone()
    if row is None:
        raise ValueError('资产已不存在: ' + asset)
    result = {'catalog_assets': [list(row)]}
    for table in (*ASSET_TABLES, 'catalog_paths'):
        result[table] = sorted([list(r) for r in db.execute('SELECT * FROM ' + table + ' WHERE library_id=? AND asset_id=?', (library, asset))], key=encoded)
    result['jobs.files'] = sorted([list(r) for r in db.execute('SELECT f.* FROM jobsdb.files f JOIN jobsdb.folders d ON f.folder_id=d.id WHERE d.library_id=? AND f.asset_id=?', (library, asset))], key=encoded)
    return result


def state_hash(state):
    return hashlib.sha256(encoded(state).encode()).hexdigest()


def outside_paths(db, library, asset, directory):
    paths = [r[0] for r in db.execute('SELECT path FROM catalog_paths WHERE library_id=? AND asset_id=? UNION SELECT path FROM catalog_version_paths WHERE library_id=? AND asset_id=?', (library, asset, library, asset))]
    paths += [r[0] for r in db.execute('SELECT f.path FROM jobsdb.files f JOIN jobsdb.folders d ON f.folder_id=d.id WHERE d.library_id=? AND f.asset_id=?', (library, asset))]
    return any(Path(p).parent != directory for p in paths)


def user_values(snapshot):
    return {k: sorted(snapshot.get(k, [])) if k == 'tags' else snapshot.get(k) for k in USER_FIELDS}


def build_groups(db, library, directory, files):
    indexed = [f for f in files if f.get('asset_id') and 'error' not in f]
    parent = {f['asset_id']: f['asset_id'] for f in indexed}
    def root(a):
        while parent[a] != a:
            a = parent[a]
        return a
    buckets = defaultdict(set)
    for f in indexed:
        for kind in ('sha256', 'visual_hash'):
            if f.get(kind):
                buckets[kind, f[kind]].add(f['asset_id'])
    for members in buckets.values():
        members = sorted(members)
        for a in members[1:]:
            parent[root(a)] = root(members[0])
    components = defaultdict(list)
    for a in sorted(parent):
        components[root(a)].append(a)
    plans, skipped = [], []
    for members in components.values():
        if len(members) < 2:
            continue
        group = {'library': library, 'directory': str(directory), 'members': members}
        if any(outside_paths(db, library, a, directory) for a in members):
            skipped.append(dict(group, reason='asset_spans_directories'))
            continue
        evidence = [f for f in indexed if f['asset_id'] in members]
        verified = {(f['path'], f['sha256']) for f in evidence}
        expected = set()
        for a in members:
            expected.update(db.execute("SELECT path,content_hash FROM catalog_paths WHERE library_id=? AND asset_id=? AND role IN ('jpeg_original','raw_original') UNION SELECT path,content_hash FROM catalog_version_paths WHERE library_id=? AND asset_id=? AND available=1", (library, a, library, a)))
        if not expected.issubset(verified):
            skipped.append(dict(group, reason='indexed_original_missing_or_unverified'))
            continue
        snapshots = {a: json.loads(db.execute('SELECT snapshot FROM catalog_assets WHERE library_id=? AND id=?', (library, a)).fetchone()[0]) for a in members}
        if len({encoded(user_values(s)) for s in snapshots.values()}) != 1:
            skipped.append(dict(group, reason='user_metadata_conflict'))
            continue
        defaults = {a: db.execute('SELECT content_hash,user_selected FROM catalog_defaults WHERE library_id=? AND asset_id=?', (library, a)).fetchone() for a in members}
        choices = {d[0] for d in defaults.values() if d and d[1]}
        if len(choices) > 1:
            skipped.append(dict(group, reason='user_default_conflict'))
            continue
        def preference(a):
            count = db.execute("SELECT count(DISTINCT content_hash) FROM catalog_files WHERE library_id=? AND asset_id=? AND role IN ('jpeg_original','raw_original')", (library, a)).fetchone()[0]
            preview = db.execute("SELECT count(*) FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'", (library, a)).fetchone()[0]
            return (-(bool(defaults[a]) and defaults[a][1]), -count, -preview, a)
        survivor = min(members, key=preference)
        plans.append(dict(group, survivor=survivor, evidence=evidence,
                          states={a: state_hash(asset_state(db, library, a)) for a in members}))
    metadata = defaultdict(list)
    for f in indexed:
        capture = f.get('capture', {})
        key = tuple(capture.get(k) for k in ('captureTime', 'cameraMake', 'cameraModel', 'lensModel'))
        if all(isinstance(v, str) and v.strip() for v in key):
            metadata[key].append(f)
    candidates = []
    for values in metadata.values():
        members = sorted({f['asset_id'] for f in values})
        if len({root(a) for a in members}) < 2:
            continue
        serials = {f['capture'].get('cameraSerial') for f in values if f['capture'].get('cameraSerial')}
        candidates.append({'library': library, 'directory': str(directory), 'members': members,
                           'reason': 'camera_serial_conflict' if len(serials) > 1 else 'requires_visual_confirmation'})
    return plans, skipped, candidates


def directory_plan(db, cache, inspector, library, directory, entries):
    files, issues = [], []
    for entry in entries:
        if not entry.is_file(follow_symlinks=False) or Path(entry.name).suffix.lower().lstrip('.') not in PHOTO_EXTENSIONS:
            continue
        path = Path(entry.path)
        try:
            result = cached_inspect(cache, inspector, path)
            if 'error' in result:
                issues.append({'path': str(path), 'reason': 'inspection_error', 'error': result['error']})
                continue
            row = db.execute('SELECT asset_id,content_hash,role FROM catalog_paths WHERE library_id=? AND path=?', (library, str(path))).fetchone()
            if row is None:
                issues.append({'path': str(path), 'reason': 'not_indexed'})
            elif row[1] != result['sha256'] or row[2] not in ORIGINAL_ROLES:
                issues.append({'path': str(path), 'reason': 'catalog_content_changed'})
            else:
                result = dict(result, asset_id=row[0])
            files.append(result)
            if len(files) % 100 == 0:
                print(encoded({'directory': str(directory), 'inspected': len(files)}), flush=True)
        except (OSError, ValueError):
            issues.append({'path': str(path), 'reason': 'inspection_error', 'error': traceback.format_exc()})
    groups, skipped, candidates = build_groups(db, library, directory, files)
    if issues:
        skipped += [dict(g, reason='directory_needs_index_reconciliation') for g in groups]
        groups = []
    return dict(library=library, directory=str(directory), inspected=len(files), issues=issues,
                groups=groups, skipped=skipped, metadata_candidates=candidates)


def plan(keeps, roots, run, inspector, resume=False):
    keeps, run = physical(keeps), physical(run)
    roots = [physical(p) for p in roots]
    if not under(run, keeps / 'maintenance'):
        raise ValueError('工作目录必须位于 KEEPS_ROOT/maintenance 下')
    run.mkdir(parents=True, exist_ok=resume)
    config = {'policy': POLICY, 'keeps': str(keeps), 'roots': sorted(map(str, roots))}
    config_path = run / 'config.json'
    if resume and config_path.exists() and json.loads(config_path.read_text()) != config:
        raise ValueError('断点续跑配置与原计划不一致')
    if (run / 'plan.json').exists():
        (run / 'plan.json').rename(run / 'previous-plan.json')
    config_path.write_text(encoded(config))
    # Re-snapshot on resume; only unchanged file inspection is reused, never stale DB associations.
    for name in ('control_plane', 'jobs'):
        copy_database(keeps / 'db' / (name + '.sqlite'), run / (name + '.sqlite'))
    with closing(sqlite3.connect(run / 'control_plane.sqlite')) as db, closing(sqlite3.connect(run / 'cache.sqlite')) as cache:
        if db.execute('PRAGMA user_version').fetchone()[0] not in (3, 4, 5):
            raise ValueError('需要 catalog schema 3、4 或 5')
        db.execute('ATTACH DATABASE ? AS jobsdb', (str(run / 'jobs.sqlite'),))
        db.execute('CREATE INDEX IF NOT EXISTS jobsdb.maintenance_files_asset ON files(asset_id)')
        cache.execute('CREATE TABLE IF NOT EXISTS evidence(path TEXT PRIMARY KEY,stamp TEXT NOT NULL,evidence TEXT NOT NULL)')
        folders = tracked(db)
        queue = deque(walk_roots(folders, roots))
        report = dict(config, id=str(uuid.uuid4()), created_at=now(), tracked=folders, directories=[], errors=[])
        while queue:
            library, directory = queue.popleft()
            if under(directory, keeps):
                continue
            try:
                physical(directory)
                with os.scandir(directory) as iterator:
                    entries = sorted(iterator, key=lambda e: e.name)
                visible = [e for e in entries if not e.name.startswith('.') and e.name not in ('@eaDir', '#recycle') and not e.is_symlink()]
                queue.extend((library, Path(e.path)) for e in visible if e.is_dir(follow_symlinks=False))
                result = directory_plan(db, cache, inspector, library, directory, visible)
                report['directories'].append(result)
                print(encoded({'directory': str(directory), 'library': library, 'inspected': result['inspected'], 'merge_groups': len(result['groups']), 'issues': len(result['issues'])}), flush=True)
            except OSError:
                report['errors'].append({'directory': str(directory), 'error': traceback.format_exc()})
            temporary = run / 'plan.partial.json'
            temporary.write_text(encoded(report))
        report['complete'] = not report['errors']
        (run / 'plan.partial.json').write_text(encoded(report))
        (run / 'plan.partial.json').replace(run / 'plan.json')
        return report


def merge_rows(db, table, library, source, survivor):
    columns = [r[1] for r in db.execute('PRAGMA table_info(' + table + ')')]
    rows = db.execute('SELECT * FROM ' + table + ' WHERE library_id=? AND asset_id=?', (library, source)).fetchall()
    for row in rows:
        values = list(row)
        values[columns.index('asset_id')] = survivor
        db.execute('INSERT OR IGNORE INTO ' + table + ' VALUES(' + ','.join('?' for _ in values) + ')', values)
        if table == 'catalog_files' and values[columns.index('availability')] == 'online':
            db.execute("UPDATE catalog_files SET availability='online' WHERE library_id=? AND asset_id=? AND content_hash=? AND role=? AND holder=?", (library, survivor, values[columns.index('content_hash')], values[columns.index('role')], values[columns.index('holder')]))
    db.execute('DELETE FROM ' + table + ' WHERE library_id=? AND asset_id=?', (library, source))


def apply_group(db, group):
    library, survivor = group['library'], group['survivor']
    old_default = db.execute('SELECT content_hash,user_selected FROM catalog_defaults WHERE library_id=? AND asset_id=?', (library, survivor)).fetchone()
    for source in group['members']:
        if source == survivor:
            continue
        for table in ('catalog_files', 'catalog_versions'):
            merge_rows(db, table, library, source, survivor)
        for table in ('catalog_paths', 'catalog_version_paths'):
            db.execute('UPDATE ' + table + ' SET asset_id=? WHERE library_id=? AND asset_id=?', (survivor, library, source))
        db.execute('UPDATE jobsdb.files SET asset_id=? WHERE asset_id=? AND folder_id IN (SELECT id FROM jobsdb.folders WHERE library_id=?)', (survivor, source, library))
        for table in ('catalog_defaults', 'derivative_objects'):
            db.execute('DELETE FROM ' + table + ' WHERE library_id=? AND asset_id=?', (library, source))
        db.execute('DELETE FROM catalog_assets WHERE library_id=? AND id=?', (library, source))
    for f in group['evidence']:
        capture = f['capture']
        key = [capture.get(k) for k in ('captureTime', 'cameraMake', 'cameraModel', 'lensModel')]
        key = json.dumps(key, ensure_ascii=False, separators=(',', ':')) if all(isinstance(x, str) and x.strip() for x in key) else None
        evidence = dict(exactVisualHash=f.get('visual_hash'), edited=f['priority'] == 3, cameraSerial=capture.get('cameraSerial', ''), captureOriginal=capture.get('captureOriginal', ''), capture=capture)
        db.execute('INSERT INTO catalog_versions VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(library_id,asset_id,content_hash) DO UPDATE SET visual_hash=excluded.visual_hash,capture_key=excluded.capture_key,width=excluded.width,height=excluded.height,priority=excluded.priority,evidence=excluded.evidence', (library, survivor, f['sha256'], f.get('visual_hash'), key, f['width'], f['height'], f['priority'], encoded(evidence)))
        db.execute('INSERT INTO catalog_version_paths VALUES(?,?,?,?,1) ON CONFLICT(library_id,path) DO UPDATE SET asset_id=excluded.asset_id,content_hash=excluded.content_hash,available=1', (library, f['path'], survivor, f['sha256']))
    available = db.execute('SELECT v.content_hash,v.priority FROM catalog_versions v WHERE library_id=? AND asset_id=? AND EXISTS(SELECT 1 FROM catalog_version_paths p WHERE p.library_id=v.library_id AND p.asset_id=v.asset_id AND p.content_hash=v.content_hash AND p.available=1) ORDER BY priority DESC,width*height DESC,content_hash', (library, survivor)).fetchall()
    priorities = dict(available)
    chosen = available[0][0]
    selected = 0
    if old_default and old_default[0] in priorities and (old_default[1] or priorities[old_default[0]] >= available[0][1]):
        chosen, selected = old_default
    db.execute('INSERT INTO catalog_defaults VALUES(?,?,?,?) ON CONFLICT(library_id,asset_id) DO UPDATE SET content_hash=excluded.content_hash,user_selected=excluded.user_selected', (library, survivor, chosen, selected))
    if not old_default or old_default[0] != chosen:
        db.execute("DELETE FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'", (library, survivor))
    db.execute("UPDATE catalog_assets SET snapshot=json_set(snapshot,'$.updatedAt',?) WHERE library_id=? AND id=?", (now(), library, survivor))
    db.execute('INSERT INTO catalog_version_revision VALUES(?,1) ON CONFLICT(library_id) DO UPDATE SET revision=revision+1', (library,))


def sidecar_stamp(path):
    values = []
    for ext in ('xmp', 'XMP'):
        for candidate in (path.with_suffix('.' + ext), Path(str(path) + '.' + ext)):
            try:
                info = candidate.lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISREG(info.st_mode):
                values.append(str(candidate) + ':' + str(info.st_size) + ':' + str(info.st_mtime_ns))
    return '|'.join(values)


def validate_group(db, group, roots):
    for asset in group['members']:
        if state_hash(asset_state(db, group['library'], asset)) != group['states'][asset]:
            raise ValueError('数据库在计划后发生变化，请重新 plan --resume: ' + asset)
        if outside_paths(db, group['library'], asset, Path(group['directory'])):
            raise ValueError('资产已跨目录: ' + asset)
    for f in group['evidence']:
        path = physical(f['path'])
        if path.parent != Path(group['directory']) or not any(under(path, root) for root in roots):
            raise ValueError('计划文件超出同目录/只读挂载范围')
        if sidecar_stamp(path) != f['sidecar_stamp']:
            raise ValueError('sidecar 在计划后发生变化: ' + str(path))
        before = stamp(path)
        if before != f['stamp'] or sha256(path) != f['sha256'] or stamp(path) != before or sidecar_stamp(path) != f['sidecar_stamp']:
            raise ValueError('原片在计划后发生变化，请重新 plan --resume: ' + str(path))


def apply(run, container):
    report = json.loads((run / 'plan.json').read_text())
    keeps, roots = Path(report['keeps']), list(map(Path, report['roots']))
    if report.get('policy') != POLICY or not report.get('complete') or not under(run, keeps / 'maintenance'):
        raise ValueError('计划不完整、版本不匹配或工作目录不正确')
    stopped(container, keeps, roots)
    groups = [g for d in report['directories'] for g in d['groups']]
    result = {'plan': report['id'], 'at': now(), 'groups': len(groups), 'merged_assets': sum(len(g['members']) - 1 for g in groups)}
    journal_path = run / 'applied.sqlite'
    with closing(sqlite3.connect(journal_path)) as journal:
        journal.execute('CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,result TEXT NOT NULL)')
        row = journal.execute('SELECT result FROM runs WHERE id=?', (report['id'],)).fetchone()
        if row:
            return dict(json.loads(row[0]), already_applied=True)
    if not groups:
        return dict(result, backup=None)
    backup = keeps / 'backups' / ('folder-merge-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
    backup.mkdir(parents=True)
    for name in ('control_plane', 'jobs'):
        copy_database(keeps / 'db' / (name + '.sqlite'), backup / (name + '.sqlite'))
    result['backup'] = str(backup)
    (run / 'apply-started.json').write_text(encoded(result))
    with closing(sqlite3.connect(keeps / 'db/control_plane.sqlite', timeout=30)) as db:
        db.execute('ATTACH DATABASE ? AS jobsdb', (str(keeps / 'db/jobs.sqlite'),))
        db.execute('ATTACH DATABASE ? AS auditdb', (str(journal_path),))
        modes = {s: db.execute('PRAGMA ' + s + '.journal_mode').fetchone()[0] for s in ('main', 'jobsdb', 'auditdb')}
        try:
            # SQLite super-journal makes catalog/jobs/audit commit atomic across process interruption.
            for schema in modes:
                mode = db.execute('PRAGMA ' + schema + '.journal_mode=DELETE').fetchone()[0]
                if mode != 'delete':
                    raise ValueError('无法启用跨库原子事务: ' + schema)
                db.execute('PRAGMA ' + schema + '.synchronous=FULL')
            db.execute('BEGIN IMMEDIATE')
            db.execute('CREATE INDEX jobsdb.maintenance_merge_files_asset ON files(asset_id)')
            if tracked(db) != report['tracked']:
                raise ValueError('追踪配置已变化，请重新 plan --resume')
            for group in groups:
                validate_group(db, group, roots)
            stopped(container, keeps, roots)
            for group in groups:
                for f in group['evidence']:
                    if stamp(Path(f['path'])) != f['stamp'] or sidecar_stamp(Path(f['path'])) != f['sidecar_stamp']:
                        raise ValueError('原片或sidecar在预检过程中变化')
            for group in groups:
                apply_group(db, group)
            db.execute('DROP INDEX jobsdb.maintenance_merge_files_asset')
            integrity(db)
            integrity(db, 'jobsdb')
            db.execute('INSERT INTO auditdb.runs VALUES(?,?)', (report['id'], encoded(dict(result, mappings=[{k: g[k] for k in ('library', 'directory', 'members', 'survivor')} for g in groups]))))
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            for schema, mode in modes.items():
                db.execute('PRAGMA ' + schema + '.journal_mode=' + mode)
    (run / 'applied.json').write_text(encoded(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('plan', help='逐层预览，不修改生产数据库')
    p.add_argument('--container', required=True, help='Explicit legacy Docker service; this migration tool does not operate on the current SPK service')
    p.add_argument('--run-dir', required=True, type=Path)
    p.add_argument('--resume', action='store_true')
    p.add_argument('--inspector', nargs=argparse.REMAINDER, required=True, help='最后一个选项；其余参数作为 keeps-inspect 命令，不经 shell')
    a = sub.add_parser('apply', help='停止服务后应用计划，自动备份双库')
    a.add_argument('--container', required=True, help='Explicit legacy Docker service; this migration tool does not operate on the current SPK service')
    a.add_argument('--run-dir', required=True, type=Path)
    args = parser.parse_args()
    if args.action == 'apply':
        print(encoded(apply(physical(args.run_dir), args.container)))
        return
    keeps, roots, _ = layout(args.container)
    inspector = Inspector(args.inspector)
    try:
        report = plan(keeps, roots, args.run_dir, inspector, args.resume)
        print(encoded({'complete': report['complete'], 'directories': len(report['directories']), 'merge_groups': sum(len(d['groups']) for d in report['directories']), 'plan': str(args.run_dir / 'plan.json')}))
    finally:
        inspector.close()


if __name__ == '__main__':
    main()
