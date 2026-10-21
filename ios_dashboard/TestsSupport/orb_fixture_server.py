"""Loopback-only deterministic Core contract server for Orb Simulator tests."""
import json, threading, time, uuid, argparse, base64
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote
REQUIRE_AUTH = False
EXPIRE_SESSION = False
LIST_DELAY = 0
HEALTH_DELAY = 0
COUNTS = {}
VALID_TOKEN = "orb-fixture-" + str(uuid.uuid4())
LOCK = threading.Lock()
MISSIONS = {}
RECEIPTS = {}
PROVIDERS = {}
CORDONED = False
# /__fail_missions: the mission list returns 500 until the next /__reset (Inbox error state).
FAIL_MISSIONS = False
INBOX_STATE = {}
QUEUE = []
RECEIVED = []
QUEUE_EVENTS = {}
SCHEDULE = []
PROJECTS = [{"slug": "orb-test", "title": "Orb test", "status": "active"}]
DOC = {"content": "# Project context\n\nA **shared** document.\n", "revision": 1}
PROMPT = "Please test the new interface"
def reset():
    global CORDONED, HEALTH_DELAY, FAIL_MISSIONS
    FAIL_MISSIONS = False
    CORDONED = False; HEALTH_DELAY = 0
    QUEUE.clear(); RECEIVED.clear(); QUEUE_EVENTS.clear(); SCHEDULE.clear(); MISSIONS.clear(); RECEIPTS.clear(); COUNTS.clear(); PROVIDERS.clear(); INBOX_STATE.clear()
    PROVIDERS['fixture-provider'] = dict(id='fixture-provider', name='Fixture provider', provider_type='openai', uses_oauth=False, enabled=True, status={'type':'connected'})
    for mid, title, tags in [('existing', 'Improve image previews', ['orb-folder:Design/Images']), ('local-only','Local Mac session',['placement:client'])]:
        MISSIONS[mid] = dict(id=mid,title=title,status='awaiting_user',project='orb-test',backend='claudecode',tags=tags,model_override='test-model',history=[dict(role='user',content=PROMPT),dict(role='assistant',content='# Ready\n\n- [x] Review complete\n\n| Feature | Status |\n| --- | --- |\n| Images | Ready |\n\n```swift\nlet orb = true\n```')])
    MISSIONS['long-chat']=dict(id='long-chat',title='Long conversation',status='awaiting_user',project='orb-test',backend='codex',tags=[],model_override='test-model',history=[dict(role='user',content=f'Message {i:03d} — conversation history') for i in range(1,81)])
    # Long, rich transcript for scroll/keyboard tests: wide code, wide tables, long URLs.
    long_rich=[]
    for i in range(1,31):
        long_rich.append(dict(role='user',content=f'Question {i:02d}: explain step {i}'))
        long_rich.append(dict(role='assistant',content=f'## Step {i}\n\nAnswer {i:02d} with a very long URL https://example.com/{"a"*120} and inline `code_{i}`.\n\n```swift\nlet veryLongLineNumber{i} = "{"x"*160}"\n```\n\n| Column A | Column B | Column C | Column D | Column E | Column F |\n| --- | --- | --- | --- | --- | --- |\n| a{i} | b{i} | c{i} | d{i} | e{i} | f{i} |'))
    long_rich.append(dict(role='assistant',content='LONG_RICH_LAST answer at the bottom.'))
    MISSIONS['long-rich']=dict(id='long-rich',title='Long rich conversation',status='awaiting_user',project='orb-test',backend='opencode',tags=[],model_override='test-model',history=long_rich)
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
    # Idle, its last turn started ~36 min ago; a send takes 2.5 s to be acknowledged.
    MISSIONS['idle-send']=dict(id='idle-send',title='Idle send',status='awaiting_user',project='orb-test',backend='claudecode',tags=[],model_override='test-model',history=[dict(role='user',content='old turn'),dict(role='assistant',content='old reply')],created_at='2026-10-09T10:00:00Z',updated_at='2026-10-09T10:06:00Z')
    QUEUE_EVENTS['idle-send']=[]
    qadd('idle-send','user_message','old turn','old-id',at=time.time()-2150); qadd('idle-send','assistant_message','old reply',at=time.time()-2140)
    # A permission request already answered, then one still waiting: exactly one card shows.
    MISSIONS['ask-question']=dict(id='ask-question',title='Needs approval',status='awaiting_user',project='orb-test',backend='claudecode',tags=[],model_override='test-model',history=[dict(role='user',content='Run the tests')],created_at='2026-10-09T10:00:00Z',updated_at='2026-10-09T10:02:00Z')
    QUEUE_EVENTS['ask-question']=[]
    qadd('ask-question','user_message','Run the tests','ask-u1',at=time.time()-120)
    qadd('ask-question','tool_call','{"method":"permission","params":{"input":{"description":"OLD_REQUEST lint","command":"swift lint"}}}',at=time.time()-110,tool_call_id='q-old',tool_name='ui_native_request')
    qadd('ask-question','tool_result','{"action":"accept"}',at=time.time()-100,tool_call_id='q-old',tool_name='ui_native_request')
    qadd('ask-question','tool_call','{"method":"permission","params":{"input":{"description":"OPEN_REQUEST run the suite","command":"swift test"}}}',at=time.time()-90,tool_call_id='q-open',tool_name='ui_native_request')
    # /btw: a conversation with two side threads, one answered (narration, an
    # opencode compaction block, Markdown answer) and one live that answers ~8 s
    # after a reset. Side questions sent to a thread stream, then complete.
    MISSIONS['btw-chat']=dict(id='btw-chat',title='Side questions',status='awaiting_user',project='orb-test',backend='claudecode',tags=[],model_override='test-model',history=[dict(role='user',content='Build the app'),dict(role='assistant',content='The app is built.')],created_at='2026-10-09T10:00:00Z',updated_at='2026-10-09T10:01:00Z')
    now=time.time()
    side('btw-done','completed',now-3600)
    qadd('btw-done','user_message','<main_conversation_update>ctx</main_conversation_update>\n\nCurrent request:\nSummarise the build',at=now-3600)
    qadd('btw-done','assistant_message_canonical','Reading the logs…',at=now-3590)
    qadd('btw-done','assistant_message_canonical','Checking the tests.',at=now-3580)
    qadd('btw-done','assistant_message',BTW_COMPACTION+'\n\n**BTW_DONE_OK** the build is green.\n\n- `swift build` passed\n- 12 tests ran\n\n```sh\nswift test\n```',at=now-3570)
    side('btw-live','running',now-60)
    qadd('btw-live','user_message','Current request:\nWhat is running now?',at=now-60)
    later('btw-live',4,'assistant_message_canonical','Looking at the running job…')
    later('btw-live',45,'assistant_message','LIVE_ANSWER_OK: the **build** is running.',status='completed')

BTW_COMPACTION='## Objective\nAnswer the side question.\n\n## Progress\n- read the logs\n\nContinue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.'

def side(mid, status, created):
    MISSIONS[mid]=dict(id=mid,title='Side question',status=status,project='orb-test',backend='opencode',tags=['btw-parent:btw-chat'],history=[],created_at=iso(created),updated_at=iso(created),last_activity_at=iso(time.time() if status=='running' else created+30))
    QUEUE_EVENTS[mid]=[]

def later(mid, delay, kind, content, status=None):
    SCHEDULE.append(dict(at=time.time()+delay,mid=mid,kind=kind,content=content,status=status))

def run_schedule():
    for item in sorted(list(SCHEDULE), key=lambda i: i['at']):
        if time.time() < item['at']: continue
        SCHEDULE.remove(item); m=MISSIONS.get(item['mid'])
        if not m: continue
        qadd(item['mid'],item['kind'],item['content'])
        if item['kind']=='assistant_message': m['history'].append({'role':'assistant','content':item['content']})
        if item['status']: m['status']=item['status']
        m['updated_at']=m['last_activity_at']=iso(time.time())

def qadd(mid, kind, content, event_id=None, at=None, tool_call_id=None, tool_name=None):
    rows=QUEUE_EVENTS[mid]; n=len(rows)+1
    rows.append(dict(id=n,mission_id=mid,sequence=n,event_type=kind,timestamp=iso(at or time.time()),event_id=event_id or f'{mid}-{n}',tool_call_id=tool_call_id,tool_name=tool_name,content=content,metadata={}))

def deliver_queue():
    """queue-run: the current turn ends; Core delivers the queued message, the agent answers, the mission completes."""
    for item in list(QUEUE):
        if time.time() < item['deliver_at']: continue
        QUEUE.remove(item); m=MISSIONS[item['mission_id']]
        m['history'] += [{'role':'assistant','content':'first reply'},{'role':'user','content':item['content']},{'role':'assistant','content':'QUEUED_REPLY_OK'}]
        qadd(m['id'],'assistant_message','first reply'); qadd(m['id'],'user_message',item['content'],item['id']); qadd(m['id'],'assistant_message','QUEUED_REPLY_OK')
        m['status']='completed'

def idle_turn(content, key):
    m=MISSIONS['idle-send']
    def step(delay, fn): time.sleep(delay); fn()
    def start():
        with LOCK: m['status']='running'; m['history'].append({'role':'user','content':content}); qadd('idle-send','user_message',content,key)
    def finish():
        with LOCK:
            m['history'].append({'role':'assistant','content':'ok'}); qadd('idle-send','assistant_message','ok')
            queued=[q for q in QUEUE if q['mission_id']=='idle-send']
            if not queued: m['status']='completed'; m['turn']=False; return
            for q in queued:
                QUEUE.remove(q); m['history'] += [{'role':'user','content':q['content']},{'role':'assistant','content':'QUEUED_REPLY_OK'}]
                qadd('idle-send','user_message',q['content'],q['id']); qadd('idle-send','assistant_message','QUEUED_REPLY_OK')
            m['status']='completed'; m['turn']=False
    step(3, start); step(2, finish)

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
        if p=='/__received': return self.send(RECEIVED)
        if p=='/api/health':
            time.sleep(HEALTH_DELAY); return self.send({'status':'ok','auth_required':REQUIRE_AUTH})
        if (REQUIRE_AUTH or EXPIRE_SESSION) and self.headers.get('Authorization') != 'Bearer '+VALID_TOKEN:
            REQUIRE_AUTH = True
            return self.send({'error':'invalid or expired token'},401)
        deliver_queue(); run_schedule()
        if p=='/api/control/queue': return self.send([{k:v for k,v in q.items() if k!='deliver_at'} for q in QUEUE])
        if p.endswith('/events') and p.split('/')[4] in QUEUE_EVENTS:
            since=int(parse_qs(u.query).get('since_seq',['0'])[0] or 0)
            return self.send([e for e in QUEUE_EVENTS[p.split('/')[4]] if e['sequence']>since])
        if p=='/api/control/inbox-state': return self.send(INBOX_STATE)
        if p=='/api/ai/providers': return self.send(list(PROVIDERS.values()))
        if p=='/api/ai/providers/usage': return self.send({'entries': {'fixture-provider': {'provider_type':'openai', 'codex_primary_used_percent':25}}})
        if p=='/api/cloud/usage': return self.send({'accounts':{}})
        if p=='/api/projects': return self.send({'projects':PROJECTS})
        if p=='/api/control/missions' and FAIL_MISSIONS: return self.send({'error':'fixture: missions unavailable'},500)
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
        global VALID_TOKEN, CORDONED, HEALTH_DELAY, FAIL_MISSIONS
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
        if p=='/__fail_missions': FAIL_MISSIONS = True; return self.send({})
        if p=='/__health_delay': HEALTH_DELAY=float(body.get('seconds',0)); return self.send({})
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
            MISSIONS[mid]=dict(id=mid,title='Side question',status='running',project='orb-test',backend=body.get('backend','opencode'),tags=['btw-parent:'+parent],history=[{'role':'user','content':'Current request:\n'+body.get('side_question','')}],created_at=iso(time.time()),updated_at=iso(time.time()),last_activity_at=iso(time.time()))
            QUEUE_EVENTS[mid]=[]; qadd(mid,'user_message','Current request:\n'+body.get('side_question',''))
            later(mid,6,'assistant_message','SIDE_ANSWER_OK: the agent is fixing the build.',status='completed')
            RECEIPTS[key]=MISSIONS[mid]; return self.send(MISSIONS[mid])
        if p=='/api/control/message' and any(t.startswith('btw-parent:') for t in MISSIONS.get(body.get('mission_id'),{}).get('tags',[])):
            mid=body['mission_id']; m=MISSIONS[mid]; RECEIVED.append(body['content'])
            m['status']='running'; m['updated_at']=m['last_activity_at']=iso(time.time())
            m['history'].append({'role':'user','content':body['content']}); qadd(mid,'user_message',body['content'],key)
            later(mid,2,'assistant_message_canonical','Looking into it…')
            later(mid,16,'assistant_message','SEND_ANSWER_OK: a **side** reply.',status='completed')
            RECEIPTS[key]={'id':key,'queued':False}; return self.send(RECEIPTS[key])
        if p=='/api/control/missions':
            mid=str(uuid.uuid4()); cloud=body.get('cloud'); m=dict(body,id=mid,status='awaiting_user',backend=('cloud_'+cloud['provider']) if cloud else body['backend'],history=[{'role':'user','content':body['prompt']},{'role':'assistant','content':'**ORB_TEST_OK**\n\nA response from the test agent.'}])
            if cloud: m['cloud_execution']={'mission_id':mid,'selection':cloud,'turns':[{'key':key,'prompt':body['prompt'],'result':'**ORB_TEST_OK**','phase':'response_complete','artifacts':[],'branches':[]}]}
            MISSIONS[mid]=m; RECEIPTS[key]=m; return self.send(m)
        if p=='/api/control/message' and body['mission_id']=='idle-send':
            # Prod timing: remote dispatch acks before the turn starts; user_message ~3 s
            # later, the agent answers and the job finishes quickly. A message posted
            # during the turn is queued and delivered when it ends.
            m=MISSIONS['idle-send']; RECEIVED.append(body['content'])
            if m.get('turn'):
                QUEUE.append(dict(id=key,mission_id='idle-send',content=body['content'],source='remote-queue',deliver_at=float('inf')))
                RECEIPTS[key]={'id':key,'queued':True}; return self.send(RECEIPTS[key])
            time.sleep(2.5); m['turn']=True
            threading.Thread(target=idle_turn, args=(body['content'], key), daemon=True).start()
            RECEIPTS[key]={'id':key,'queued':False}; return self.send(RECEIPTS[key])
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
