"""Operator-only loopback bridge. Credentials remain in memory, never in Simulator argv.
Only dedicated orb-ios-validation missions may be created or mutated.
"""
import json, subprocess, urllib.request, urllib.error
from urllib.parse import unquote
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
PROJECT='orb-ios-validation'
script="import runpy,sys;sys.argv=['probe','probe'];d=runpy.run_path('/tmp/orb-cloud-prod-install.py');print(d['t'])"
token=subprocess.check_output(['ssh',__import__('os').environ.get('ORB_LIVE_SSH','agent-core'),'python3 -c '+__import__('shlex').quote(script)],text=True).strip()
owned=set()
def request(path,body=None,method='GET'):
    return urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:18768'+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}),timeout=90)
with request('/api/projects',{'slug':PROJECT,'title':'Orb iOS validation'},'PUT') as r:r.read()
class Proxy(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):self.forward()
    def do_POST(self):self.forward()
    def do_PUT(self):self.forward()
    def do_PATCH(self):self.forward()
    def do_DELETE(self):self.forward()
    def send(self,body,code=200):
        data=json.dumps(body).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def forward(self):
        self.path = unquote(self.path)
        if self.path=='/api/health':return self.send({'status':'ok','auth_required':False})
        if self.path=='/api/projects':return self.send({'projects':[{'slug':PROJECT,'title':'Orb iOS validation','status':'active'}]})
        body=json.loads(self.rfile.read(int(self.headers['Content-Length']))) if self.headers.get('Content-Length') else None
        if self.command!='GET':
            allowed=False
            if self.path=='/api/control/missions' and body and body.get('project')==PROJECT:allowed=True
            if self.path=='/api/control/message' and body and body.get('mission_id') in owned:allowed=True
            if self.path.startswith('/api/control/missions/') and self.path.split('/')[4] in owned:allowed=True
            if not allowed:return self.send({'error':'Only validation missions may be changed'},403)
        try:
            with request(self.path,body,self.command) as response:
                data=response.read()
                if self.command=='POST' and self.path=='/api/control/missions':
                    value=json.loads(data);owned.add(value['id']);print('Created validation mission',value['id'],value.get('backend'),flush=True)
                self.send_response(response.status)
                for key in ['Content-Type','X-Max-Sequence']:
                    if response.headers.get(key):self.send_header(key,response.headers[key])
                self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
        except urllib.error.HTTPError as e:
            self.send({'error':e.read().decode()[:1000]},e.code)
        except Exception as e:self.send({'error':type(e).__name__},502)
print('Live bridge on 127.0.0.1:18767, scoped to',PROJECT,flush=True)
ThreadingHTTPServer(('127.0.0.1',18767),Proxy).serve_forever()
