"""Offline union/intersection of saved physical trace intervals, no device commands."""
import argparse,json,math,subprocess
from pathlib import Path
import xml.etree.ElementTree as E

def rows(path):
    try:data=path.read_bytes()
    except PermissionError:data=subprocess.check_output(['cat',str(path)])
    root=E.fromstring(data);ids={n.attrib['id']:n for n in root.iter() if 'id' in n.attrib}
    def resolve(n):
        while 'ref' in n.attrib:n=ids[n.attrib['ref']]
        return n
    out=[]
    for node in root:
        schema=node.find('schema')
        if schema is None:continue
        columns=[x.findtext('mnemonic') for x in schema]
        for row in node.findall('row'):
            value={}
            for k,n in zip(columns,row):
                n=resolve(n)
                try:number=float(n.text)
                except (ValueError,TypeError):number=None
                value[k]=(number,n.get('fmt',n.text or ''))
            out.append(value)
    return out

def union(values):
    result=[]
    for start,end in sorted(values):
        if result and start<=result[-1][1]:result[-1]=(result[-1][0],max(end,result[-1][1]))
        else:result.append((start,end))
    return result

def length(values):return sum(end-start for start,end in union(values))
def overlap(a,b):
    a,b=union(a),union(b);i=j=0;total=0
    while i<len(a) and j<len(b):
        total+=max(0,min(a[i][1],b[j][1])-max(a[i][0],b[j][0]))
        if a[i][1]<b[j][1]:i+=1
        else:j+=1
    return total

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('wait',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    enc=rows(a.run/'encoders.xml');roles={}
    for e in enc:
        cb=e['cmdbuffer-id'][1];label=e['encoder-label'][1]
        if 'Render Command' in label:roles[cb]='composition'
        elif 'ci_' in label and roles.get(cb)!='composition':roles[cb]='mask'
        elif cb not in roles:roles[cb]='caption'
    gpu=rows(a.run/'gpu.xml');intervals={};all_gpu=[]
    for r in gpu:
        start,duration=r['start'][0],r['duration'][0];role=roles.get(r['cmdbuffer-id'][1])
        if start is None or duration is None or start<1e9 or role is None:continue
        interval=(start,start+duration);key=role+' '+r['channel-name'][1]
        intervals.setdefault(key,[]).append(interval);all_gpu.append(interval)
    lo=min(x[0] for x in all_gpu);hi=max(x[1] for x in all_gpu)
    waits=[]
    for r in rows(a.wait):
        s,d=r['start'][0],r['duration'][0]
        if s is not None and d is not None and 'GradientsV4Comparison' in r['thread'][1] and max(s,lo)<min(s+d,hi):waits.append((max(s,lo),min(s+d,hi)))
    result={'windowSeconds':(hi-lo)/1e9,'GPUIntervalUnionMS':length(all_gpu)/1e6,
        'GPUIntervalUnionByRoleMS':{k:length(v)/1e6 for k,v in intervals.items()},
        'mainDrawableWaitMS':length(waits)/1e6,'drawableWaitCount':len(waits),
        'drawableWaitOverlappingGPUPercent':overlap(waits,all_gpu)/max(1,length(waits))*100,
        'drawableWaitOverlappingBackgroundComputePercent':overlap(waits,intervals.get('composition Compute',[]))/max(1,length(waits))*100,
        'note':'Intervals include driver stalls and may overlap. Unions are timeline occupancy proxies, not additive ALU execution cost.'}
    a.output.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
