#!/usr/bin/env python3
"""Validate changelog contract, ordering and safe embedded-data generation."""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'generators'))
import build_changelog as generator


class ChangelogTests(unittest.TestCase):
    def entry(self, version='0.1.0', status='implemented'):
        return {'version': version, 'date': '2026-10-25', 'status': status, 'title': '样例', 'changes': ['可读变化']}

    def data(self, entries):
        return {'schemaVersion': 1, 'entries': entries}

    def test_versions_are_sorted_numerically(self):
        entries = generator.validate(self.data([self.entry('0.9.0'), self.entry('0.10.0'), self.entry('1.0.0')]))
        self.assertEqual([x['version'] for x in entries], ['1.0.0', '0.10.0', '0.9.0'])

    def test_pending_is_kept_in_full_history_but_not_in_recent_three(self):
        entries = generator.validate(self.data([self.entry('0.5.0', 'pending'), self.entry('0.4.0'), self.entry('0.3.0'), self.entry('0.2.0'), self.entry('0.1.0')]))
        self.assertEqual(len(entries), 5)
        self.assertEqual([x['version'] for x in generator.recent(entries)], ['0.4.0', '0.3.0', '0.2.0'])

    def test_internal_entries_are_hidden_from_user_visible(self):
        pending = self.entry('0.6.0', 'pending')
        internal = self.entry('0.5.0', 'implemented')
        internal['internal'] = True
        visible = self.entry('0.4.0')
        entries = generator.validate(self.data([pending, internal, visible]))
        self.assertEqual([x['version'] for x in generator.user_visible(entries)], ['0.4.0'])
        self.assertEqual([x['version'] for x in generator.recent(entries)], ['0.4.0'])

    def test_bad_internal_flag_and_notes_fail(self):
        for field, value in [('internal', 'yes'), ('notes', 'text'), ('notes', ['ok', '']), ('notes', [1])]:
            with self.subTest(field=field, value=value):
                entry = copy.deepcopy(self.entry())
                entry[field] = value
                with self.assertRaises(ValueError):
                    generator.validate(self.data([entry]))

    def test_valid_notes_are_kept(self):
        entry = self.entry()
        entry['internal'] = False
        entry['notes'] = ['内部备注']
        self.assertEqual(generator.validate(self.data([entry]))[0]['notes'], ['内部备注'])

    def test_duplicate_versions_fail(self):
        with self.assertRaises(ValueError):
            generator.validate(self.data([self.entry(), self.entry()]))

    def test_bad_status_date_and_empty_changes_fail(self):
        for field, value in [('status', 'unknown'), ('date', '2026-02-30'), ('changes', []), ('title', '')]:
            with self.subTest(field=field):
                entry = copy.deepcopy(self.entry())
                entry[field] = value
                with self.assertRaises(ValueError):
                    generator.validate(self.data([entry]))

    def test_invalid_version_and_schema_fail(self):
        for data in [self.data([self.entry('next')]), {'schemaVersion': 2, 'entries': []}]:
            with self.assertRaises(ValueError):
                generator.validate(data)

    def test_embedded_html_script_terminator_is_escaped_without_losing_text(self):
        value = '</script><script>unexpected()</script>\u2028\u2029'
        encoded = generator.quoted(value)
        self.assertNotIn('<', encoded)
        self.assertNotIn('\u2028', encoded)
        self.assertNotIn('\u2029', encoded)
        self.assertEqual(json.loads(encoded), value)


if __name__ == '__main__':
    unittest.main()
