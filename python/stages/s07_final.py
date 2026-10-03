"""Stage 7 - offline final refinement, scale, export (prog.final_refinement, package_result)."""
import os
import numpy as np
from common import get_cfg, get_cam, save, load, CACHE
from esfm import prog, traj, data

cfg = get_cfg()
cam = get_cam(cfg)
P = load('progressive')
m = P['map']
fin = prog.final_refinement(m, cfg.data.end_time_s, cam, cfg)
X = fin['X'][fin['keep']]
scale = prog.calibrate_scale(X, cfg.output)
t_pose = np.arange(cfg.data.start_time_s, cfg.data.end_time_s + 1e-9, cfg.data.slice_s)
pose = traj.sample_refined_trajectory(fin['traj'], t_pose, scale['m_per_unit'])
res = dict(final=fin, X=X, X_m=X * scale['m_per_unit'], scale=scale, pose=pose,
           nobs=m['nobs'][fin['keep']], normal_rms_px=np.sqrt(np.mean(fin['dn'] ** 2)))
print(f'Final: {len(fin["keep"])} of {len(m["X"])} landmarks kept, {len(fin["O"])} observations, '
      f'normal RMS {res["normal_rms_px"]:.3f} px, {fin["revisit"].sum()} revisited')
print(f'Mean spin {np.rad2deg(fin["traj"]["omega"]):.4f} deg/s, axis {fin["traj"]["a"]}')
print(f'Scale {scale["m_per_unit"]:.4f} m/unit')
save('final', res)
out = os.path.join(CACHE, 'export')
os.makedirs(out, exist_ok=True)
data.write_ply(os.path.join(out, 'cloud_m.ply'), res['X_m'])
