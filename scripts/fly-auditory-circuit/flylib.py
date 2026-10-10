import numpy as np, struct, zlib, glob, os
def load_mesh(path):
    b = open(path, 'rb').read()
    n = struct.unpack('<I', b[:4])[0]
    v = np.frombuffer(b, dtype='<f4', count=3*n, offset=4).reshape(-1, 3).astype(np.float64)
    t = np.frombuffer(b, dtype='<u4', offset=4+12*n).reshape(-1, 3)
    return v, t
def load_swc(path):
    rows = [l.split() for l in open(path) if l.strip() and not l.startswith('#')]
    a = np.array([[float(x) for x in r[:7]] for r in rows])
    return a  # id type x y z r parent (8nm 单位)
def png(path, img):
    h, w, _ = img.shape
    raw = b''.join(b'\x00' + img[y].astype(np.uint8).tobytes() for y in range(h))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))
def splat(img, xs, ys, color, alpha=1.0):
    h, w, _ = img.shape
    m = (xs >= 0) & (xs < w) & (ys >= 0) & (ys < h)
    xs = xs[m].astype(int); ys = ys[m].astype(int)
    img[ys, xs] = img[ys, xs] * (1 - alpha) + np.array(color) * alpha
