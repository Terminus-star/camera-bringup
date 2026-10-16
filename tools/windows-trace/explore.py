import struct,sys,collections
d=open(sys.argv[1],'rb').read()
BS=262144
cnt=collections.Counter(); bad=0
for b in range(len(d)//BS):
    base=b*BS
    bsz,saved,cur=struct.unpack_from('<III',d,base)
    p=base+0x48
    end=base+min(saved,BS)
    while p+8<=end:
        w,=struct.unpack_from('<I',d,p)
        hi=w>>16
        if hi==0xc002 or (w&0xffff)==2 and hi&0xc000:
            size,=struct.unpack_from('<H',d,p+4)
        else:
            size=w&0xffff
        cnt[hex(hi)]+=1
        if size<8:
            bad+=1; print('bad',b,hex(p-base),hex(w)); break
        p+=(size+7)&~7
    if p!=end and b<100: print('buf',b,'end mismatch',hex(p-base),hex(end-base))
print(cnt.most_common(20),bad)
