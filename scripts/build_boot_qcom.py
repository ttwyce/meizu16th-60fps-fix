import gzip, hashlib, os, struct, sys, zlib

D = r"C:\Users\ttwy\Desktop\sj\gsi\ssos"

def al(n, a=4096):
    return (n + a - 1) // a * a

def build(kernel_path, out_path):
    b = open(os.path.join(D, "boot.img"), "rb").read()
    page = struct.unpack_from("<I", b, 36)[0]
    ks = struct.unpack_from("<I", b, 8)[0]
    rs = struct.unpack_from("<I", b, 16)[0]

    region = b[page:page + ks]
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    d.decompress(region)
    d.flush()
    consumed = len(region) - len(d.unused_data)
    dtb = region[consumed:]                      # 追加的 DTB（含尾部零填充）
    assert dtb[:4] == b"\xd0\x0d\xfe\xed", "DTB magic 不对!"

    kernel = open(kernel_path, "rb").read()
    gz = gzip.compress(kernel, compresslevel=9, mtime=0)

    new_kernel = gz + dtb
    new_ks = len(new_kernel)

    r_off = page + al(ks, page)
    ramdisk = b[r_off:r_off + rs]
    r_pad = al(rs, page)

    total = page + al(new_ks, page) + r_pad
    img = bytearray(total)
    img[0:page] = b[0:page]
    struct.pack_into("<I", img, 8, new_ks)
    img[page:page + new_ks] = new_kernel
    ramdisk_off = page + al(new_ks, page)
    img[ramdisk_off:ramdisk_off + rs] = ramdisk

    open(out_path, "wb").write(bytes(img))

    print("  kernel: gzip=%d + dtb=%d = %d  (原 kernel_size=%d, 差 %+d)"
          % (len(gz), len(dtb), new_ks, ks, new_ks - ks))
    print("  ramdisk @%d (原 %d)  总大小 %d (原 %d)" % (ramdisk_off, r_off, total, len(b)))
    print("  ramdisk magic ok:", bytes(img[ramdisk_off:ramdisk_off + 2]) == b"\x1f\x8b")
    print("  dtb 位置: %d, magic: %s" % (page + len(gz), bytes(img[page + len(gz):page + len(gz) + 4]).hex()))

if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
