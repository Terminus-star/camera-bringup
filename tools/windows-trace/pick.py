import re,sys
rows=[l.rstrip('\n').split('\t',1) for l in open(sys.argv[1])][1:]
kw=re.compile(r'mipi|csi|sensor|mode|lane|rate|stream|buffer|isp_|fw_|phy|i2c|gpio|clk|clock|power|fps|resol|width|height|bayer|raw|exposure',re.I)
seen=set();out=[]
# prefer rarer strings: first occurrence order, dedupe by digit-normalised form
for c,s in rows:
    k=re.sub(r'\d+','#',s)
    if k in seen or len(s)<5: continue
    seen.add(k)
    if kw.search(s): out.append((int(c),s))
print(len(rows),len(out))
import collections
# score: prefer strings with several keywords / config-like words
def score(s): return len(set(m.lower() for m in kw.findall(s[1])))+ (2 if re.search(r'mipi|csi|sensor|lane|phy',s[1],re.I) else 0)
best=sorted(out,key=lambda x:(-score(x),x[0]))[:40]
best.sort()
with open(sys.argv[2],'w') as f:
    f.write('first_clock\tstring\n')
    for c,s in best: f.write('%d\t%s\n'%(c,s))
