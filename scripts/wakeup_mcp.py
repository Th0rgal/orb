"""Orb's credential-free, durable scheduling transport (stdio MCP or CLI)."""
import datetime, hashlib, json, os, pathlib, sys, tempfile, time, uuid
root, mission, generation = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
if generation < 0: raise ValueError("Invalid run generation")

def schedule(name, args):
    if not isinstance(args, dict):
        raise ValueError('arguments must be a JSON object')
    key = str(args.get('request_id') or uuid.uuid4())
    if not key.strip() or len(key) > 200: raise ValueError('Invalid request_id')
    dest = root / (hashlib.sha256(key.encode()).hexdigest() + '.json')
    if dest.with_suffix('.cancelled').exists():
        return {'request_id': key, 'state': 'cancelled', 'owner': 'sandboxed'}
    if dest.with_suffix('.rejected').exists():
        raise ValueError('Core rejected this wake-up. Use a new request_id with corrected parameters.')
    if dest.exists() or dest.with_suffix('.acked').exists():
        return {'request_id': key, 'state': 'persisted', 'owner': 'sandboxed'}
    prompt = args.get('prompt', '')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 65536:
        raise ValueError('A nonempty prompt (<= 65536 chars) is required')
    reason = str(args.get('reason', ''))
    if len(reason) > 4096:
        raise ValueError('reason exceeds 4096 chars')
    variables = {'__wakeup_source': 'orb-local', '__wakeup_request_id': key, '__wakeup_reason': reason, '__wakeup_local': 'true', '__wakeup_run_generation': str(generation)}
    if name == 'schedule_job_wakeup':
        trigger = {'type': 'durable_job_terminal', 'job_id': str(uuid.UUID(args['job_id']))}
        variables['__wakeup_source'] = 'durable-job-terminal'
    elif name == 'schedule_wakeup':
        delay = args.get('delay_seconds', args.get('delaySeconds'))
        if type(delay) is not int or not 60 <= delay <= 3600:
            raise ValueError('delay_seconds must be an integer between 60 and 3600')
        trigger = {'type': 'interval', 'seconds': delay}
        variables['__wakeup_due_at'] = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=delay)).isoformat()
    else:
        raise ValueError('Unknown scheduling tool')
    body = {'command_source': {'type': 'inline', 'content': prompt}, 'trigger': trigger,
            'stop_policy': {'type': 'after_first_fire'}, 'fresh_session': 'keep',
            'variables': variables, 'start_immediately': False}
    root.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=root, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump({'mission': mission, 'created_ns': time.time_ns(), 'body': body}, f)
            f.flush(); os.fsync(f.fileno())
        # A stable request ID cannot replace its first persisted payload.
        try: os.link(tmp, dest)
        except FileExistsError: pass
        d = os.open(root, os.O_RDONLY)
        try: os.fsync(d)
        finally: os.close(d)
    finally:
        os.unlink(tmp)
    return {'request_id': key, 'state': 'pending_sync', 'owner': 'sandboxed',
            'message': 'Saved on this computer. Orb must sync with Core before this wake-up can fire. Do not start a second timer.'}

schema = {'type': 'object', 'properties': {'request_id': {'type': 'string'}, 'prompt': {'type': 'string'},
          'reason': {'type': 'string'}, 'delay_seconds': {'type': 'integer', 'minimum': 60, 'maximum': 3600}},
          'required': ['prompt', 'reason', 'delay_seconds']}
job_schema = json.loads(json.dumps(schema))
job_schema['properties'].pop('delay_seconds')
job_schema['properties']['job_id'] = {'type': 'string'}
job_schema['required'] = ['prompt', 'reason', 'job_id']
tools = [{'name': 'schedule_wakeup', 'description': 'Save one durable wake-up for this mission. Core owns the timer. Reuse request_id when retrying.', 'inputSchema': schema},
         {'name': 'schedule_job_wakeup', 'description': 'Resume after a Core durable job becomes terminal. Prefer this to polling.', 'inputSchema': job_schema}]
if len(sys.argv) > 4:
    print(json.dumps(schedule(sys.argv[4], json.loads(sys.argv[5]))))
else:
    while True:
        line = sys.stdin.readline(131073)
        if not line:
            break
        if len(line) > 131072:
            print(json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Request too large'}}), flush=True)
            continue
        req_id = None
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise TypeError('Request must be an object')
            if 'id' not in req:
                continue
            req_id = req['id']
            method = req.get('method')
            params = req.get('params')
            if params is not None and not isinstance(params, dict):
                print(json.dumps({'jsonrpc': '2.0', 'id': req_id, 'error': {'code': -32602, 'message': 'Invalid params'}}), flush=True)
                continue
            params = params or {}
            if method == 'initialize': result = {'protocolVersion': params.get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'orb-wakeups', 'version': '1'}}
            elif method == 'tools/list': result = {'tools': tools}
            elif method == 'ping': result = {}
            elif method == 'tools/call':
                try:
                    value = schedule(params['name'], params.get('arguments', {}))
                    result = {'content': [{'type': 'text', 'text': json.dumps(value)}]}
                except Exception as e: result = {'isError': True, 'content': [{'type': 'text', 'text': str(e)}]}
            else:
                print(json.dumps({'jsonrpc': '2.0', 'id': req_id, 'error': {'code': -32601, 'message': 'Method not found'}}), flush=True); continue
            print(json.dumps({'jsonrpc': '2.0', 'id': req_id, 'result': result}), flush=True)
        except json.JSONDecodeError:
            print(json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}), flush=True)
        except (ValueError, KeyError, TypeError):
            print(json.dumps({'jsonrpc': '2.0', 'id': req_id, 'error': {'code': -32600, 'message': 'Invalid request'}}), flush=True)
