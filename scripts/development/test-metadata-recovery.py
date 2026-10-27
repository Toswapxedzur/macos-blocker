#!/usr/bin/env python3
"""Disposable Git/local-remote tests; run on the owner-selected test host only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('original_fixtures', Path(__file__).with_name('test-history-reconciliation.py'))
original = importlib.util.module_from_spec(spec); spec.loader.exec_module(original)
delivery = original.delivery


class MetadataRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = original.ReconciliationTests(); self.fixture.setUp()
        f = self.fixture
        self.git, self.run_git, self.commit = f.git, f.run_git, f.commit
        self.repo, self.source, self.common, self.remote = f.repo, f.source, f.common, f.remote
        f.reconcile(); f.verify_and_push()
        state = delivery.read_state(self.common)
        state['delivered']['commit'] = f.candidate
        delivery.write_state(self.common, state)
        self.before = (self.common / 'vault-delivery.json').read_bytes()
        self.record = state['historyReconciliations'][0]
        self.historical = delivery.snapshot_path(self.common, f.old, f.new).read_bytes()
        aliases = {}
        def rewrite(sha):
            if sha in aliases: return aliases[sha]
            tree = self.git(self.repo, 'rev-parse', sha + '^{tree}')
            parents = self.git(self.repo, 'show', '-s', '--format=%P', sha).split()
            args = ['git', '-C', str(self.repo), 'commit-tree', tree]
            for parent in parents: args += ['-p', rewrite(parent)]
            env = dict(os.environ, GIT_AUTHOR_NAME='Metadata fixture', GIT_AUTHOR_EMAIL='rewrite@example.invalid',
                       GIT_COMMITTER_NAME='Metadata fixture', GIT_COMMITTER_EMAIL='rewrite@example.invalid')
            aliases[sha] = subprocess.check_output(args, input='Rewritten ' + sha + '\n', text=True, env=env).strip()
            return aliases[sha]
        for sha in [f.old, f.before, f.old_task, f.new, f.candidate]: rewrite(sha)
        self.head = aliases[f.candidate]
        self.run_git(self.repo, 'reset', '--hard', self.head)
        self.run_git(self.source, 'reset', '--hard', self.head)
        self.run_git(self.source, 'checkout', '-b', 'recovery-source')
        (self.source/'task-feature').write_text('reviewed feature')
        self.commit(self.source, 'reviewed feature base'); minimum = self.git(self.source, 'rev-parse', 'HEAD')
        (self.source/'controller').write_text('reviewed recovery implementation')
        self.commit(self.source, 'controller only'); self.source_head = self.git(self.source, 'rev-parse', 'HEAD')
        self.run_git(self.source, 'push', '-u', 'origin', 'recovery-source')
        self.run_git(self.remote, 'update-ref', 'refs/heads/' + delivery.BRANCH, self.head)
        self.run_git(self.repo, 'fetch', 'origin')
        self.old_refs = delivery.ref_prefix(f.old, f.new)
        for name, sha in [('old-delivered',f.old),('old-checkout',f.before),('old-source',f.old_task),('new-base',f.new),('candidate',f.candidate)]:
            self.run_git(self.repo, 'update-ref', self.old_refs + name, aliases[sha])
        self.policy_id = 'fixture-approved-rewrite'
        self.policy = dict(integrationHead=self.head, minimumSource=minimum, stateSHA256=hashlib.sha256(self.before).hexdigest(),
                           reconciliationOld=f.old, reconciliationNew=f.new, delivered=f.candidate,
                           allowedSourcePaths=['controller'], aliases=aliases)
        self.policy_patch = patch.object(delivery, 'SUPPORTED_METADATA_RECOVERIES', {self.policy_id:self.policy}); self.policy_patch.start()
        self.path = delivery.metadata_archive_path(self.common, self.policy_id)
        self.prefix = delivery.metadata_ref_prefix(self.policy_id)

    def tearDown(self):
        self.policy_patch.stop(); self.fixture.tearDown()

    def recover(self): delivery.recover_metadata_history(self.common, self.source, self.policy_id)
    def assert_untouched(self):
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(), self.before)
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.head)
        self.assertFalse(self.git(self.repo,'for-each-ref','--format=%(refname)',self.prefix))

    def test_adoption_preserves_receipts_refs_and_head_then_normal_merge_verify_push(self):
        with self.assertRaisesRegex(RuntimeError,'preserved reconciliation ref'): delivery.validate_reconciled_lineage(self.common,delivery.read_state(self.common),self.head)
        refs_before=self.git(self.repo,'for-each-ref','--format=%(refname) %(objectname)',self.old_refs)
        self.recover(); state=delivery.read_state(self.common)
        self.assertEqual(self.path.read_bytes(),self.before)
        self.assertEqual(delivery.snapshot_path(self.common,self.fixture.old,self.fixture.new).read_bytes(),self.historical)
        self.assertEqual(state['historyReconciliations'],[self.record]); self.assertNotIn('verified',state)
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.head)
        self.assertEqual(self.git(self.repo,'for-each-ref','--format=%(refname) %(objectname)',self.old_refs),refs_before)
        delivery.integrate(self.common,self.source)
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.source_head)
        with self.assertRaisesRegex(RuntimeError,'remote verification'): delivery.check_launch(self.common)
        state=delivery.read_state(self.common);state['verified']={'commit':self.source_head,'host':'mini2'};delivery.write_state(self.common,state)
        with self.assertRaisesRegex(RuntimeError,'Push'):delivery.check_launch(self.common)
        self.run_git(self.repo,'push','origin',delivery.BRANCH)
        self.assertEqual(delivery.check_launch(self.common)[0],self.source_head)
        self.assertFalse(self.git(self.remote,'for-each-ref','--format=%(refname)',self.prefix))

    def test_explicit_bootstrap_uses_the_registered_checkout_and_normally_integrates(self):
        with patch.object(delivery,'ROOT',self.source), patch('sys.argv',['vault-delivery.py','recover-metadata-history','--source',str(self.source),'--policy',self.policy_id]), patch.object(delivery,'verify') as verify, patch.object(delivery,'launch') as launch:
            delivery.main()
        verify.assert_not_called(); launch.assert_not_called()
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.source_head)
        self.assertEqual(self.path.read_bytes(),self.before)

    def test_source_remote_drift_cannot_mutate(self):
        self.run_git(self.remote,'update-ref','refs/heads/recovery-source',self.head)
        with self.assertRaisesRegex(RuntimeError,'source must be pushed'):self.recover()
        self.assert_untouched()

    def test_unsupported_policy_cannot_mutate(self):
        with self.assertRaisesRegex(RuntimeError,'Unsupported'):delivery.recover_metadata_history(self.common,self.source,'unreviewed')
        self.assert_untouched()
    def test_unequal_alias_tree_cannot_mutate(self):
        self.policy['aliases'][self.fixture.old_task]=self.policy['aliases'][self.fixture.new]
        with self.assertRaisesRegex(RuntimeError,'different source trees'):self.recover()
        self.assert_untouched()
    def test_receipt_drift_cannot_mutate(self):
        (self.common/'vault-delivery.json').write_bytes(self.before+b'\n');changed=(self.common/'vault-delivery.json').read_bytes()
        with self.assertRaisesRegex(RuntimeError,'receipt changed'):self.recover()
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(),changed);self.assertFalse(self.path.exists())
    def test_original_archive_tampering_cannot_mutate(self):
        delivery.snapshot_path(self.common,self.fixture.old,self.fixture.new).write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError,'Original reconciliation receipt'):self.recover()
        self.assert_untouched()
    def test_remote_drift_cannot_mutate(self):
        self.run_git(self.remote,'update-ref','refs/heads/'+delivery.BRANCH,self.source_head)
        with self.assertRaisesRegex(RuntimeError,'remote changed'):self.recover()
        self.assert_untouched()
    def test_unreviewed_source_changes_cannot_mutate(self):
        (self.source/'unreviewed').write_text('unapproved product changes');self.commit(self.source,'unreviewed')
        self.run_git(self.source,'push','origin','recovery-source')
        with self.assertRaisesRegex(RuntimeError,'outside the reviewed controller scope'):self.recover()
        self.assert_untouched()
    def test_dirty_source_cannot_mutate(self):
        (self.source/'controller').write_text('unsaved')
        with self.assertRaisesRegex(RuntimeError,'uncommitted'):self.recover()
        self.assert_untouched()
    def test_partial_preservation_cannot_be_replayed(self):
        self.path.write_bytes(self.before)
        with self.assertRaisesRegex(RuntimeError,'Partial metadata preservation'):self.recover()
        self.assert_untouched()
    def test_preserved_alias_drift_is_rejected_after_adoption(self):
        self.recover();self.run_git(self.repo,'update-ref',self.old_refs+'new-base',self.fixture.new)
        with self.assertRaisesRegex(RuntimeError,'preserved reconciliation ref'):delivery.validate_reconciled_lineage(self.common,delivery.read_state(self.common),self.head)
    def test_original_object_preservation_drift_is_rejected(self):
        self.recover();self.run_git(self.repo,'update-ref',self.prefix+'original/'+self.fixture.old,self.fixture.new)
        with self.assertRaisesRegex(RuntimeError,'Metadata preservation ref'):delivery.metadata_aliases(self.common,delivery.read_state(self.common))
    def test_adoption_record_or_receipt_tampering_is_rejected(self):
        self.recover();state=delivery.read_state(self.common);state['metadataRecoveries'][0]['stage']='prepared'
        with self.assertRaisesRegex(RuntimeError,'unsupported or incomplete'):delivery.metadata_aliases(self.common,state)
        self.path.write_bytes(self.before+b'\n')
        with self.assertRaisesRegex(RuntimeError,'receipt changed'):delivery.metadata_aliases(self.common,delivery.read_state(self.common))
    def test_malformed_recovery_records_are_not_ignored(self):
        state=delivery.read_state(self.common);state['metadataRecoveries']={}
        with self.assertRaisesRegex(RuntimeError,'record is invalid'):delivery.metadata_aliases(self.common,state)

if __name__=='__main__':unittest.main()
