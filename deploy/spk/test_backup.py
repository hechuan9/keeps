from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('backup_hook', ROOT / 'package/scripts/backup/hook.py')
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


@contextmanager
def database(path):
    connection = sqlite3.connect(path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.var = self.base / 'var'
        self.var.mkdir()
        self.root = self.base / 'state'
        (self.root / 'db').mkdir(parents=True)
        self.backup = self.base / 'backup'
        self.backup.mkdir()
        for name in hook.DATABASES:
            with database(self.root / name) as db:
                db.execute('CREATE TABLE sample (value TEXT)')
                db.execute("INSERT INTO sample VALUES ('original')")
        for name in hook.CONFIGS:
            (self.var / name).write_text('test\n')
        (self.var / 'server-overrides').write_text('KEEPS_ROOT=' + str(self.root) + '\n')
        (self.root / 'maintenance').mkdir()
        (self.root / 'maintenance/operation.json').write_text('{"complete":true}')
        (self.root / 'previews').mkdir()
        (self.root / 'previews/cache.jpg').write_bytes(b'cache')
        self.original = self.base / 'original.raw'
        self.original.write_bytes(b'original image')
        (self.var / 'original-root').write_text(str(self.base) + '\n')
        self.addCleanup(patch.stopall)
        patch.object(hook, 'VAR', self.var).start()
        self.controller = patch.object(hook.subprocess, 'run').start()
        self.controller.return_value.stdout = '{"status":"stop"}\n'
        self.controller.return_value.stderr = ''
        self.controller.return_value.returncode = 17

    def export(self):
        hook.export_state(self.backup)

    def test_backup_hooks_are_packaged_and_executable(self):
        pack_spec = importlib.util.spec_from_file_location('spk_pack', ROOT / 'pack.py')
        packer = importlib.util.module_from_spec(pack_spec)
        pack_spec.loader.exec_module(packer)
        payload = self.base / 'payload'
        (payload / 'bin').mkdir(parents=True)
        (payload / 'runtime').mkdir()
        binary = payload / 'bin/keeps-server'
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        output = self.base / 'test.spk'
        packer.pack(payload, output)
        with tarfile.open(output) as archive:
            self.assertFalse(any('__pycache__' in name or name.endswith('.pyc') for name in archive.getnames()))
            self.assertEqual(archive.extractfile('scripts/backup/version').read().strip(), b'1.0')
            self.assertEqual(json.load(archive.extractfile('scripts/backup/info')),
                             {'online_backup': False, 'external_data': []})
            for name in ('can_export', 'can_import', 'export', 'import'):
                self.assertEqual(archive.getmember('scripts/backup/' + name).mode, 0o755)
                self.assertIn(b'/usr/bin/python3', archive.extractfile('scripts/backup/' + name).read())
            self.assertIsNotNone(archive.getmember('scripts/backup/hook.py'))

    def test_roundtrip_preserves_previous_state_and_excludes_images(self):
        self.export()
        self.assertFalse((self.backup / 'keeps/previews').exists())
        for name in hook.DATABASES:
            with database(self.root / name) as db:
                db.execute("UPDATE sample SET value='newer'")
        (self.var / 'access-token').write_text('new token')
        hook.import_state(self.backup)
        saved = next((self.root / 'backups').glob('restore-before-*'))
        for name in hook.DATABASES:
            with database(self.root / name) as db:
                self.assertEqual(db.execute('SELECT value FROM sample').fetchone()[0], 'original')
            with database(saved / name) as db:
                self.assertEqual(db.execute('SELECT value FROM sample').fetchone()[0], 'newer')
        self.assertEqual((saved / 'config/access-token').read_text(), 'new token')
        self.assertEqual(self.original.read_bytes(), b'original image')
        self.assertEqual((self.root / 'previews/cache.jpg').read_bytes(), b'cache')
        self.assertEqual((self.root / 'maintenance/operation.json').read_text(), '{"complete":true}')

    def test_restore_changes_sync_generation_without_changing_catalog_revision(self):
        path = self.root / hook.DATABASES[0]
        with database(path) as db:
            db.executescript("""
                CREATE TABLE catalog_sync_state(library_id TEXT PRIMARY KEY, generation TEXT, floor INTEGER);
                CREATE TABLE catalog_version_revision(library_id TEXT PRIMARY KEY, revision INTEGER);
                CREATE TABLE catalog_replicas(replica_id TEXT);
                INSERT INTO catalog_sync_state VALUES('lib','old-generation',10);
                INSERT INTO catalog_version_revision VALUES('lib',42);
                INSERT INTO catalog_replicas VALUES('phone');
            """)
        self.export()
        hook.import_state(self.backup)
        with database(path) as db:
            generation, floor = db.execute('SELECT generation,floor FROM catalog_sync_state').fetchone()
            self.assertNotEqual(generation, 'old-generation')
            self.assertEqual(str(hook.uuid.UUID(generation)), generation)
            self.assertEqual(floor, 42)
            self.assertEqual(db.execute('SELECT revision FROM catalog_version_revision').fetchone()[0], 42)
            self.assertEqual(db.execute('SELECT count(*) FROM catalog_replicas').fetchone()[0], 0)
        with database(self.backup / 'keeps' / hook.DATABASES[0]) as db:
            self.assertEqual(db.execute('SELECT generation FROM catalog_sync_state').fetchone()[0], 'old-generation')

    def test_corrupt_second_database_rejected_before_any_live_write(self):
        self.export()
        first = (self.root / hook.DATABASES[0]).read_bytes()
        (self.backup / 'keeps' / hook.DATABASES[1]).write_bytes(b'broken')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            hook.import_state(self.backup)
        self.assertEqual((self.root / hook.DATABASES[0]).read_bytes(), first)
        self.assertFalse((self.root / 'backups').exists())

    def test_insufficient_export_space_writes_nothing(self):
        with patch.object(hook.shutil, 'disk_usage') as disk_usage:
            disk_usage.return_value.free = 0
            with self.assertRaisesRegex(RuntimeError, 'Insufficient backup destination space'):
                self.export()
        self.assertEqual(list(self.backup.iterdir()), [])

    def test_active_service_refuses_export_and_import(self):
        self.export()
        self.controller.return_value.stdout = '{"status":"running"}\n'
        self.controller.return_value.returncode = 0
        for action in (hook.export_state, hook.import_state):
            with self.assertRaisesRegex(RuntimeError, 'must be stopped'):
                action(self.backup)

    def test_unknown_package_status_refuses_export(self):
        for stdout, returncode in [('not json', 1), ('{}', 0), ('[]', 0),
                                   ('{"status":"unknown"}', 0), ('{"status":"stop"}', 1)]:
            with self.subTest(stdout=stdout, returncode=returncode):
                self.controller.return_value.stdout = stdout
                self.controller.return_value.stderr = 'status diagnostic'
                self.controller.return_value.returncode = returncode
                with self.assertRaisesRegex(RuntimeError, 'status diagnostic'):
                    self.export()
                self.assertFalse((self.backup / 'keeps').exists())

    def test_restore_keeps_current_root_in_configuration(self):
        self.export()
        new_root = self.base / 'relocated'
        (self.var / 'server-overrides').write_text('KEEPS_ROOT=' + str(new_root) + '\n')
        hook.import_state(self.backup)
        self.assertEqual(hook.state_root(), new_root)
        self.assertTrue((new_root / hook.DATABASES[0]).is_file())

    def test_restore_inherits_existing_ownership(self):
        self.export()
        with patch.object(hook.os, 'chown') as chown:
            hook.import_state(self.backup)
        owner = self.var.stat()
        chown.assert_any_call(str(self.var / 'access-token.restore'), owner.st_uid, owner.st_gid)
        owner = (self.root / 'db').stat()
        chown.assert_any_call(str(self.root / 'db/jobs.restore'), owner.st_uid, owner.st_gid)

    def test_sqlite_wal_rows_are_included(self):
        path = self.root / hook.DATABASES[0]
        with database(path) as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute("INSERT INTO sample VALUES ('wal-row')")
            db.commit()
            self.export()
            with database(self.backup / 'keeps' / hook.DATABASES[0]) as restored:
                self.assertEqual(restored.execute('SELECT COUNT(*) FROM sample').fetchone()[0], 2)
                self.assertEqual(restored.execute('PRAGMA journal_mode').fetchone()[0], 'delete')
            hook.validate_backup(self.backup)
            self.assertFalse(list((self.backup / 'keeps/db').glob('*-wal')))
            self.assertFalse(list((self.backup / 'keeps/db').glob('*-shm')))


if __name__ == '__main__':
    unittest.main()
