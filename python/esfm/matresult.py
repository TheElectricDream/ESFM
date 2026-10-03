"""Read the MATLAB v7.3 result.mat produced by prog.package_result (reference only)."""
import h5py
import numpy as np


def _read(node, f):
    if isinstance(node, h5py.Group):
        return {k: _read(node[k], f) for k in node.keys()}
    a = node[()]
    if node.attrs.get('MATLAB_class', b'') == b'char':
        return ''.join(map(chr, np.asarray(a).ravel()))
    a = np.asarray(a)
    if a.dtype == object:
        return a
    return a.T.squeeze() if a.ndim >= 2 else a


def load(path):
    with h5py.File(path, 'r') as f:
        r = _read(f['result'], f)
    tr = r['traj']
    trj = dict(t0=float(tr['t0']), h=float(tr['h']), n_seg=int(tr['n_seg']), K=int(tr['K']),
               knot_t=np.ravel(tr['knot_t']), a=np.ravel(tr['a']), omega=float(tr['omega']),
               c=np.ravel(tr['c']), V=np.ravel(tr['V']), k=np.ravel(tr['k']), m=np.atleast_2d(tr['m']))
    r['traj_py'] = trj
    return r
