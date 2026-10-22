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
        m=re.search(r"^(\S+) cetrafs: IBCAS fs_lba=2064 reg=0 dev_lba=\d+ att=(\d+) ret=(0|-16) old0=([0-9a-f]{8}) new0=([0-9a-f]{8})",ln)
        if m and m.group(3)=='0':
            ev.append((ts(m.group(1)),h,int(m.group(4),16),int(m.group(5),16)))
ev=[e for e in ev if e[0]]; ev.sort(key=lambda e:e[0])
def bits(x): return bin(x).count('1')
multi=0; chain_breaks=0; prev_new=None; examples=[]
for t,h,old,new in ev:
    d = old ^ new
    if bits(d) > 1:
        multi+=1
        if len(examples)<4: examples.append(f"MULTIBIT {t} {h} old={old:08x} new={new:08x} flips={bits(d)}")
    if prev_new is not None and old != prev_new:
        # device changed between CASes: fine if another node's CAS did it;
        # but compare against ALL seen new-images -- a backward jump is one
        # where bits SET in prev_new are CLEAR in old with no free logged.
        lost = prev_new & ~old
        if bits(lost) >= 2:
            chain_breaks+=1
            if len(examples)<8: examples.append(f"BACKWARD {t} {h} prev_new={prev_new:08x} old={old:08x} lost_bits={bits(lost)}")
    prev_new=new
print(f"successful CASes: {len(ev)}  multi-bit writes: {multi}  backward jumps(>=2 lost): {chain_breaks}")
for x in examples: print(" ",x)
