#!/usr/bin/env python3
import json, subprocess, time, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

CHAIN='SRTLA_IN'
_prev={}; _rates={}

def setup():
    subprocess.run(['iptables','-N',CHAIN],capture_output=True)
    r=subprocess.run(['iptables','-C','INPUT','-p','udp','--dport','5001','-j',CHAIN],capture_output=True)
    if r.returncode!=0:
        subprocess.run(['iptables','-I','INPUT','1','-p','udp','--dport','5001','-j',CHAIN],capture_output=True)

def ensure_rule(ip):
    r=subprocess.run(['iptables','-C',CHAIN,'-s',ip,'-j','RETURN'],capture_output=True)
    if r.returncode!=0:
        subprocess.run(['iptables','-I',CHAIN,'1','-s',ip,'-j','RETURN'],capture_output=True)

def read_ipt():
    try:
        out=subprocess.check_output(['iptables','-L',CHAIN,'-n','-v','-x'],text=True,stderr=subprocess.DEVNULL)
        res={}
        for ln in out.strip().split('\n')[2:]:
            p=ln.split()
            if len(p)>=8:
                try:
                    b=int(p[1]); src=p[7]
                    if src in('0.0.0.0/0','anywhere'): continue
                    ip=src.split('/')[0]
                    if ip: res[ip]=b
                except: pass
        return res
    except: return {}

def peer_rates(peers):
    global _prev,_rates
    for ip in peers: ensure_rule(ip)
    now=time.time(); bn=read_ipt()
    for ip,b in bn.items():
        if ip in _prev:
            pb,pt=_prev[ip]; dt=now-pt
            if dt>0.1: _rates[ip]=round(max(0,(b-pb)*8/dt/1e6),3)
        _prev[ip]=(b,now)
    for ip in list(_rates):
        if ip not in bn: del _rates[ip]
    return {ip:_rates.get(ip,0) for ip in peers}

def mtx(path):
    for v in('v3','v2'):
        try:
            with urllib.request.urlopen('http://127.0.0.1:9997/'+v+'/'+path,timeout=2) as r:
                return json.loads(r.read())
        except: pass
    return {}

def get_paths():
    return {p['name']:{'ready':p.get('ready',False),'tracks':p.get('tracks',[])}
            for p in mtx('paths/list').get('items',[])
            if p.get('name','').startswith(('app','cam'))}

def get_srtconns():
    return [{'path':c.get('path',''),'mbps':round(c.get('mbpsReceiveRate',0),3),
             'bytesRx':c.get('bytesReceived',0),'state':c.get('state',''),
             'remote':c.get('remoteAddr','')}
            for c in mtx('srtconns/list').get('items',[])]

def get_peers():
    try:
        out=subprocess.check_output(['conntrack','-L','-p','udp','--dport','5001'],text=True,stderr=subprocess.DEVNULL,timeout=3)
        ps=set()
        for ln in out.splitlines():
            if 'dport=5001' not in ln: continue
            i=ln.find('src=')
            if i<0: continue
            ip=ln[i+4:].split()[0]
            if ip and not ip.startswith('127.'): ps.add(ip)
        return sorted(ps)
    except: return []
_cpu_prev=[0,0]
def get_sys():
    try:
        vals=[int(x) for x in open('/proc/stat').readline().split()[1:]]
        idle=vals[3]+vals[4]; total=sum(vals)
        di=idle-_cpu_prev[0]; dt=total-_cpu_prev[1]
        _cpu_prev[0]=idle; _cpu_prev[1]=total
        cpu=round(100*(1-float(di)/dt),1) if dt>0 else 0
        m={}
        for ln in open('/proc/meminfo'):
            parts=ln.split()
            m[parts[0].rstrip(':')]=int(parts[1])
        memp=round(100*(1-float(m.get('MemAvailable',0))/m.get('MemTotal',1)),1)
        la=float(open('/proc/loadavg').read().split()[0])
        return {'cpu':cpu,'mem':memp,'load':la}
    except Exception:
        return {}

class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        peers=get_peers()
        rates=peer_rates(peers)
        body=json.dumps({'ts':time.time(),'paths':get_paths(),
                         'srtConns':get_srtconns(),
                         'srtlaPeers':peers,
                         'peerRates':rates,'sys':get_sys()}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Cache-Control','no-cache')
        self.send_header('Access-Control-Allow-Origin','*')
        self.end_headers()
        self.wfile.write(body)

setup()
print('bondstat on 127.0.0.1:9998')
HTTPServer(('127.0.0.1',9998),H).serve_forever()
