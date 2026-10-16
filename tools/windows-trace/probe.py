import struct,sys,uuid,collections
d=open(sys.argv[1],'rb').read()
BS=262144
ev=[]
c6=collections.Counter()
for b in range(1,len(d)//BS):
    base=b*BS
    bsz,saved,cur=struct.unpack_from('<III',d,base)
    cpu,lg=struct.unpack_from('<HH',d,base+0x28)
    p=base+0x48; end=base+min(saved,BS)
    while p+8<=end:
        size,mk,mn,x=struct.unpack_from('<HHHH',d,p)
        c6[(mk,x)]+=1
        g=uuid.UUID(bytes_le=d[p+8:p+24])
        ts,tid,pid=struct.unpack_from('<QII',d,p+24)
        ev.append((ts,b,p-base,mn,str(g),tid,pid,cpu,size))
        p+=(size+7)&~7
print(c6)
ev.sort()
for e in ev[:5]: print(e)
