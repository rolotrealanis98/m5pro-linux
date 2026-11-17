import sys, zlib, struct
# black-pixel fraction and bbox of an 8-bit RGB/RGBA non-interlaced PNG (stdlib only)
d=open(sys.argv[1],'rb').read(); i=8; idat=b''
while i<len(d):
    ln,=struct.unpack('>I',d[i:i+4]); t=d[i+4:i+8]; c=d[i+8:i+8+ln]; i+=12+ln
    if t==b'IHDR': w,h,bd,ct,_,_,il=struct.unpack('>IIBBBBB',c)
    elif t==b'IDAT': idat+=c
bpp={2:3,6:4}[ct]; raw=zlib.decompress(idat); st=w*bpp; prev=bytearray(st); p=0
n=0; tot=0; x0=w; y0=h; x1=y1=-1
for y in range(h):
    f=raw[p]; line=bytearray(raw[p+1:p+1+st]); p+=1+st
    if f==1:
        for k in range(bpp,st): line[k]=(line[k]+line[k-bpp])&255
    elif f==2:
        for k in range(st): line[k]=(line[k]+prev[k])&255
    elif f==3:
        for k in range(st): line[k]=(line[k]+((line[k-bpp] if k>=bpp else 0)+prev[k])//2)&255
    elif f==4:
        for k in range(st):
            a=line[k-bpp] if k>=bpp else 0; b=prev[k]; c=prev[k-bpp] if k>=bpp else 0
            pa=abs(b-c); pb=abs(a-c); pc=abs(a+b-2*c)
            line[k]=(line[k]+(a if pa<=pb and pa<=pc else b if pb<=pc else c))&255
    prev=line
    if y%2: continue
    for x in range(0,w,2):
        k=x*bpp; tot+=1
        if line[k]==0 and line[k+1]==0 and line[k+2]==0:
            n+=1; x0=min(x0,x); x1=max(x1,x); y0=min(y0,y); y1=max(y1,y)
print("%dx%d black=%.3f bbox=%s"%(w,h,n/tot,(x0,y0,x1,y1) if n else None))
