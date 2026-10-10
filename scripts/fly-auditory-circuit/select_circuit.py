# 从听觉入口出发按真实连接逐层选神经元，输出 circuit.json（身份、类型、层、递质符号、彼此的连接）。
import sys, json, numpy as np, pandas as pd
ann = pd.read_feather('flydata/body-annotations.feather')
nt = pd.read_feather('flydata/body-nt.feather', columns=['body', 'consensus_nt', 'predicted_nt'])
e = np.load('flydata/strong.npz')
pre, post, w = e['pre'], e['post'], e['w']
ann = ann.set_index('bodyId')
ok = ann[(ann['status'] == 'Traced') & ann['type'].notna()]
typ = ok['type'].astype(str)
inputs = list(ok[typ.str.startswith('JO-A') | typ.str.startswith('JO-B')].index)
print('inputs', len(inputs))
layer = {b: 0 for b in inputs}
budget = [None, 80, 80, 64, 50]
side = (ok['somaSide'].fillna(ok['rootSide'])).fillna('M').astype(str).to_dict()
eligible = set(ok[~ok['superclass'].isin(['ol_intrinsic', 'visual_projection', 'vnc_intrinsic', 'vnc_sensory', 'vnc_motor'])].index)
for L in range(1, 5):
    src = np.array([b for b, l in layer.items() if l == L - 1])
    m = np.isin(pre, src)
    df = pd.DataFrame({'post': post[m], 'w': w[m]})
    df = df[df['post'].isin(eligible) & ~df['post'].isin(layer.keys())]
    score = df.groupby('post')['w'].sum().sort_values(ascending=False)
    # 左右各挑一半，画面对称；居中的（M）算进较少的那一侧
    picked = {'L': [], 'R': []}
    for body in score.index:
        sd = side.get(body, 'M')
        sd = sd if sd in picked else min(picked, key=lambda k: len(picked[k]))
        if len(picked[sd]) < budget[L] // 2: picked[sd].append(body)
        if all(len(v) >= budget[L] // 2 for v in picked.values()): break
    chosen = picked['L'] + picked['R']
    for b in chosen: layer[b] = L
    print('layer', L, 'candidates', len(score), 'chosen', len(chosen), 'L/R', len(picked['L']), len(picked['R']), 'min score', int(min(score[b] for b in chosen)))
ids = np.array(list(layer.keys()))
m = np.isin(pre, ids) & np.isin(post, ids)
edges = [(int(a), int(b), int(c)) for a, b, c in zip(pre[m], post[m], w[m])]
print('edges among selected', len(edges))
ntmap = nt.set_index('body')['consensus_nt'].to_dict()
def sign(b):
    v = ntmap.get(b)
    if v == 'acetylcholine': return 1
    if v in ('gaba', 'glutamate'): return -1
    return 0
neurons = []
for b, l in layer.items():
    r = ann.loc[b]
    neurons.append({'id': int(b), 'type': str(r['type']), 'layer': l, 'sign': sign(b), 'superclass': str(r['superclass']), 'side': str(r['somaSide'] or r['rootSide'] or '')})
json.dump({'neurons': neurons, 'edges': edges}, open('flydata/circuit.json', 'w'))
s = pd.Series([n['type'] for n in neurons if n['layer'] > 0])
print(s.str.extract(r'^([A-Za-z]+)')[0].value_counts().head(15).to_dict())
print('signs', pd.Series([n['sign'] for n in neurons]).value_counts().to_dict())
