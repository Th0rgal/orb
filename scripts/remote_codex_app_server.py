#!/usr/bin/env python3
"""Node-side native Codex transport. Codex, not this process, owns goal iteration.

One JSON configuration argument; inherited proxy credentials stay in the env.
Output uses the existing remote JSON stream plus explicit native goal receipts.
"""
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time


def emit(kind, **fields):
    print(json.dumps(dict(type=kind, **fields)), flush=True)


GOAL_CONTROLS = ('pause', 'status', 'clear')


def goal_control(goal, prompt):
    """`/goal pause|status|clear` control an existing native goal; they are not objectives."""
    word = prompt[6:].strip() if prompt.startswith('/goal ') else None
    return word if goal is not None and word in GOAL_CONTROLS else None


def goal_action(goal, prompt):
    requested = prompt.startswith('/goal ')
    objective = prompt[6:].strip() if requested else None
    if goal is not None:
        if requested and objective not in ('resume', goal['objective']):
            raise RuntimeError('Native goal objective differs; refusing to replace its identity or counters')
        if goal['status'] == 'complete':
            if requested:
                raise RuntimeError('Native goal is complete; explicit new goal required')
            return None
        budget = goal.get('tokenBudget')
        if budget is not None and goal.get('tokensUsed', 0) >= budget:
            raise RuntimeError('Native goal budget exhausted; refusing to reset usage')
        return {'status': 'active'}
    if requested:
        if not objective or objective in ('resume', 'pause', 'status', 'clear'):
            raise RuntimeError('No native goal exists to resume')
        return {'objective': objective, 'status': 'active'}
    return None


class NativeSession:
    def __init__(self, config):
        self.config = config
        self.next_id = 0
        self.inbound = queue.Queue()
        self.deferred = []
        self.thread_id = None
        self.goal = False
        self.goal_status = None
        self.turns = set()
        self.iteration = 0
        self.seen_turns = set()
        self.text = {}
        self.pending_hint = None
        command = ['codex']
        if os.environ.get('SANDBOXED_MCP_WRAPPER'):
            command = [os.environ['SANDBOXED_MCP_WRAPPER'], 'launch', '--harness', 'codex', '--', 'codex']
        for setting in config['settings']:
            command += ['-c', setting]
        command += ['app-server', '--enable', 'goals']
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=sys.stderr, text=True, bufsize=1)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            for line in self.child.stdout:
                self.inbound.put(json.loads(line))
        finally:
            self.inbound.put(None)

    def send(self, value):
        self.child.stdin.write(json.dumps(value) + '\n')
        self.child.stdin.flush()

    def rpc(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({'id': request_id, 'method': method, 'params': params})
        deadline = time.monotonic() + 90
        while True:
            value = self.inbound.get(timeout=max(0.01, deadline-time.monotonic()))
            if value is None:
                raise RuntimeError('Codex app-server disconnected')
            if value.get('id') == request_id and 'method' not in value:
                if 'error' in value:
                    raise RuntimeError(str(value['error']))
                return value.get('result', {})
            self.deferred.append(value)

    def event(self, message):
        method, params = message.get('method'), message.get('params', {})
        if params.get('threadId', self.thread_id) != self.thread_id:
            return
        if 'id' in message:
            # approvalPolicy=never: unexpected requests fail closed, never hang.
            self.send({'id': message['id'], 'error': {'code': -32601, 'message': 'Interactive request unavailable on remote node'}})
            return
        if method in ('thread/goal/updated', 'thread/goal/cleared') and not self.goal:
            return
        if method == 'thread/goal/updated':
            goal = params.get('goal', {})
            self.goal_status = goal.get('status')
            emit('goal.status', status=self.goal_status, objective=goal.get('objective', ''))
        elif method == 'thread/goal/cleared':
            self.goal_status = 'cleared'
            emit('goal.status', status='cleared', objective='')
        elif method == 'turn/started':
            turn = params['turn']['id']
            self.turns.add(turn)
            if self.goal and turn not in self.seen_turns:
                self.seen_turns.add(turn)
                self.iteration += 1
                emit('goal.iteration', iteration=self.iteration)
            emit('turn.started')
            if self.pending_hint:
                hint, self.pending_hint = self.pending_hint, None
                self.rpc('turn/steer', {'threadId': self.thread_id, 'expectedTurnId': turn,
                                      'input': [{'type': 'text', 'text': hint}]})
        elif method == 'turn/completed':
            turn = params['turn']
            self.turns.discard(turn['id'])
            if turn.get('status') == 'failed':
                raise RuntimeError(str(turn.get('error', 'Native turn failed')))
            if not self.goal:
                emit('turn.completed')
                self.goal_status = 'complete'
        elif method in ('item/started', 'item/completed'):
            item = params['item']
            completed = method == 'item/completed'
            kind = item.get('type')
            if kind == 'agentMessage' and completed:
                emit('item.completed', item={'type': 'agent_message', 'id': item['id'], 'text': item.get('text', '')})
            elif kind in ('commandExecution', 'fileChange', 'mcpToolCall', 'webSearch'):
                types = {'commandExecution':'command_execution', 'fileChange':'file_change', 'mcpToolCall':'mcp_tool_call', 'webSearch':'web_search'}
                normalized = dict(item, type=types[kind], aggregated_output=item.get('aggregatedOutput'),
                                  status='failed' if item.get('status') == 'failed' else ('completed' if completed else 'in_progress'))
                emit('item.completed' if completed else 'item.started', item=normalized)
        elif method == 'error' and not params.get('willRetry', False):
            raise RuntimeError(str(params.get('error', 'Native Codex error')))

    def run(self):
        self.rpc('initialize', {'clientInfo': {'name': 'sandboxed-remote', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized'})
        params = {'model': self.config['model'], 'cwd': os.getcwd(), 'approvalPolicy': 'never', 'sandbox': 'danger-full-access'}
        resume = self.config.get('session')
        if resume:
            params['threadId'] = resume
        result = self.rpc('thread/resume' if resume else 'thread/start', params)
        thread = result['thread']
        self.thread_id = thread['id']
        if (resume and self.thread_id != resume) or thread.get('cwd') != os.getcwd():
            raise RuntimeError('Native thread identity/cwd mismatch; no fresh-thread fallback')
        emit('thread.started', thread_id=self.thread_id)
        self.turns = {turn['id'] for turn in thread.get('turns', []) if turn.get('status') == 'inProgress'}
        goal = self.rpc('thread/goal/get', {'threadId': self.thread_id}).get('goal')
        control = goal_control(goal, self.config['prompt'])
        if control:
            if control == 'pause':
                self.rpc('thread/goal/set', {'threadId': self.thread_id, 'status': 'paused'})
            elif control == 'clear':
                self.rpc('thread/goal/clear', {'threadId': self.thread_id})
            current = self.rpc('thread/goal/get', {'threadId': self.thread_id}).get('goal') or {}
            status = 'cleared' if control == 'clear' else current.get('status', goal['status'])
            emit('goal.status', status=status, objective=current.get('objective', ''))
            emit('turn.completed')
            return
        action = goal_action(goal, self.config['prompt'])
        self.goal = action is not None
        # Restored stop snapshots precede this explicit activation.
        self.deferred = [m for m in self.deferred if m.get('method') not in ('thread/goal/updated', 'thread/goal/cleared')]
        if self.goal:
            if goal and not self.config['prompt'].startswith('/goal '):
                self.pending_hint = self.config['prompt']
            self.rpc('thread/goal/set', dict(action, threadId=self.thread_id))
            current = self.rpc('thread/goal/get', {'threadId': self.thread_id}).get('goal')
            if goal and (not current or any(current.get(k) != goal.get(k) for k in ('objective','tokenBudget'))
                         or current.get('tokensUsed', 0) < goal.get('tokensUsed', 0)
                         or current.get('timeUsedSeconds', 0) < goal.get('timeUsedSeconds', 0)):
                raise RuntimeError('Native goal identity/budget/usage changed during resume')
            if current:
                self.goal_status = current['status']
                emit('goal.status', status=current['status'], objective=current['objective'])
            if self.pending_hint and self.turns:
                hint, self.pending_hint = self.pending_hint, None
                self.rpc('turn/steer', {'threadId': self.thread_id, 'expectedTurnId': next(iter(self.turns)),
                                      'input': [{'type': 'text', 'text': hint}]})
        else:
            self.rpc('turn/start', {'threadId': self.thread_id, 'input': [{'type': 'text', 'text': self.config['prompt']}]})
        terminal = {'complete', 'paused', 'blocked', 'budgetLimited', 'usageLimited', 'cleared'}
        while True:
            try:
                value = self.deferred.pop(0) if self.deferred else self.inbound.get(timeout=1)
            except queue.Empty:
                if self.goal_status in terminal and not self.turns:
                    # Explicit native goal status, not a turn/exec exit, ends a goal.
                    emit('turn.completed')
                    return
                continue
            if value is None:
                raise RuntimeError('Codex disconnected before native completion')
            self.event(value)
            if not self.goal and self.goal_status == 'complete':
                return

    def close(self):
        self.child.terminate()
        try:
            self.child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()


def main():
    session = NativeSession(json.loads(sys.argv[1]))
    def stop(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop)
    try:
        session.run()
    except KeyboardInterrupt:
        # Explicit cancellation must also stop native automatic continuation.
        if session.thread_id and session.goal:
            session.rpc('thread/goal/set', {'threadId': session.thread_id, 'status': 'paused'})
        raise
    finally:
        session.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit('turn.failed', error={'message': str(error)})
        sys.exit(1)
