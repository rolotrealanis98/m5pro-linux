import sys
# black-pixel fraction and bbox in a binary PPM (P6)
d=open(sys.argv[1],'rb').read()
parts=[];i=0
while len(parts)<4:
    while d[i:i+1].isspace(): i+=1
    if d[i:i+1]==b'#':
        while d[i:i+1]!=b'\n': i+=1
        continue
    j=i
    while not d[j:j+1].isspace(): j+=1
    parts.append(d[i:j]); i=j
i+=1
w,h=int(parts[1]),int(parts[2]); px=d[i:]
n=0; x0=w; y0=h; x1=-1; y1=-1
row=w*3
for y in range(0,h,2):
    r=px[y*row:(y+1)*row]
    for x in range(0,w,2):
        k=x*3
        if r[k]==0 and r[k+1]==0 and r[k+2]==0:
            n+=1
            if x<x0:x0=x
            if x>x1:x1=x
            if y<y0:y0=y
            if y>y1:y1=y
tot=((w+1)//2)*((h+1)//2)
print("black=%.3f bbox=%s" % (n/tot, (x0,y0,x1,y1) if n else None))
