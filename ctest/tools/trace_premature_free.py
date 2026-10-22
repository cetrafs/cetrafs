# SPDX-License-Identifier: GPL-2.0-or-later
import re,sys,glob,datetime
it=sys.argv[1]
def ts(x):
    try: return datetime.datetime.fromisoformat(x.split('+')[0].replace(',','.'))
    except: return None
ev=[]
for f in glob.glob(f"/root/revhunt/dm-{it}-*.txt"):
    h=f.split('-')[-1].replace('.txt','')
    for ln in open(f,errors="ignore"):
        m=re.search(r"^(\S+) cetrafs: ADDNAME dir=(\d+) name='([^']+)' ino=(\d+)",ln)
        if m: ev.append((ts(m.group(1)),h,'A',int(m.group(2)),m.group(3),int(m.group(4)))); continue
        m=re.search(r"^(\S+) cetrafs: REMNAME dir=(\d+) name='([^']+)' ino=(\d+)",ln)
        if m: ev.append((ts(m.group(1)),h,'R',int(m.group(2)),m.group(3),int(m.group(4)))); continue
        m=re.search(r"^(\S+) cetrafs: RETGT dir=(\d+) name='([^']+)' new_ino=(\d+) removed_ino=(\d+)",ln)
        if m:
            t=ts(m.group(1)); d=int(m.group(2)); n=m.group(3)
            ev.append((t,h,'R',d,n,int(m.group(5))))   # victim loses the name
            ev.append((t,h,'A',d,n,int(m.group(4))))   # new ino gains it
            continue
        m=re.search(r"^(\S+) cetrafs: INOFREE ino=(\d+) nlink_on_disk=(\d+) size=(\d+) from=(\S+)",ln)
        if m: ev.append((ts(m.group(1)),h,'F',None,None,int(m.group(2)),int(m.group(3)),m.group(5)))
ev=[e for e in ev if e[0]]; ev.sort(key=lambda e:e[0])
names={}; hits=[]
for e in ev:
    if e[2]=='A': names.setdefault(e[5],set()).add((e[3],e[4]))
    elif e[2]=='R': names.get(e[5],set()).discard((e[3],e[4]))
    else:
        t,h,_,_,_,i,nl,fn=e
        if names.get(i):
            hits.append(f"{t} {h} FREED ino={i} (disk nlink={nl}, by {fn.split('+')[0]}) names={list(names[i])[:3]}")
for x in hits[:6]: print("HIT: PREMATURE-FREE",x)
print(f"premature frees (retarget-aware): {len(hits)}")
sys.exit(0 if hits else 1)
