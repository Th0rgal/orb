import contextlib
import io
import json
import unittest
from unittest.mock import patch, Mock
import os
import queue
from scripts.remote_codex_app_server import NativeSession, goal_action


class CyberSelectionTests(unittest.TestCase):
    def test_explicit_program_reaches_proxy_config_without_model_substitution(self):
        with patch.dict(os.environ, {'SANDBOXED_CYBER_PROGRAM':'standard'}, clear=True), \
             patch('scripts.remote_codex_app_server.subprocess.Popen') as spawn, \
             patch('scripts.remote_codex_app_server.threading.Thread'):
            NativeSession({'settings':['model="gpt-6.1-sol"']})
        command = spawn.call_args.args[0]
        self.assertIn('model_providers.sandboxed.http_headers={"x-sandboxed-cyber-program"="standard"}', command)
        self.assertIn('model="gpt-6.1-sol"', command)

    def test_invalid_program_cannot_start_process(self):
        with patch.dict(os.environ, {'SANDBOXED_CYBER_PROGRAM':'invalid'}, clear=True), \
             patch('scripts.remote_codex_app_server.subprocess.Popen') as spawn:
            with self.assertRaisesRegex(RuntimeError, 'Invalid cyber program'):
                NativeSession({'settings':[]})
            spawn.assert_not_called()


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
        self.assertIn('"type": "execution.mode", "mode": "goal"', output.getvalue())
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

    def test_followup_after_completed_goal_reports_ordinary_execution(self):
        session = NativeSession.__new__(NativeSession)
        session.config = {'model':'test-model', 'session':'same-thread', 'prompt':'What were the results?'}
        session.inbound = queue.Queue()
        session.deferred = []
        session.goal_status = None
        session.pending_hint = None
        calls = []
        goal = {'status':'complete', 'objective':'original task', 'tokensUsed':123}
        def rpc(method, params):
            calls.append((method, params))
            if method == 'thread/resume':
                return {'thread':{'id':'same-thread','cwd':os.getcwd(),'turns':[]}}
            if method == 'thread/goal/get': return {'goal':goal}
            if method == 'turn/start':
                session.deferred += [
                    {'method':'turn/started','params':{'turn':{'id':'followup'}}},
                    {'method':'turn/completed','params':{'turn':{'id':'followup','status':'completed'}}},
                ]
            return {}
        session.rpc = rpc
        session.send = lambda message: None
        with contextlib.redirect_stdout(io.StringIO()) as output:
            session.run()
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertIn({'type':'execution.mode', 'mode':'turn'}, events)
        self.assertEqual(events[-1], {'type':'turn.completed'})
        self.assertFalse(any(event['type'] == 'goal.status' for event in events))
        self.assertEqual([params for method, params in calls if method == 'turn/start'], [{
            'threadId':'same-thread', 'input':[{'type':'text','text':'What were the results?'}]}])
        self.assertFalse(any(method == 'thread/goal/set' for method, _ in calls))

    def test_goal_controls_act_on_the_native_goal_without_objective_check(self):
        for word, expected_calls, status in (
            ('pause', [('thread/goal/set', {'threadId':'same-thread','status':'paused'})], 'paused'),
            ('clear', [('thread/goal/clear', {'threadId':'same-thread'})], 'cleared'),
            ('status', [], 'active'),
        ):
            session = NativeSession.__new__(NativeSession)
            session.config = {'model':'test-model', 'session':'same-thread', 'prompt':f'/goal {word}'}
            session.inbound = queue.Queue()
            session.deferred = []
            session.goal_status = None
            session.pending_hint = None
            goal = {'status':'active', 'objective':'ship the release'}
            calls = []
            def rpc(method, params):
                calls.append((method, params))
                if method == 'thread/resume':
                    return {'thread':{'id':'same-thread','cwd':os.getcwd(),'turns':[]}}
                if method == 'thread/goal/get':
                    return {'goal': None if word == 'clear' and len(calls) > 3 else dict(goal, status=status)}
                return {}
            session.rpc = rpc
            session.send = lambda message: None
            with contextlib.redirect_stdout(io.StringIO()) as output:
                session.run()
            mutations = [(m, p) for m, p in calls if m not in ('initialize', 'thread/resume', 'thread/goal/get')]
            self.assertEqual(mutations, expected_calls, word)
            self.assertIn(f'"status": "{status}"', output.getvalue(), word)
            self.assertEqual(output.getvalue().count('turn.completed'), 1, word)
            self.assertNotIn('turn/start', [m for m, _ in calls])

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


class NativeCapacityTests(unittest.TestCase):
    def session(self, goal=False):
        session = NativeSession.__new__(NativeSession)
        session.thread_id = 'original'
        session.goal = goal
        session.turns = {'turn'}
        session.rpc = Mock(return_value={})
        return session

    def test_capacity_notification_waits_for_terminal_receipt_and_retries_bounded(self):
        session = self.session()
        error = {'codexErrorInfo': 'serverOverloaded', 'message': 'At capacity'}
        with patch('scripts.remote_codex_app_server.time.sleep') as sleep, contextlib.redirect_stdout(io.StringIO()):
            session.event({'method': 'error', 'params': {'error': error, 'willRetry': False}})
            session.rpc.assert_not_called()
            receipt = {'method': 'turn/completed', 'params': {'turn': {'id': 'turn', 'status': 'failed', 'error': error}}}
            for _ in range(3):
                session.event(receipt)
            with self.assertRaisesRegex(RuntimeError, 'serverOverloaded'):
                session.event(receipt)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [5, 15, 30])
        self.assertEqual(session.rpc.call_count, 3)
        for call in session.rpc.call_args_list:
            self.assertEqual(call.args[0], 'turn/start')
            self.assertEqual(call.args[1]['threadId'], 'original')
            self.assertIn('do not repeat', call.args[1]['input'][0]['text'])

    def test_native_goal_and_unrelated_failures_are_not_retried(self):
        for goal, code in [(True, 'serverOverloaded'), (False, 'other')]:
            session = self.session(goal)
            with self.assertRaises(RuntimeError):
                session.event({'method': 'turn/completed', 'params': {'turn': {
                    'id': 'turn', 'status': 'failed', 'error': {'codexErrorInfo': code}}}})
            session.rpc.assert_not_called()

    def test_launch_sets_full_access_before_app_server(self):
        with patch('scripts.remote_codex_app_server.subprocess.Popen') as popen, patch('scripts.remote_codex_app_server.threading.Thread'):
            NativeSession({'settings': []})
        command = popen.call_args.args[0]
        self.assertLess(command.index('approval_policy="never"'), command.index('app-server'))
        self.assertLess(command.index('sandbox_mode="danger-full-access"'), command.index('app-server'))
