"""Loopback-only deterministic Core contract server for Orb Simulator tests."""
import json, threading, time, uuid, argparse, base64
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote
REQUIRE_AUTH = False
LOCK = threading.Lock()
MISSIONS = {}
RECEIPTS = {}
PROJECTS = [{"slug": "orb-test", "title": "Orb test", "status": "active"}]
DOC = {"content": "# Project context\n\nA **shared** document.\n", "revision": 1}
PROMPT = "Please test the new interface"
def reset():
    MISSIONS.clear(); RECEIPTS.clear()
    for mid, title, tags in [('existing', 'Improve image previews', ['orb-folder:Design/Images']), ('local-only','Local Mac session',['placement:client'])]:
        MISSIONS[mid] = dict(id=mid,title=title,status='awaiting_user',project='orb-test',backend='claudecode',tags=tags,model_override='test-model',history=[dict(role='user',content=PROMPT),dict(role='assistant',content='# Ready\n\n- [x] Review complete\n\n| Feature | Status |\n| --- | --- |\n| Images | Ready |\n\n```swift\nlet orb = true\n```')])
    rich=Path(__file__).with_name('fixtures').joinpath('chatgpt-rich.md').read_text()
    MISSIONS['rich-chatgpt']=dict(id='rich-chatgpt',title='ChatGPT rich response',status='awaiting_user',project='orb-test',backend='cloud_chatgpt',tags=[],cloud_execution={'selection':{'provider':'chatgpt','account':'chatgpt-test','model':'test-cloud-model'},'turns':[{'key':'rich-turn','prompt':'Montre le calcul, un tableau et les fichiers.','phase':'response_complete','result':rich,'artifacts':[{'path':'/mnt/data/chart.png'},{'path':'/mnt/data/result.csv'}]}]})
    MISSIONS['reconnect']=dict(id='reconnect',title='Reconnect ChatGPT',status='blocked',project='orb-test',backend='cloud_chatgpt',tags=[],cloud_execution={'selection':{'provider':'chatgpt','account':'chatgpt-test'},'turns':[{'key':'blocked-turn','prompt':'Continue the analysis.','phase':'reconnect_required','detail':'Reconnect your ChatGPT account in Orb on your Mac.','result':'','artifacts':[]}]})
reset()
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send(self, value, status=200):
        data=json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        u=urlparse(self.path); p=unquote(u.path)
        if p=='/api/health': return self.send({'status':'ok','auth_required':REQUIRE_AUTH})
        if p=='/api/projects': return self.send({'projects':PROJECTS})
        if p=='/api/control/missions': return self.send(list(MISSIONS.values()))
        if p=='/api/control/queue' or p.endswith('/events'): return self.send([])
        if p=='/api/backends': return self.send([{'id':'claudecode','name':'Claude Code'},{'id':'codex','name':'Codex'}])
        if p=='/api/providers/backend-models': return self.send({'backends':{b:[{'value':'test-model','label':'Test model'}] for b in ['claudecode','codex']}})
        if p=='/api/remote-nodes': return self.send({'nodes':[{'id':'test-node','name':'Test node','status':'online'}]})
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
                return self.send(m['cloud_execution'])
            return self.send(m)
        return self.send({'error':'Not found'},404)
    def do_PUT(self): self.do_POST()
    def do_POST(self):
        with LOCK: self.mutate()
    def mutate(self):
        p=unquote(urlparse(self.path).path); size=int(self.headers.get('Content-Length',0)); body=json.loads(self.rfile.read(size)) if size else {}
        if p=='/__reset': reset(); return self.send({})
        if p=='/api/projects': PROJECTS.append(body); return self.send(body)
        if p.endswith('/file/mkdir'): return self.send({})
        if p.endswith('/file'):
            if body.get('expected_revision')!=DOC['revision']: return self.send({'error':'Version conflict'},409)
            DOC.update(content=body['content'],revision=DOC['revision']+1); return self.send({'revision':DOC['revision']})
        key=body.get('idempotency_key') or body.get('client_message_id')
        if key in RECEIPTS: return self.send(RECEIPTS[key])
        if p=='/api/control/missions':
            mid=str(uuid.uuid4()); cloud=body.get('cloud'); m=dict(body,id=mid,status='awaiting_user',backend=('cloud_'+cloud['provider']) if cloud else body['backend'],history=[{'role':'user','content':body['prompt']},{'role':'assistant','content':'**ORB_TEST_OK**\n\nA response from the test agent.'}])
            if cloud: m['cloud_execution']={'mission_id':mid,'selection':cloud,'turns':[{'key':key,'prompt':body['prompt'],'result':'**ORB_TEST_OK**','phase':'response_complete','artifacts':[],'branches':[]}]}
            MISSIONS[mid]=m; RECEIPTS[key]=m; return self.send(m)
        if p=='/api/control/message':
            m=MISSIONS[body['mission_id']]; m['history'] += [{'role':'user','content':body['content']},{'role':'assistant','content':'FOLLOWUP_OK'}]
            if 'cloud_execution' in m: m['cloud_execution']['turns'].append({'key':key,'prompt':body['content'],'result':'FOLLOWUP_OK','phase':'response_complete','artifacts':[],'branches':[]})
            RECEIPTS[key]={'id':key,'queued':False}; return self.send(RECEIPTS[key])
        if p.startswith('/api/control/missions/'):
            m=MISSIONS[p.split('/')[4]]
            if p.endswith('/title') or p.endswith('/status'): m.update(body)
            if p.endswith('/cancel'): m['status']='interrupted'
            return self.send(m)
        return self.send({'error':'Unknown route'},404)
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=18766); parser.add_argument('--require-auth',action='store_true'); args=parser.parse_args(); REQUIRE_AUTH=args.require_auth
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
