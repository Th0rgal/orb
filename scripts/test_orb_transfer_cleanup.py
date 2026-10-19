"""Regression tests for the production SQLite transfer lifecycle migration."""
import json
from pathlib import Path
import re
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / 'src/api/mission_store/transfer_cleanup.sql').read_text()
SCHEMA = re.search(r'const SCHEMA:&str="([^"]+)";', (ROOT / 'src/api/mission_store/sqlite_transfer.rs').read_text()).group(1)

class TransferCleanup(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', isolation_level=None)
        self.addCleanup(self.db.close)
        self.db.execute('CREATE TABLE missions(id TEXT PRIMARY KEY)')
        self.db.executescript(SCHEMA)
        self.db.executescript(SQL)

    def add(self, mid='source', phase='preparing', revision=0, present=True):
        if present:
            self.db.execute('INSERT OR IGNORE INTO missions VALUES(?)', (mid,))
        data = dict(phase=phase, revision=revision, source_root='/shared', context='retained history', receipt={'keep': True})
        self.db.execute('INSERT INTO machine_transfers VALUES(?,?,?,?,?,?,?)', (mid, mid, mid, revision, phase, json.dumps(data), '2020-01-01'))

    def row(self, mid='source'):
        row = self.db.execute('SELECT phase,revision,data FROM machine_transfers WHERE id=?', (mid,)).fetchone()
        return row[0], row[1], json.loads(row[2])

    def test_delete_cancels_each_unfinished_phase_and_releases_shared_fence(self):
        for phase in ['preparing', 'copying', 'verified']:
            with self.subTest(phase=phase):
                self.add(phase, phase, 4)
                self.db.execute('DELETE FROM missions WHERE id=?', (phase,))
                status, revision, data = self.row(phase)
                self.assertEqual((status, revision, data['phase'], data['revision']), ('cancelled', 5, 'cancelled', 5))
                self.assertEqual(data['context'], 'retained history')
                self.assertEqual(data['receipt'], {'keep': True})
        self.assertEqual(self.db.execute("SELECT count(*) FROM machine_transfers WHERE phase NOT IN ('activated','cancelled') AND json_extract(data,'$.source_root')='/shared'").fetchone()[0], 0)

    def test_existing_shared_source_remains_fenced(self):
        self.add()
        self.db.execute("INSERT INTO missions VALUES('unrelated')")
        self.db.execute("DELETE FROM missions WHERE id='unrelated'")
        self.db.executescript(SQL)
        self.assertEqual(self.row()[:2], ('preparing', 0))

    def test_terminal_receipts_unchanged(self):
        for phase in ['activated', 'cancelled']:
            self.add(phase, phase, 7)
            before = self.row(phase)
            self.db.execute('DELETE FROM missions WHERE id=?', (phase,))
            self.db.executescript(SQL)
            self.assertEqual(self.row(phase), before)

    def test_recovery_is_idempotent_and_only_repairs_missing_sources(self):
        self.add('orphan', present=False)
        self.add('live')
        self.db.executescript(SQL)
        self.assertEqual(self.row('orphan')[:2], ('cancelled', 1))
        self.assertEqual(self.row('live')[:2], ('preparing', 0))
        self.db.executescript(SQL)
        self.assertEqual(self.row('orphan')[:2], ('cancelled', 1))

    def test_delete_rollback_restores_fence_and_source_atomically(self):
        self.add()
        self.db.execute('BEGIN IMMEDIATE')
        self.db.execute("DELETE FROM missions WHERE id='source'")
        self.assertEqual(self.row()[0], 'cancelled')
        self.db.rollback()
        self.assertEqual(self.row()[:2], ('preparing', 0))
        self.assertEqual(self.db.execute('SELECT count(*) FROM missions').fetchone()[0], 1)

    def test_stale_adapter_revision_cannot_restore_fence(self):
        self.add()
        self.db.execute("DELETE FROM missions WHERE id='source'")
        cur = self.db.execute("UPDATE machine_transfers SET phase='copying' WHERE id='source' AND revision=0")
        self.assertEqual(cur.rowcount, 0)
        self.assertEqual(self.row()[0], 'cancelled')

    def test_bulk_deletion_cancels_only_deleted_sources(self):
        for mid in ['one', 'two', 'keep']:
            self.add(mid)
        self.db.execute("DELETE FROM missions WHERE id IN ('one','two')")
        self.assertEqual([self.row(mid)[0] for mid in ['one','two','keep']], ['cancelled','cancelled','preparing'])

if __name__ == '__main__':
    unittest.main()
