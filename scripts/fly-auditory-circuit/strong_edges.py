# 从 1.5 亿条连接里只留权重 >= 5 的（强连接），存成 npz，后面的筛选都在它上面做。
import sys, numpy as np, pyarrow.ipc as ipc, pyarrow as pa
src, dst, minw = sys.argv[1], sys.argv[2], int(sys.argv[3])
reader = ipc.open_file(pa.memory_map(src))
pres, posts, ws = [], [], []
total = 0
for i in range(reader.num_record_batches):
    b = reader.get_batch(i)
    w = b.column('weight').to_numpy()
    m = w >= minw
    total += len(w)
    pres.append(b.column('body_pre').to_numpy()[m]); posts.append(b.column('body_post').to_numpy()[m]); ws.append(w[m].astype(np.int32))
pre = np.concatenate(pres); post = np.concatenate(posts); w = np.concatenate(ws)
np.savez(dst, pre=pre, post=post, w=w)
print('batches', reader.num_record_batches, 'rows', total, 'kept', len(w))
