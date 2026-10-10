# 生成 PrimuseKit/Sources/PrimuseKit/Resources/FlyAuditoryCircuit.bin（全屏效果「果蝇听歌」）。
#
# 数据：Male CNS v1.0 连接组，Janelia FlyEM 与 Google，CC BY 4.0（https://male-cns.janelia.org/）。
# 在一个工作目录里按顺序跑（需要 Python 3 与 numpy、pandas、pyarrow、shapely）：
#   1. 下载到 flydata/：
#      https://storage.googleapis.com/flyem-male-cns/v1.0/connectome-data/flat-connectome/
#        body-annotations-male-cns-v1.0-minconf-0.5.feather       -> flydata/body-annotations.feather
#        body-neurotransmitters-male-cns-v1.0.feather              -> flydata/body-nt.feather
#        connectome-weights-male-cns-v1.0-minconf-0.5.feather      -> flydata/weights.feather（约 1 GB）
#   2. strong_edges.py flydata/weights.feather flydata/strong.npz 5
#   3. select_circuit.py                         -> flydata/circuit.json、按其中的 id 下载骨架：
#      https://storage.googleapis.com/flyem-male-cns/v1.0/segmentation/skeletons-malecns/skeletons-swc/<id>.swc -> flydata/swc/
#   4. 下载脑区网格：https://storage.googleapis.com/flyem-male-cns/rois/fullbrain-roi-v4/mesh/
#      （segment_properties/info 列出名字，mesh/<id>:0 列出碎片）-> flydata/roi/frag_NNN.ngmesh 与 frag_index.txt
#   5. build_fly.py FlyAuditoryCircuit.bin 60 4  （最后两个数：剪掉短于多少 µm 的细枝、折线化简容差 µm）
# 生成果蝇听觉通路资源：脑区切片轮廓、裁剪化简后的神经元骨架、神经元之间的连接、推算的突触位置、脑区标签。
# 数据：Janelia FlyEM 与 Google 的 Male CNS v1.0（CC BY 4.0）。坐标单位 µm。
import sys, json, struct, math, random
import numpy as np
from shapely.geometry import MultiLineString, Polygon
from shapely.ops import polygonize, unary_union
sys.path.insert(0, __import__('os').path.dirname(__file__))
from flylib import load_mesh, load_swc

OUT = sys.argv[1]
P = dict(lmin=float(sys.argv[2]) if len(sys.argv) > 2 else 60.0,
         eps=float(sys.argv[3]) if len(sys.argv) > 3 else 4.0)
random.seed(7)

idx = dict(l.split('\t') for l in open('flydata/roi/frag_index.txt').read().split('\n') if l)
meshes = {}
for k, f in idx.items():
    v, t = load_mesh(f'flydata/roi/frag_{k}.ngmesh')
    meshes[f.replace('.ngmesh', '')] = (v / 1000.0, t.astype(np.int64))
allv = np.concatenate([m[0] for m in meshes.values()])
lo, hi = allv.min(0), allv.max(0)
center = (lo + hi) / 2
scale = (hi - lo).max() / 2 * 1.02
print('brain bounds um', lo.round(1), hi.round(1), 'scale', round(scale, 1))

def slice_mesh(v, t, axis, c):
    d = v[:, axis] - c
    s = d[t] > 0
    cross = s.any(1) & ~s.all(1)
    tt = t[cross]
    segs = []
    for tri in tt:
        pts = []
        for a, b in ((0, 1), (1, 2), (2, 0)):
            i, j = tri[a], tri[b]
            if (d[i] > 0) != (d[j] > 0):
                if i > j: i, j = j, i
                u = d[i] / (d[i] - d[j])
                p = v[i] + (v[j] - v[i]) * u
                pts.append(tuple(np.delete(p, axis)))
        if len(pts) == 2: segs.append(pts)
    return segs

def section_polygons(names, axis, c):
    polys = []
    for n in names:
        v, t = meshes[n]
        if not (v[:, axis].min() < c < v[:, axis].max()): continue
        segs = slice_mesh(v, t, axis, c)
        if not segs: continue
        polys.extend(p for p in polygonize(MultiLineString(segs)) if p.area > 4)
    return polys

def rings_of(geom):
    out = []
    gs = getattr(geom, 'geoms', [geom])
    for g in gs:
        if g.is_empty or g.geom_type != 'Polygon': continue
        out.append(list(g.exterior.coords))
        for h in g.interiors:
            if Polygon(h).area > 300: out.append(list(h.coords))
    return out

def lift(coords2d, axis, c):
    res = []
    for q in coords2d:
        q = list(q); q.insert(axis, c); res.append(q)
    return res

AUDITORY = ['AMMC(L)', 'AMMC(R)', 'SAD', 'WED(L)', 'WED(R)', 'AVLP(L)', 'AVLP(R)']
import os, pickle
CACHE = 'flydata/outlines.pkl'
outlines = []  # (flags, points µm)
if os.path.exists(CACHE):
    outlines = pickle.load(open(CACHE, 'rb'))
    print('outline cache', len(outlines))
else:
  outlines = []
  everything = list(meshes.keys())
  # 水平切片（沿背腹轴）
  for c in np.linspace(lo[1] + 22, hi[1] - 18, 13):
      union = unary_union(section_polygons(everything, 1, c)).simplify(1.6)
      for r in rings_of(union):
          if len(r) >= 4: outlines.append((1, lift(r, 1, c)))
      aud = section_polygons(AUDITORY, 1, c)
      for p in aud:
          r = list(p.simplify(1.2).exterior.coords)
          if len(r) >= 4: outlines.append((1 | 2, lift(r, 1, c)))
  # 纵向切片（沿左右轴），让外壳转起来有立体的经线
  for c in np.linspace(lo[0] + 60, hi[0] - 60, 7):
      union = unary_union(section_polygons(everything, 0, c)).simplify(2.0)
      for r in rings_of(union):
          if len(r) >= 4: outlines.append((1 | 4, lift(r, 0, c)))
  pickle.dump(outlines, open(CACHE, 'wb'))
print('outline rings', len(outlines), 'points', sum(len(p) for _, p in outlines))

# 神经元
circ = json.load(open('flydata/circuit.json'))
neurons = circ['neurons']
margin = 4.0
def inside(p):
    return (lo[0] - margin <= p[0] <= hi[0] + margin) and (lo[1] - margin <= p[1] <= hi[1] + margin) and (lo[2] - margin <= p[2] <= hi[2] + margin)

def dp(points, eps):
    if len(points) < 3: return points
    a = np.array(points)
    keep = [0, len(a) - 1]
    stack = [(0, len(a) - 1)]
    while stack:
        s, e = stack.pop()
        if e <= s + 1: continue
        seg = a[e] - a[s]; L = np.linalg.norm(seg)
        rel = a[s + 1:e] - a[s]
        if L < 1e-9: dist = np.linalg.norm(rel, axis=1)
        else: dist = np.linalg.norm(np.cross(rel, seg / L), axis=1)
        i = int(np.argmax(dist))
        if dist[i] > eps:
            m = s + 1 + i; keep.append(m); stack.append((s, m)); stack.append((m, e))
    return [points[i] for i in sorted(keep)]

cells_of = {}
neuron_polys = []
total_pts = 0
for n in neurons:
    a = load_swc(f"flydata/swc/{n['id']}.swc")
    ids = a[:, 0].astype(int); par = a[:, 6].astype(int); xyz = a[:, 2:5] * 0.008
    index = {i: k for k, i in enumerate(ids)}
    ok = np.array([inside(p) for p in xyz])
    parent = [index.get(p, -1) if p != -1 else -1 for p in par]
    parent = [p if (p >= 0 and ok[k] and ok[p]) else -1 for k, p in enumerate(parent)]
    cells = {}
    for k in np.nonzero(ok)[0]:
        key = tuple((xyz[k] // 2.0).astype(int))
        cells.setdefault(key, xyz[k])
    cells_of[n['id']] = cells
    children = [[] for _ in ids]
    for k, p in enumerate(parent):
        if p >= 0: children[p].append(k)
    order = []
    roots = [k for k in range(len(ids)) if ok[k] and parent[k] < 0]
    stack = list(roots)
    while stack:
        k = stack.pop(); order.append(k); stack.extend(children[k])
    height = np.zeros(len(ids))
    for k in reversed(order):
        for c in children[k]:
            height[k] = max(height[k], height[c] + np.linalg.norm(xyz[c] - xyz[k]))
    kept_children = [[] for _ in ids]
    for k in order:
        if not children[k]: continue
        best = max(children[k], key=lambda c: height[c])
        for c in children[k]:
            if c == best or height[c] + np.linalg.norm(xyz[c] - xyz[k]) >= P['lmin']:
                kept_children[k].append(c)
    # 只留撑得起来的根：太碎的小块（裁剪后残留的一小截）不要
    roots = [r for r in roots if height[r] >= P['lmin']]
    dist = {}
    polys = []
    for r in roots:
        dist[r] = 0.0
        stack = [(r, [r])]
        while stack:
            k, line = stack.pop()
            kc = kept_children[k]
            while len(kc) == 1:
                c = kc[0]; dist[c] = dist[k] + np.linalg.norm(xyz[c] - xyz[k]); line.append(c); k = c; kc = kept_children[k]
            if len(line) >= 2: polys.append(line)
            for c in kc:
                dist[c] = dist[k] + np.linalg.norm(xyz[c] - xyz[k])
                stack.append((c, [k, c]))
    maxd = max(dist.values()) if dist else 1.0
    out = []
    for line in polys:
        pts = [tuple(xyz[k]) + (dist[k] / maxd,) for k in line]
        simp = dp([p[:3] for p in pts], P['eps'])
        sset = {tuple(p) for p in simp}
        pts = [p for p in pts if p[:3] in sset]
        if len(pts) >= 2: out.append(pts)
    neuron_polys.append(out)
    total_pts += sum(len(l) for l in out)
print('neuron points', total_pts, 'polylines', sum(len(o) for o in neuron_polys))

# 突触：两条骨架在同一个 2 µm 小格里相遇的地方
order_ids = [n['id'] for n in neurons]
pos = {b: i for i, b in enumerate(order_ids)}
syn = []
for pre, post, w in circ['edges']:
    if w < 10: continue
    common = list(set(cells_of[pre]) & set(cells_of[post]))
    if not common: continue
    random.shuffle(common)
    k = min(len(common), 1 + w // 60, 3)
    for key in common[:k]:
        syn.append((pos[pre], pos[post], cells_of[pre][key]))
if len(syn) > 3200:
    syn = random.sample(syn, 3200)
syn.sort(key=lambda s: (s[0], s[1]))
print('synapse sites', len(syn))

labels = {}
for name in ['AMMC(L)', 'WED(L)', 'SAD', 'AVLP(L)', 'GNG', 'AL(R)', 'LH(R)', 'ME(R)', 'LO(R)', 'CA(R)', 'ME(L)']:
    v, _ = meshes[name]; labels[name] = v.mean(0)

def q(p):
    return [int(round(max(-1, min(1, (p[i] - center[i]) / scale)) * 32767)) for i in range(3)]

roles = []
for n in neurons:
    t = n['type']
    if t.startswith('JO-A'): roles.append(0)
    elif t.startswith('JO-B'): roles.append(1)
    elif n['superclass'] == 'descending_neuron': roles.append(3)
    else: roles.append(2)

buf = bytearray()
buf += b'PMFC' + struct.pack('<HH', 1, 0)
buf += struct.pack('<f', scale)
buf += struct.pack('<IHIIH', len(outlines), len(neurons), len(circ['edges']), len(syn), len(labels))
for flags, pts in outlines:
    buf += struct.pack('<BBH', 0, flags, len(pts))
    for p in pts: buf += struct.pack('<hhh', *q(p))
for n, role, polys in zip(neurons, roles, neuron_polys):
    sub = n['type']
    m = __import__('re').match(r'JO-([AB])(\d)?', sub)
    subtype = int(m.group(2)) if (m and m.group(2)) else 0
    buf += struct.pack('<BbBBH', n['layer'], n['sign'], role, subtype, len(polys))
    for line in polys:
        buf += struct.pack('<H', len(line))
        for p in line:
            buf += struct.pack('<hhhH', *q(p[:3]), int(round(p[3] * 65535)))
edges = sorted((pos[a], pos[b], w) for a, b, w in circ['edges'])
for a, b, w in edges: buf += struct.pack('<HHH', a, b, min(w, 65535))
for a, b, p in syn: buf += struct.pack('<HHhhh', a, b, *q(p))
for name, p in labels.items():
    nb = name.encode()
    buf += struct.pack('<B', len(nb)) + nb + struct.pack('<hhh', *q(p))
open(OUT, 'wb').write(bytes(buf))
print('wrote', OUT, len(buf), 'bytes')
