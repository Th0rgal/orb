import contextlib
import io
import unittest
import os
import queue
from scripts.remote_codex_app_server import NativeSession, goal_action


class NativeGoalTests(unittest.TestCase):
    def test_full_native_resume_drains_multiple_turns_without_resubmission(self):
        session = NativeSession.__new__(NativeSession)
        session.config = {'model': 'test-model', 'session': 'same-thread', 'prompt': '/goal resume'}
        session.inbound = queue.Queue()
        session.deferred = []
        session.goal_status = None
        session.iteration = 0
        session.seen_turns = set()
        session.pending_hint = None
        calls = []
        goal = {'status':'active', 'objective':'unchanged', 'tokenBudget':None, 'tokensUsed':123}
        def rpc(method, params):
            calls.append((method, params))
            if method == 'thread/resume':
                return {'thread': {'id':'same-thread', 'cwd':os.getcwd(), 'turns':[]}}
            if method == 'thread/goal/get': return {'goal':goal}
            if method == 'thread/goal/set':
                for turn in ('first', 'second'):
                    session.deferred += [
                        {'method':'turn/started', 'params':{'turn':{'id':turn}}},
                        {'method':'turn/completed', 'params':{'turn':{'id':turn,'status':'completed'}}},
                    ]
                session.deferred.append({'method':'thread/goal/updated', 'params':{'goal':dict(goal,status='complete')}})
            return {}
        session.rpc = rpc
        session.send = lambda message: None
        with contextlib.redirect_stdout(io.StringIO()) as output:
            session.run()
        self.assertEqual(session.iteration, 2)
        self.assertEqual([params for method, params in calls if method=='thread/goal/set'], [{'threadId':'same-thread','status':'active'}])
        self.assertFalse(any(method=='turn/start' for method, params in calls))
        self.assertEqual(output.getvalue().count('turn.completed'), 1)

    def test_ordinary_turn_ignores_goal_cleared_and_completes_once(self):
        session = NativeSession.__new__(NativeSession)
        session.config = {'model':'test-model', 'session':'same-thread', 'prompt':'plain task'}
        session.inbound = queue.Queue()
        session.deferred = []
        session.goal_status = None
        session.pending_hint = None
        def rpc(method, params):
            if method == 'thread/resume':
                return {'thread':{'id':'same-thread','cwd':os.getcwd(),'turns':[]}}
            if method == 'thread/goal/get': return {'goal':None}
            if method == 'turn/start':
                session.deferred += [
                    {'method':'thread/goal/cleared','params':{'threadId':'same-thread'}},
                    {'method':'turn/started','params':{'turn':{'id':'one'}}},
                    {'method':'turn/completed','params':{'turn':{'id':'one','status':'completed'}}},
                ]
            return {}
        session.rpc = rpc
        session.send = lambda message: None
        with contextlib.redirect_stdout(io.StringIO()) as output:
            session.run()
        self.assertNotIn('goal.status', output.getvalue())
        self.assertEqual(output.getvalue().count('turn.completed'), 1)

    def test_resume_preserves_native_goal_and_budget(self):
        goal = {'status': 'active', 'objective': 'all roadmap criteria', 'tokenBudget': None, 'tokensUsed': 11314410}
        self.assertEqual(goal_action(goal, '/goal resume'), {'status': 'active'})
        self.assertEqual(goal['tokensUsed'], 11314410)
        with self.assertRaisesRegex(RuntimeError, 'objective differs'):
            goal_action(goal, '/goal unrelated objective')
        with self.assertRaisesRegex(RuntimeError, 'budget exhausted'):
            goal_action(dict(goal, tokenBudget=100), '/goal resume')

    def test_no_fake_goal_when_native_record_missing(self):
        with self.assertRaisesRegex(RuntimeError, 'No native goal'):
            goal_action(None, '/goal resume')
        self.assertEqual(goal_action(None, '/goal actual new objective'), {'status': 'active', 'objective': 'actual new objective'})

    def test_turn_completion_does_not_end_active_goal(self):
        session = NativeSession.__new__(NativeSession)
        session.thread_id = 'same-thread'
        session.goal = True
        session.goal_status = 'active'
        session.turns = {'first'}
        session.iteration = 1
        session.seen_turns = {'first'}
        session.pending_hint = None
        with contextlib.redirect_stdout(io.StringIO()) as output:
            session.event({'method': 'turn/completed', 'params': {'threadId': 'same-thread', 'turn': {'id': 'first', 'status': 'completed'}}})
            self.assertEqual(session.goal_status, 'active')
            session.event({'method': 'turn/started', 'params': {'threadId': 'same-thread', 'turn': {'id': 'second'}}})
        self.assertEqual(session.turns, {'second'})
        self.assertEqual(session.iteration, 2)
        self.assertNotIn('goal.status', output.getvalue())

    def test_native_stop_and_thread_filter(self):
        session = NativeSession.__new__(NativeSession)
        session.thread_id = 'same-thread'
        session.goal_status = 'active'
        session.goal = True
        with contextlib.redirect_stdout(io.StringIO()):
            session.event({'method': 'thread/goal/updated', 'params': {'threadId': 'other', 'goal': {'status': 'complete'}}})
            self.assertEqual(session.goal_status, 'active')
            session.event({'method': 'thread/goal/updated', 'params': {'threadId': 'same-thread', 'goal': {'status': 'blocked'}}})
        self.assertEqual(session.goal_status, 'blocked')
