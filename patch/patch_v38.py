import struct, hashlib, zlib, gzip, io
SRC=r"C:\Users\ttwy\Desktop\sj\01_基准原厂\handoff_kernel_patch\Image"
BOOT=r"C:\Users\ttwy\Desktop\sj\01_基准原厂\handoff_kernel_patch\boot.img"
OI=r"C:\Users\ttwy\Desktop\sj\00_最终成果\Image_v38.img"
OB=r"C:\Users\ttwy\Desktop\sj\00_最终成果\boot_v38.img"
def enc_bl(pc,t):
    d=(t-pc)>>2; assert -0x2000000<=d<0x2000000; return 0x94000000|(d&0x3FFFFFF)
def cbz(rt,d):  return 0x34000000|(((d>>2)&0x7FFFF)<<5)|rt
def cbnz(rt,d): return 0x35000000|(((d>>2)&0x7FFFF)<<5)|rt
def addx(rd,rn,imm): return 0x91000000|((imm&0xFFF)<<10)|(rn<<5)|rd
def ldaxr(rt,rn): return 0x885F7C00|(rn<<5)|rt
def stxr(rs,rt,rn): return 0x8800FC00|(rs<<16)|(rn<<5)|rt
def sub1(rd,rn): return 0x51000400|(rn<<5)|rd
img=bytearray(open(SRC,"rb").read()); orig=bytes(img)
for off,exp,new,d in [(0x56A94C,0x528001C2,0x52800142,"V20-A"),
                      (0x56A83C,0x52800081,0x52800061,"V20-B")]:
    o=struct.unpack_from("<I",img,off)[0]; assert o==exp, hex(off)
    struct.pack_into("<I",img,off,new); print("keep %s"%d)
CAVE=0x566864; CALL=0x56A0E8; REAL=0x55FE98; CBDONE=0x564BF0
seq=[(0x00,0xA9BE7BFD),(0x04,0xF9000BF3),(0x08,0xAA0003F3),
     (0x0C,enc_bl(CAVE+0x0C,REAL)),
     (0x10,0xF9400260),(0x14,0xAA1303E1),(0x18,0x52800122),
     (0x1C,enc_bl(CAVE+0x1C,CBDONE)),
     (0x20,addx(5,19,0x290)),(0x24,ldaxr(6,5)),(0x28,cbz(6,0x10)),
     (0x2C,sub1(6,6)),(0x30,stxr(7,6,5)),(0x34,cbnz(7,-0x10)),
     (0x38,0xF9400BF3),(0x3C,0xA8C27BFD),(0x40,0xD65F03C0)]
for off,val in seq: struct.pack_into("<I",img,CAVE+off,val)
struct.pack_into("<I",img,CALL,enc_bl(CALL,CAVE))
print("V36 cave 已写入")
O=0x55E478; old=struct.unpack_from("<I",img,O)[0]
print("0x55e478 原值: 0x%08x (ldrb w4,[x21,#0x31])"%old)
assert old==0x3940C6A4, "预期 3940c6a4 实际 %08x"%old
struct.pack_into("<I",img,O,0x52800024)
print("0x55e478 新值: 0x52800024 (mov w4,#1)  <- is_te_using_watchdog_timer 恒 true")
open(OI,"wb").write(bytes(img))
boot=bytearray(open(BOOT,"rb").read())
(ks,ka,rs,ra,ss,sa,tg,ps,hv,osv)=struct.unpack("<10I",boot[8:48])
kern=bytes(boot[ps:ps+ks]); do=zlib.decompressobj(16+zlib.MAX_WBITS)
od=do.decompress(kern)+do.flush(); gzs=len(kern)-len(do.unused_data); dtb=kern[gzs:]
assert od==orig
buf=io.BytesIO()
with gzip.GzipFile(fileobj=buf,mode="wb",compresslevel=9,mtime=0) as g: g.write(bytes(img))
ngz=buf.getvalue(); nk=ngz+dtb; nks=len(nk)
op=(ks+ps-1)//ps; assert (nks+ps-1)//ps==op
out=bytearray(boot); struct.pack_into("<I",out,8,nks)
out[ps:ps+nks]=nk; pe=ps+op*ps
out[ps+nks:pe]=b"\x00"*(pe-(ps+nks))
open(OB,"wb").write(bytes(out))
print("\nboot_v38 md5:",hashlib.md5(bytes(out)).hexdigest())
chk=open(OB,"rb").read(); ck=chk[ps:ps+nks]
d2=zlib.decompressobj(16+zlib.MAX_WBITS); ri=d2.decompress(ck)+d2.flush()
print("verify:",ri==bytes(img))
