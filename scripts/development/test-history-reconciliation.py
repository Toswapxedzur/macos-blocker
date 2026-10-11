#!/usr/bin/env python3
"""Run on mini1 only; all refs/remotes/receipts below are disposable fixtures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("delivery_candidate",Path(__file__).with_name("vault-delivery.py"))
delivery=importlib.util.module_from_spec(spec);spec.loader.exec_module(delivery)

class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name).resolve()
        self.repo=self.base/'shared';self.remote=self.base/'origin.git';self.source=self.base/'rewritten'
        self.run_git(self.base,'init','--bare',str(self.remote));self.run_git(self.base,'init','-b',delivery.BRANCH,str(self.repo))
        self.run_git(self.repo,'config','user.name','Disposable fixture');self.run_git(self.repo,'config','user.email','fixture@example.invalid')
        self.run_git(self.repo,'config','vault.deliveryCheckout',str(self.repo))
        (self.repo/'accepted').write_text('accepted source');self.commit(self.repo,'old accepted base')
        self.old=self.git(self.repo,'rev-parse','HEAD');self.tree=self.git(self.repo,'rev-parse','HEAD^{tree}')
        (self.repo/'initial-linking-fix').write_text('old verified task work');self.commit(self.repo,'old linking work')
        self.before=self.git(self.repo,'rev-parse','HEAD')
        self.old_source=self.base/'old-source'
        self.run_git(self.repo,'worktree','add','--detach',str(self.old_source),self.before)
        (self.old_source/'follow-up-linking-fix').write_text('new task work');self.commit(self.old_source,'old reviewed task')
        self.old_task=self.git(self.old_source,'rev-parse','HEAD')
        self.run_git(self.repo,'remote','add','origin',str(self.remote))
        self.run_git(self.repo,'worktree','add','--detach',str(self.source),self.old)
        self.run_git(self.source,'checkout','--orphan','fixture-rewritten');self.commit(self.source,'rewritten equal accepted source')
        self.new=self.git(self.source,'rev-parse','HEAD')
        self.run_git(self.source,'push','origin','HEAD:refs/heads/'+delivery.BRANCH)
        self.run_git(self.repo,'fetch','origin');self.run_git(self.repo,'branch','--set-upstream-to=origin/'+delivery.BRANCH)
        (self.source/'initial-linking-fix').write_text('old verified task work')
        (self.source/'follow-up-linking-fix').write_text('new task work');self.commit(self.source,'rewritten linking task')
        self.candidate=self.git(self.source,'rev-parse','HEAD')
        self.policy={'tree':self.tree,'oldCheckout':self.before,'oldSource':self.old_task,
                     'candidate':self.candidate,'sourceTree':self.git(self.source,'rev-parse','HEAD^{tree}')}
        self.patches=[patch.object(delivery,'ROOT',self.repo),patch.object(delivery,'APPROVED_REMOTE_URL',str(self.remote)),
                      patch.object(delivery,'APPROVED_CHECKOUT',self.repo),
                      patch.object(delivery,'SUPPORTED_RECONCILIATIONS',{(self.old,self.new):self.policy})]
        for p in self.patches:p.start()
        self.common=delivery.context()
        self.original={'verified':{'commit':self.before,'host':'mini1','checks':['real fixture verification']},
                       'delivered':{'commit':self.old,'checkout':str(self.repo),'pid':123,'at':1}}
        delivery.write_state(self.common,self.original);self.original_raw=(self.common/'vault-delivery.json').read_bytes()
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def run_git(self,root,*args):
        subprocess.run(['git','-C',str(root),*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    def git(self,root,*args):return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()
    def commit(self,root,message):self.run_git(root,'add','.');self.run_git(root,'commit','-m',message)
    def reconcile(self):delivery.reconcile_history(self.common,self.source,self.old,self.new)
    def verify_and_push(self):
        # Unit fixture evidence only; no real launch or remote build is claimed.
        state=delivery.read_state(self.common);state['verified']={'commit':self.git(self.repo,'rev-parse','HEAD'),'host':'mini1'}
        delivery.write_state(self.common,state);self.run_git(self.repo,'push','origin',delivery.BRANCH)
    def assert_no_adoption(self):
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.before)
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(),self.original_raw)
        self.assertFalse(delivery.snapshot_path(self.common,self.old,self.new).exists())
    def test_preserves_exact_original_receipt_and_refs_then_requires_fresh_verify_push(self):
        with patch.object(delivery,'verify') as verify,patch.object(delivery,'launch') as launch:self.reconcile()
        verify.assert_not_called();launch.assert_not_called()
        state=delivery.read_state(self.common)
        self.assertEqual(state['delivered'],self.original['delivered']);self.assertNotIn('verified',state)
        self.assertEqual(delivery.snapshot_path(self.common,self.old,self.new).read_bytes(),self.original_raw)
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.candidate)
        self.assertEqual(self.git(self.remote,'rev-parse','refs/heads/'+delivery.BRANCH),self.new)
        prefix=delivery.ref_prefix(self.old,self.new)
        self.assertEqual(self.git(self.repo,'rev-parse',prefix+'old-checkout'),self.before)
        self.assertEqual(self.git(self.repo,'rev-parse',prefix+'old-source'),self.old_task)
        with self.assertRaisesRegex(RuntimeError,'remote verification'):delivery.check_launch(self.common)
        state['verified']={'commit':self.candidate,'host':'mini1'};delivery.write_state(self.common,state)
        with self.assertRaisesRegex(RuntimeError,'Push'):delivery.check_launch(self.common)
        self.verify_and_push();self.assertEqual(delivery.check_launch(self.common)[0],self.candidate)
        remote_history=set(self.git(self.remote,'rev-list','refs/heads/'+delivery.BRANCH).splitlines())
        self.assertNotIn(self.old,remote_history);self.assertNotIn(self.before,remote_history)
    def test_unsupported_mapping_is_refused_before_mutation(self):
        with self.assertRaisesRegex(RuntimeError,'Unsupported'):delivery.reconcile_history(self.common,self.source,self.before,self.new)
        self.assert_no_adoption()
    def test_unequal_tree_is_refused_before_mutation(self):
        with patch.object(delivery,'SUPPORTED_RECONCILIATIONS',{(self.old,self.candidate):self.policy}):
            with self.assertRaisesRegex(RuntimeError,'equal source trees'):delivery.reconcile_history(self.common,self.source,self.old,self.candidate)
        self.assert_no_adoption()
    def test_missing_old_commit_is_refused(self):
        missing='f'*40
        with patch.object(delivery,'SUPPORTED_RECONCILIATIONS',{(missing,self.new):self.policy}):
            with self.assertRaises(subprocess.CalledProcessError):delivery.reconcile_history(self.common,self.source,missing,self.new)
        self.assert_no_adoption()
    def test_changed_remote_or_tracking_base_is_refused(self):
        self.run_git(self.source,'push','origin','HEAD:refs/heads/'+delivery.BRANCH)
        with self.assertRaisesRegex(RuntimeError,'actual remote'):self.reconcile()
        self.assert_no_adoption()
        self.run_git(self.repo,'fetch','origin')
        with self.assertRaisesRegex(RuntimeError,'tracking'):self.reconcile()
        self.assert_no_adoption()
    def test_wrong_remote_repository_or_upstream_is_refused(self):
        with patch.object(delivery,'APPROVED_REMOTE_URL',str(self.base/'wrong.git')):
            with self.assertRaisesRegex(RuntimeError,'approved repository'):self.reconcile()
        self.assert_no_adoption()
    def test_dirty_shared_and_dirty_source_are_refused(self):
        (self.repo/'unfinished').write_text('owner work')
        with self.assertRaisesRegex(RuntimeError,'uncommitted'):self.reconcile()
        (self.repo/'unfinished').unlink();(self.source/'unfinished').write_text('owner work')
        with self.assertRaisesRegex(RuntimeError,'uncommitted'):self.reconcile()
        self.assert_no_adoption()
    def test_source_not_descended_from_rewritten_base_is_refused(self):
        self.run_git(self.source,'checkout','--detach',self.before)
        with self.assertRaisesRegex(RuntimeError,'exact reviewed commits'):self.reconcile()
        self.assert_no_adoption()
    def test_old_history_merge_is_refused_even_with_new_base_ancestry(self):
        self.run_git(self.source,'merge','--allow-unrelated-histories','--no-edit',self.before)
        with self.assertRaisesRegex(RuntimeError,'exact reviewed commits'):self.reconcile()
        self.assert_no_adoption()
    def test_different_repository_source_is_refused(self):
        other=self.base/'other';self.run_git(self.base,'clone',str(self.remote),str(other))
        with self.assertRaisesRegex(RuntimeError,'same repository'):delivery.reconcile_history(self.common,other,self.old,self.new)
        self.assert_no_adoption()
    def test_preservation_ref_collision_is_refused(self):
        self.run_git(self.repo,'update-ref',delivery.ref_prefix(self.old,self.new)+'old-delivered',self.before)
        with self.assertRaisesRegex(RuntimeError,'Preservation refs'):self.reconcile()
        self.assert_no_adoption()
    def test_existing_record_is_not_overwritten_or_replayed(self):
        self.reconcile();raw=(self.common/'vault-delivery.json').read_bytes()
        with self.assertRaisesRegex(RuntimeError,'existing reconciliation'):self.reconcile()
        self.assertEqual(raw,(self.common/'vault-delivery.json').read_bytes())
    def test_archive_tampering_and_missing_preserved_ref_hold_launch(self):
        self.reconcile();self.verify_and_push();archive=delivery.snapshot_path(self.common,self.old,self.new)
        original=archive.read_bytes();archive.write_bytes(original+b' ')
        with self.assertRaisesRegex(RuntimeError,'bytes changed'):delivery.check_launch(self.common)
        archive.write_bytes(original);self.run_git(self.repo,'update-ref','-d',delivery.ref_prefix(self.old,self.new)+'old-checkout')
        with self.assertRaises(subprocess.CalledProcessError):delivery.check_launch(self.common)
    def test_changed_delivered_receipt_fields_hold_launch(self):
        self.reconcile();self.verify_and_push();state=delivery.read_state(self.common);state['delivered']['pid']=999
        delivery.write_state(self.common,state)
        with self.assertRaisesRegex(RuntimeError,'fields changed'):delivery.check_launch(self.common)
    def test_exact_live_remote_is_required_at_launch(self):
        self.reconcile();self.verify_and_push();self.run_git(self.remote,'update-ref','refs/heads/'+delivery.BRANCH,self.new)
        with self.assertRaisesRegex(RuntimeError,'actual remote'):delivery.check_launch(self.common)
    def test_old_lineage_rollback_cannot_use_mapping(self):
        self.reconcile();self.run_git(self.repo,'reset','--hard',self.before)
        # Simulate a bad local fixture ref rewrite; never force-push a real remote.
        self.run_git(self.remote,'fetch',str(self.repo),self.before)
        self.run_git(self.remote,'update-ref','refs/heads/'+delivery.BRANCH,self.before)
        self.run_git(self.repo,'fetch','origin')
        state=delivery.read_state(self.common);state['verified']={'commit':self.before,'host':'mini1'}
        delivery.write_state(self.common,state)
        with self.assertRaisesRegex(RuntimeError,'canonical lineage'):delivery.check_launch(self.common)
    def test_incomplete_reconciliation_holds_launch_even_on_old_lineage(self):
        state=dict(self.original);state['historyReconciliations']=[{'version':1,'stage':'prepared','oldBase':self.old}]
        delivery.write_state(self.common,state)
        with self.assertRaisesRegex(RuntimeError,'incomplete'):delivery.check_launch(self.common)
    def test_interrupted_adoption_preserves_evidence_and_holds_delivery(self):
        real_run=subprocess.run
        def fail_reset(command,**kwargs):
            if command[:4]==['git','-C',str(self.repo),'reset']:
                raise subprocess.CalledProcessError(1,command)
            return real_run(command,**kwargs)
        with patch.object(delivery.subprocess,'run',side_effect=fail_reset):
            with self.assertRaises(subprocess.CalledProcessError):self.reconcile()
        self.assertEqual(delivery.snapshot_path(self.common,self.old,self.new).read_bytes(),self.original_raw)
        self.assertEqual(delivery.read_state(self.common)['historyReconciliations'][0]['stage'],'prepared')
        with self.assertRaisesRegex(RuntimeError,'incomplete'):delivery.check_launch(self.common)
        with self.assertRaisesRegex(RuntimeError,'existing reconciliation'):self.reconcile()
    def test_explicit_bootstrap_routes_only_to_registered_same_repo_checkout(self):
        # Reviewed offline artifact is outside both source and shared checkout.
        with patch.object(delivery,'ROOT',self.base/'offline-artifact'),patch.object(sys,'argv',['candidate','reconcile-history','--source',str(self.source),'--old-base',self.old,'--new-base',self.new]):
            delivery.main()
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.candidate)
    def test_other_commands_cannot_bootstrap_from_task_checkout(self):
        with patch.object(delivery,'ROOT',self.source),patch.object(sys,'argv',['candidate','status']):
            with self.assertRaisesRegex(RuntimeError,'Use the shared command'):delivery.main()
    def test_bootstrap_rejects_an_unapproved_registered_path_before_locking_it(self):
        unapproved=self.base/'unapproved';self.run_git(self.repo,'config','vault.deliveryCheckout',str(unapproved))
        with patch.object(delivery,'ROOT',self.base/'offline-artifact'),patch.object(sys,'argv',['candidate','reconcile-history','--source',str(self.source),'--old-base',self.old,'--new-base',self.new]):
            with self.assertRaisesRegex(RuntimeError,'canonical checkout'):delivery.main()
        self.assertFalse(unapproved.exists());self.assert_no_adoption()
    def test_owner_edit_appearing_at_reset_is_not_destroyed(self):
        real_run=subprocess.run
        def edit_at_reset(command,**kwargs):
            if command[:4]==['git','-C',str(self.repo),'reset']:
                (self.repo/'initial-linking-fix').write_text('concurrent owner edit')
            return real_run(command,**kwargs)
        with patch.object(delivery.subprocess,'run',side_effect=edit_at_reset):
            with self.assertRaises(subprocess.CalledProcessError):self.reconcile()
        self.assertEqual((self.repo/'initial-linking-fix').read_text(),'concurrent owner edit')
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.before)
        self.assertEqual(delivery.read_state(self.common)['historyReconciliations'][0]['stage'],'prepared')
    def test_malformed_or_future_reconciliation_record_holds_launch(self):
        for records in ('bad',{'version':1},[{'version':2,'stage':'adopted'}]):
            state=dict(self.original);state['historyReconciliations']=records;delivery.write_state(self.common,state)
            with self.assertRaisesRegex(RuntimeError,'unsupported'):delivery.check_launch(self.common)
    def test_new_unreviewed_shared_commit_is_preserved_and_refused(self):
        (self.repo/'unreviewed').write_text('new owner commit');self.commit(self.repo,'owner work after review')
        head=self.git(self.repo,'rev-parse','HEAD')
        with self.assertRaisesRegex(RuntimeError,'exact reviewed commits'):self.reconcile()
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),head)
        self.assertEqual((self.common/'vault-delivery.json').read_bytes(),self.original_raw)
        self.assertFalse(delivery.snapshot_path(self.common,self.old,self.new).exists())
    def test_new_unreviewed_source_commit_is_refused(self):
        (self.source/'unreviewed').write_text('new task work');self.commit(self.source,'task changed after review')
        with self.assertRaisesRegex(RuntimeError,'exact reviewed commits'):self.reconcile()
        self.assert_no_adoption()
    def test_task_tree_equivalence_is_required(self):
        policy={**self.policy,'oldSource':self.before}
        with patch.object(delivery,'SUPPORTED_RECONCILIATIONS',{(self.old,self.new):policy}):
            with self.assertRaisesRegex(RuntimeError,'source trees differ'):self.reconcile()
        self.assert_no_adoption()
    def test_old_shared_must_be_ancestor_of_reviewed_old_source(self):
        unrelated=self.base/'unrelated-old';self.run_git(self.repo,'worktree','add','--detach',str(unrelated),self.old_task)
        self.run_git(unrelated,'checkout','--orphan','unrelated-old-task');self.commit(unrelated,'same tree unrelated old task')
        policy={**self.policy,'oldSource':self.git(unrelated,'rev-parse','HEAD')}
        with patch.object(delivery,'SUPPORTED_RECONCILIATIONS',{(self.old,self.new):policy}):
            with self.assertRaisesRegex(RuntimeError,'checkout ancestry'):self.reconcile()
        self.assert_no_adoption()
    def test_missing_reviewed_old_source_is_refused(self):
        policy={**self.policy,'oldSource':'f'*40}
        with patch.object(delivery,'SUPPORTED_RECONCILIATIONS',{(self.old,self.new):policy}):
            with self.assertRaises(subprocess.CalledProcessError):self.reconcile()
        self.assert_no_adoption()
    def test_preserved_record_cannot_substitute_unreviewed_source(self):
        self.reconcile();self.verify_and_push();state=delivery.read_state(self.common)
        state['historyReconciliations'][0]['oldSource']=self.before;delivery.write_state(self.common,state)
        with self.assertRaisesRegex(RuntimeError,'original delivered receipt'):delivery.check_launch(self.common)
    def test_mapping_is_restricted_to_the_exact_canonical_checkout(self):
        with patch.object(delivery,'APPROVED_CHECKOUT',self.base/'other-delivery'):
            with self.assertRaisesRegex(RuntimeError,'canonical checkout'):self.reconcile()
        self.assert_no_adoption()
    def test_mapping_remains_guarded_after_a_real_delivery_receipt_replacement(self):
        self.reconcile();self.verify_and_push();state=delivery.read_state(self.common)
        # Simulate only a disposable fixture launch receipt, never a product launch.
        state['delivered']={'commit':self.candidate,'pid':456,'checkout':str(self.repo),'at':2}
        delivery.write_state(self.common,state)
        self.assertEqual(delivery.check_launch(self.common)[0],self.candidate)
        (self.repo/'later-feature').write_text('accepted future canonical work');self.commit(self.repo,'later work')
        self.verify_and_push();self.assertEqual(delivery.check_launch(self.common)[0],self.git(self.repo,'rev-parse','HEAD'))
        self.run_git(self.repo,'merge','--allow-unrelated-histories','--no-edit',self.old_task)
        self.verify_and_push()
        with self.assertRaisesRegex(RuntimeError,'discarded old history'):delivery.check_launch(self.common)
    def test_integrate_refuses_old_history_before_merge(self):
        self.reconcile();self.run_git(self.old_source,'checkout','--detach',self.old_task)
        with self.assertRaisesRegex(RuntimeError,'Integration would bring discarded old history'):
            delivery.integrate(self.common,self.old_source)
        self.assertEqual(self.git(self.repo,'rev-parse','HEAD'),self.candidate)
    def test_verify_rejects_old_history_before_any_remote_build_or_receipt(self):
        self.reconcile();self.run_git(self.repo,'merge','--allow-unrelated-histories','--no-edit',self.old_task)
        raw=(self.common/'vault-delivery.json').read_bytes()
        real_popen=subprocess.Popen;exports=[]
        def observe_export(command,**kwargs):
            if command[:4]==['git','-C',str(self.repo),'archive']:exports.append(command)
            return real_popen(command,**kwargs)
        with patch.object(delivery.subprocess,'Popen',side_effect=observe_export):
            with self.assertRaisesRegex(RuntimeError,'discarded old history'):delivery.verify(self.common)
        self.assertEqual(exports,[]);self.assertEqual((self.common/'vault-delivery.json').read_bytes(),raw)

if __name__=='__main__':unittest.main(verbosity=2)
