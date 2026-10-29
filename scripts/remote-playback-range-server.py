#!/usr/bin/env python3
"""Serve one real WAV for testDeviceLargeWebDAVMusicSurvivesNetworkStalls.

Pass --bind with the Mac LAN address and set PRIMUSE_LARGE_AUDIO_QA_URL
in the physical-device test environment to http://<address>:18964.
"""
import argparse
import http.server, json, os, re, threading, time
from urllib.parse import urlparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('wav', help='An ordinary music PCM WAV larger than 1 GB')
parser.add_argument('--bind', default='127.0.0.1')
parser.add_argument('--port', type=int, default=18964)
args = parser.parse_args()
FILE = args.wav
SIZE=os.path.getsize(FILE)
lock=threading.Lock()
state={'stall_until':0.0,'range_requests':0,'full_requests':0,'bytes_sent':0,'stalls':[]}
def event(**kw): print(json.dumps(dict(at=time.time(),**kw)),flush=True)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def reply(self,status,body=b'',ctype='application/json',headers=None):
        self.send_response(status); self.send_header('Content-Type',ctype); self.send_header('Content-Length',str(len(body)))
        for k,v in (headers or {}).items(): self.send_header(k,str(v))
        self.end_headers()
        if self.command!='HEAD': self.wfile.write(body)
    def do_POST(self):
        if self.path!='/control': return self.reply(404)
        data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
        seconds=min(90,max(0,float(data.get('stall_seconds',0))))
        with lock:
            state['stall_until']=time.monotonic()+seconds
            state['stalls'].append({'seconds':seconds,'at':time.time()})
        event(kind='stall',seconds=seconds)
        self.reply(200,b'{}')
    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        body=f'''<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/music.wav</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>{SIZE}</d:getcontentlength><d:getcontenttype>audio/wav</d:getcontenttype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'''.encode()
        self.reply(207,body,'application/xml')
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        path=urlparse(self.path).path
        if path=='/metrics':
            with lock: body=json.dumps(state).encode()
            return self.reply(200,body)
        if path=='/manifest': return self.reply(200,json.dumps({'size':SIZE}).encode())
        if path!='/music.wav': return self.reply(404)
        if self.command=='HEAD':
            self.send_response(200); self.send_header('Content-Length',str(SIZE)); self.send_header('Accept-Ranges','bytes'); self.end_headers(); return
        match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
        if not match:
            with lock: state['full_requests']+=1
            event(kind='full-download-rejected')
            return self.reply(503,b'full downloads forbidden in this fixture')
        start=int(match[1]); end=min(SIZE-1,int(match[2]) if match[2] else SIZE-1)
        if start>=SIZE or end<start: return self.reply(416,headers={'Content-Range':f'bytes */{SIZE}'})
        began=time.monotonic()
        while True:
            with lock: remain=state['stall_until']-time.monotonic()
            if remain<=0: break
            time.sleep(min(.1,remain))
        length=end-start+1
        self.send_response(206); self.send_header('Content-Type','audio/wav'); self.send_header('Content-Length',str(length)); self.send_header('Content-Range',f'bytes {start}-{end}/{SIZE}'); self.send_header('Accept-Ranges','bytes'); self.end_headers()
        sent=0
        try:
            with open(FILE,'rb') as f:
                f.seek(start)
                while sent<length:
                    block=f.read(min(65536,length-sent))
                    if not block: break
                    self.wfile.write(block); sent+=len(block)
        except (BrokenPipeError,ConnectionResetError): pass
        with lock:
            state['range_requests']+=1; state['bytes_sent']+=sent
        event(kind='range',offset=start,length=length,sent=sent,wait=round(time.monotonic()-began,3))
event(kind='ready', size=SIZE, port=args.port)
http.server.ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()
