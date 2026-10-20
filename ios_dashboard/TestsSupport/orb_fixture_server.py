"""Loopback-only deterministic Core contract server for Orb Simulator tests."""
import json, threading, time, uuid, argparse, base64
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote
REQUIRE_AUTH = False
EXPIRE_SESSION = False
LIST_DELAY = 0
COUNTS = {}
VALID_TOKEN = "orb-fixture-" + str(uuid.uuid4())
LOCK = threading.Lock()
MISSIONS = {}
RECEIPTS = {}
PROVIDERS = {}
CORDONED = False
INBOX_STATE = {}
QUEUE = []
QUEUE_EVENTS = {}
PROJECTS = [{"slug": "orb-test", "title": "Orb test", "status": "active"}]
DOC = {"content": "# Project context\n\nA **shared** document.\n", "revision": 1}
PROMPT = "Please test the new interface"
def reset():
    global CORDONED
    CORDONED = False
    QUEUE.clear(); QUEUE_EVENTS.clear(); MISSIONS.clear(); RECEIPTS.clear(); COUNTS.clear(); PROVIDERS.clear(); INBOX_STATE.clear()
    PROVIDERS['fixture-provider'] = dict(id='fixture-provider', name='Fixture provider', provider_type='openai', uses_oauth=False, enabled=True, status={'type':'connected'})
    for mid, title, tags in [('existing', 'Improve image previews', ['orb-folder:Design/Images']), ('local-only','Local Mac session',['placement:client'])]:
        MISSIONS[mid] = dict(id=mid,title=title,status='awaiting_user',project='orb-test',backend='claudecode',tags=tags,model_override='test-model',history=[dict(role='user',content=PROMPT),dict(role='assistant',content='# Ready\n\n- [x] Review complete\n\n| Feature | Status |\n| --- | --- |\n| Images | Ready |\n\n```swift\nlet orb = true\n```')])
    MISSIONS['long-chat']=dict(id='long-chat',title='Long conversation',status='awaiting_user',project='orb-test',backend='codex',tags=[],model_override='test-model',history=[dict(role='user',content=f'Message {i:03d} — conversation history') for i in range(1,81)])
    rich=Path(__file__).with_name('fixtures').joinpath('chatgpt-rich.md').read_text()
    MISSIONS['rich-chatgpt']=dict(id='rich-chatgpt',title='ChatGPT rich response',status='awaiting_user',project='orb-test',backend='cloud_chatgpt',tags=[],cloud_execution={'selection':{'provider':'chatgpt','account':'chatgpt-test','model':'test-cloud-model'},'turns':[{'key':'rich-turn','prompt':'Montre le calcul, un tableau et les fichiers.','phase':'response_complete','result':rich,'artifacts':[{'path':'/mnt/data/chart.png'},{'path':'/mnt/data/result.csv'}]}]})
    MISSIONS['rich-growth']=dict(id='rich-growth',title='Growing rich response',status='active',project='orb-test',backend='cloud_chatgpt',tags=[],cloud_execution={'selection':{'provider':'chatgpt','account':'chatgpt-test'},'turns':[{'key':'growth-turn','prompt':'Write a long response.','phase':'running','result':'Starting the response…','artifacts':[]}]})
    MISSIONS['reconnect']=dict(id='reconnect',title='Reconnect ChatGPT',status='blocked',project='orb-test',backend='cloud_chatgpt',tags=[],cloud_execution={'selection':{'provider':'chatgpt','account':'chatgpt-test'},'turns':[{'key':'blocked-turn','prompt':'Continue the analysis.','phase':'reconnect_required','detail':'Reconnect your ChatGPT account in Orb on your Mac.','result':'','artifacts':[]}]})
    for mission in MISSIONS.values():
        mission.update(created_at='2026-10-09T10:00:00Z', updated_at='2026-10-09T10:01:00Z')
    # A coding agent mid-turn: an earlier finished turn, then the current one with a
    # task list in harness vocabulary, edits, a running command and a linked PR.
    for mid, title, status in [('agent-work', 'Fix the iOS build', 'active'), ('agent-done', 'Ship the iOS fix', 'completed')]:
        MISSIONS[mid]=dict(id=mid,title=title,status=status,project='orb-test',backend='claudecode',tags=[],model_override='test-model',github_pr='Th0rgal/orb#1132',history=[dict(role='user',content='Set up CI for the app'),dict(role='assistant',content='CI is set up.'),dict(role='user',content='Now fix the build')]+([dict(role='assistant',content='The build is fixed and the PR is open.')] if status=='completed' else []),created_at='2026-10-09T10:00:00Z',updated_at='2026-10-09T10:01:00Z')
    # A running turn: a follow-up sent now is queued, then Core delivers it.
    MISSIONS['queue-run']=dict(id='queue-run',title='Queue while running',status='running',project='orb-test',backend='claudecode',tags=[],model_override='test-model',history=[dict(role='user',content='first message')],created_at='2026-10-09T10:00:00Z',updated_at='2026-10-09T10:05:00Z')
    QUEUE_EVENTS['queue-run']=[]
    qadd('queue-run','user_message','first message','first-id')

def qadd(mid, kind, content, event_id=None):
    rows=QUEUE_EVENTS[mid]; n=len(rows)+1
    rows.append(dict(id=n,mission_id=mid,sequence=n,event_type=kind,timestamp=iso(time.time()),event_id=event_id or f'{mid}-{n}',tool_call_id=None,tool_name=None,content=content,metadata={}))

def deliver_queue():
    """queue-run: the current turn ends; Core delivers the queued message, the agent answers, the mission completes."""
    for item in list(QUEUE):
        if time.time() < item['deliver_at']: continue
        QUEUE.remove(item); m=MISSIONS[item['mission_id']]
        m['history'] += [{'role':'assistant','content':'first reply'},{'role':'user','content':item['content']},{'role':'assistant','content':'QUEUED_REPLY_OK'}]
        qadd(m['id'],'assistant_message','first reply'); qadd(m['id'],'user_message',item['content'],item['id']); qadd(m['id'],'assistant_message','QUEUED_REPLY_OK')
        m['status']='completed'

def iso(t): return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))
def agent_events(mid):
    """Events of the agent-work/agent-done fixtures; the current turn started 95 s ago."""
    started=time.time()-95; rows=[]
    def add(kind, content, tool=None, call=None, at=None):
        rows.append(dict(id=len(rows)+1, mission_id=mid, sequence=len(rows)+1, event_type=kind, timestamp=iso(at or started), event_id=f'{mid}-{len(rows)+1}', tool_call_id=call, tool_name=tool, content=content, metadata={}))
    old=started-3600
    add('user_message','Set up CI for the app',at=old)
    add('tool_call',json.dumps({'todos':[{'content':'Write the workflow','status':'pending'},{'content':'Run it','status':'pending'}]}),'TodoWrite','t0',old)
    add('tool_call',json.dumps({'file_path':'/repo/.github/workflows/ci.yml','old_string':'','new_string':'name: CI\non: push'}),'Edit','e0',old)
    add('tool_result','ok','Edit','e0',old)
    add('assistant_message','CI is set up.',at=old)
    add('user_message','Now fix the build')
    add('tool_call',json.dumps({'file_path':'/repo/ios/App.swift'}),'Read','r1')
    add('tool_result','struct App {}','Read','r1')
    add('tool_call',json.dumps({'plan':[{'step':'Reproduce the failure','status':'done'},{'step':'Fix the type-check timeout','status':'in-progress'},{'step':'Wait for CI','status':'blocked'},{'step':'Old approach','status':'canceled'}]}),'update_plan','p1')
    add('tool_call',json.dumps({'file_path':'/repo/ios/App.swift','old_string':'let a = 1','new_string':'let a = 1\nlet b = 2\nlet c = 3'}),'Edit','e1')
    add('tool_result','ok','Edit','e1')
    add('tool_call',json.dumps({'file_path':'/repo/ios/View.swift','content':'import SwiftUI\n'}),'Write','w1')
    add('tool_result','ok','Write','w1')
    add('tool_call',json.dumps({'command':'xcodebuild build -scheme App'}),'Bash','b1')
    if mid=='agent-done':
        add('tool_result','BUILD SUCCEEDED','Bash','b1'); add('assistant_message','The build is fixed and the PR is open.')
    return rows

reset()

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send(self, value, status=200):
        data=json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        global REQUIRE_AUTH
        u=urlparse(self.path); p=unquote(u.path)
        COUNTS[p] = COUNTS.get(p, 0) + 1
        if p=='/__counts': return self.send(COUNTS)
        if p=='/api/health': return self.send({'status':'ok','auth_required':REQUIRE_AUTH})
        if (REQUIRE_AUTH or EXPIRE_SESSION) and self.headers.get('Authorization') != 'Bearer '+VALID_TOKEN:
            REQUIRE_AUTH = True
            return self.send({'error':'invalid or expired token'},401)
        deliver_queue()
        if p=='/api/control/queue': return self.send([{k:v for k,v in q.items() if k!='deliver_at'} for q in QUEUE])
        if p.endswith('/events') and p.split('/')[4] in QUEUE_EVENTS:
            since=int(parse_qs(u.query).get('since_seq',['0'])[0] or 0)
            return self.send([e for e in QUEUE_EVENTS[p.split('/')[4]] if e['sequence']>since])
        if p=='/api/control/inbox-state': return self.send(INBOX_STATE)
        if p=='/api/ai/providers': return self.send(list(PROVIDERS.values()))
        if p=='/api/ai/providers/usage': return self.send({'entries': {'fixture-provider': {'provider_type':'openai', 'codex_primary_used_percent':25}}})
        if p=='/api/cloud/usage': return self.send({'accounts':{}})
        if p=='/api/projects': return self.send({'projects':PROJECTS})
        if p=='/api/control/missions':
            time.sleep(LIST_DELAY)
            return self.send(list(MISSIONS.values()))
        if p.endswith('/events') and p.split('/')[4] in ('agent-work','agent-done'): return self.send(agent_events(p.split('/')[4]))
        if p=='/api/control/queue' or p.endswith('/events'): return self.send([])
        if p=='/api/backends': return self.send([{'id':'claudecode','name':'Claude Code'},{'id':'codex','name':'Codex'},{'id':'chatgpt_ui','name':'ChatGPT UI'}])
        if p=='/api/providers/backend-models': return self.send({'backends':{b:[{'value':'test-model','label':'Test model'}] for b in ['claudecode','codex']}})
        if p=='/api/remote-nodes': return self.send({'nodes':[{'id':'test-node','name':'Test node','status':'online','cordoned':CORDONED,'active_jobs':2,'mem_total_bytes':8589934592,'mem_available_bytes':4294967296}]})
        if p=='/api/cloud/accounts': return self.send([{'id':p+'-test','provider':p,'label':p+' account','available':True,'capabilities':{'cancel':True,'follow_up':True,'models':p!='grok_bot','attachments':False}} for p in ['chatgpt','cursor_cloud','grok_bot']])
        if p.endswith('/options'): return self.send({'models':{'items':[{'id':'test-cloud-model','displayName':'Test cloud model'}]},'repositories':{'items':[{'url':'https://github.com/example/orb-test'}]}})
        if p.endswith('/context/manifest'): return self.send({'revision':1,'entries':{'Design':{'directory':True},'Design/Images':{'directory':True}}})
        if p.endswith('/files'): return self.send({'entries':[{'name':'README.md','kind':'file'}]})
        if p.endswith('/file'): return self.send(DOC)
        if p.startswith('/api/control/missions/'):
            mid=p.split('/')[4]; m=MISSIONS.get(mid)
            if not m: return self.send({'error':'Not found'},404)
            if m.get('side_ready_at') and time.time()>=m['side_ready_at'] and m['status']=='running':
                m['status']='completed'; m['history'].append({'role':'assistant','content':'SIDE_ANSWER_OK: the agent is fixing the build.'})
            if p.endswith('/cloud/artifact'):
                name=parse_qs(u.query).get('path',[''])[0].split('/')[-1]
                if name=='chart.png': data=Path(__file__).with_name('fixtures').joinpath('chart.png').read_bytes()
                else: data=b'year,value\n1999,243\n2026,3767\n'
                return self.send({'name':name,'content_base64':base64.b64encode(data).decode()})
            if p.endswith('/cloud'):
                if not m['backend'].startswith('cloud_'): return self.send({},404)
                if mid=='rich-growth' and COUNTS[p]>=2:
                    result=json.loads(json.dumps(m['cloud_execution']))
                    result['turns'][0].update(phase='response_complete',result=('## Rich layout section\n\nA paragraph with **bold text**, a list, and inline math $x^2+y^2=z^2$.\n\n' * 40)+'\nFINAL RESPONSE END',artifacts=[{'path':'/mnt/data/result.csv'}])
                    return self.send(result)
                return self.send(m['cloud_execution'])
            return self.send(m)
        return self.send({'error':'Not found'},404)
    def do_PUT(self): self.do_POST()
    def do_DELETE(self): self.do_POST()
    def do_POST(self):
        with LOCK: self.mutate()
    def mutate(self):
        global VALID_TOKEN, CORDONED
        p=unquote(urlparse(self.path).path); size=int(self.headers.get('Content-Length',0))
        if p == '/api/voice/transcribe':
            audio = self.rfile.read(size)
            if not audio.startswith(b'RIFF'): return self.send({'error': 'Expected WAV'},400)
            time.sleep(5)
            return self.send({'text': 'Bonjour, ajoute un microphone dans la conversation.'})
        body=json.loads(self.rfile.read(size)) if size else {}
        if p=='/__expire':
            VALID_TOKEN = 'orb-fixture-' + str(uuid.uuid4())
            return self.send({})
        if p=='/api/auth/login':
            COUNTS[p] = COUNTS.get(p, 0) + 1
            if body.get('password') != 'orb-test-password': return self.send({'error':'Invalid password'},401)
            return self.send({'token':VALID_TOKEN,'exp':int(time.time())+3600})
        if p=='/__reset': reset(); return self.send({})
        if p=='/api/control/inbox-state/preferences':
            INBOX_STATE['preferences'] = body; return self.send({})
        if p.startswith('/api/control/inbox-state/seen/'):
            INBOX_STATE['seen:' + p.split('/')[-1]] = body['stamp']; return self.send({})
        if p.endswith('/inbox-digest'):
            mid=p.split('/')[4]; mission=MISSIONS[mid]
            return self.send(dict(schemaVersion=7, context='Restore the interrupted conversation safely.', contextDetails='Keep the original conversation and unsent drafts.', outcome='The account must be reconnected before continuing.', unresolved='Account reconnection is still required.', decision='Reconnect the account, then resume.', suggestions=['The account is reconnected; continue checking.'], sources=[dict(quote='Reconnect your ChatGPT account in Orb on your Mac.',eventSequence=None)], model=body.get('model','builtin/smart'), sourceRevision='fixture-shared-v7', sourceUpdatedAt=mission['updated_at'], generatedAt='2026-10-09T10:02:00Z'))
        if p.startswith('/api/nodes/test-node/'):
            CORDONED = p.endswith('/cordon'); return self.send({'cordoned':CORDONED})
        if p.startswith('/api/ai/providers/'):
            key=p.split('/')[-1]
            if key in PROVIDERS:
                PROVIDERS[key].update({k:v for k,v in body.items() if k != 'api_key'}); return self.send(PROVIDERS[key])
        if p=='/api/ai/providers':
            key=str(uuid.uuid4()); PROVIDERS[key]=dict(id=key,name=body['name'],provider_type=body['provider_type'],uses_oauth=False,enabled=True,status={'type':'connected'}); return self.send(PROVIDERS[key])
        if p=='/api/projects': PROJECTS.append(body); return self.send(body)
        if p.endswith('/file/mkdir'): return self.send({})
        if p.endswith('/file'):
            if body.get('expected_revision')!=DOC['revision']: return self.send({'error':'Version conflict'},409)
            DOC.update(content=body['content'],revision=DOC['revision']+1); return self.send({'revision':DOC['revision']})
        key=body.get('idempotency_key') or body.get('client_message_id')
        if key in RECEIPTS: return self.send(RECEIPTS[key])
        if p.endswith('/btw/agent'):
            time.sleep(3); parent=p.split('/')[4]; mid=str(uuid.uuid4())
            MISSIONS[mid]=dict(id=mid,title='Side question',status='running',project='orb-test',backend=body.get('backend','opencode'),tags=['btw-parent:'+parent],history=[{'role':'user','content':'Current request:\n'+body.get('side_question','')}],created_at=iso(time.time()),updated_at=iso(time.time()),side_ready_at=time.time()+6)
            RECEIPTS[key]=MISSIONS[mid]; return self.send(MISSIONS[mid])
        if p=='/api/control/missions':
            mid=str(uuid.uuid4()); cloud=body.get('cloud'); m=dict(body,id=mid,status='awaiting_user',backend=('cloud_'+cloud['provider']) if cloud else body['backend'],history=[{'role':'user','content':body['prompt']},{'role':'assistant','content':'**ORB_TEST_OK**\n\nA response from the test agent.'}])
            if cloud: m['cloud_execution']={'mission_id':mid,'selection':cloud,'turns':[{'key':key,'prompt':body['prompt'],'result':'**ORB_TEST_OK**','phase':'response_complete','artifacts':[],'branches':[]}]}
            MISSIONS[mid]=m; RECEIPTS[key]=m; return self.send(m)
        if p=='/api/control/message' and body.get('queue_followup') and MISSIONS[body['mission_id']]['status']=='running':
            QUEUE.append(dict(id=key,mission_id=body['mission_id'],content=body['content'],source='remote-queue',deliver_at=time.time()+4))
            RECEIPTS[key]={'id':key,'queued':True}; return self.send(RECEIPTS[key])
        if p=='/api/control/message':
            m=MISSIONS[body['mission_id']]; m['history'] += [{'role':'user','content':body['content']},{'role':'assistant','content':'FOLLOWUP_OK'}]
            if 'cloud_execution' in m: m['cloud_execution']['turns'].append({'key':key,'prompt':body['content'],'result':'FOLLOWUP_OK','phase':'response_complete','artifacts':[],'branches':[]})
            RECEIPTS[key]={'id':key,'queued':False}; return self.send(RECEIPTS[key])
        if p.startswith('/api/control/missions/'):
            m=MISSIONS[p.split('/')[4]]
            if p.endswith('/title') or p.endswith('/status'): m.update(body)
            if p.endswith('/cancel'): m['status']='interrupted'
            if p.endswith('/project'): m.update(project=body['project'], tags=body['tags'])
            return self.send(m)
        return self.send({'error':'Unknown route'},404)
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=18766); parser.add_argument('--require-auth',action='store_true'); parser.add_argument('--expire-session',action='store_true'); parser.add_argument('--list-delay',type=float,default=0); args=parser.parse_args(); LIST_DELAY=args.list_delay; REQUIRE_AUTH=args.require_auth; EXPIRE_SESSION=args.expire_session
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
