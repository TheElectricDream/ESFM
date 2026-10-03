"""F01 pipeline overview with the real counts from every stage; writes facts_overview.json."""
import json
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from style import *  # noqa
from esfm import config

cfg = config.config(start_time_s=float(os.environ.get('ESFM_T0', 60)), end_time_s=float(os.environ.get('ESFM_T1', 185)))
E = npz('events'); S = npz('surface')
Wt = load('warm_tracks'); Fw = load('warm_fit'); Sm = load('seed_map'); P = load('progressive'); Fn = load('final')
fx = dict(
    n_events=int(E['t'].size), dur=float(cfg.data.end_time_s - cfg.data.start_time_s),
    n_accept=int(S['accept'].sum()), frac_accept=float(S['accept'].mean()),
    n_tracks=int(Wt['obs'].shape[1]), n_warm_obs=int(Wt['fi'].size),
    w_deg=float(abs(np.rad2deg(Fw['refined']['w']))), axis=Fw['refined']['a'].tolist(),
    seed_rms0=float(np.sqrt(np.mean(Sm['dn0'] ** 2))), seed_rms1=float(np.sqrt(np.mean(Sm['dn1'] ** 2))),
    n_slices=int(len(P['centers'])), map_size=int(len(P['map']['X'])), map_obs=int(len(P['map']['O'])),
    n_final=int(len(Fn['X'])), final_obs=int(len(Fn['final']['O'])), final_rms=float(Fn['normal_rms_px']),
    final_w_deg=float(abs(np.rad2deg(Fn['final']['traj']['omega']))), final_axis=Fn['final']['traj']['a'].tolist(),
    scale=float(Fn['scale']['m_per_unit']), n_revisit=int(Fn['final']['revisit'].sum()),
    K=int(Fn['final']['traj']['K']))
json.dump(fx, open(os.path.join(OUT, 'facts_overview.json'), 'w'), indent=1)

stages = [('events', f'{fx["n_events"]/1e6:.1f} M events\n{fx["dur"]:.0f} s'),
          ('undistort', 'fisheye →\npinhole'),
          ('planes', f'{100*fx["frac_accept"]:.0f} % accepted\nnormal flow'),
          ('warm tracks', f'{fx["n_tracks"]} tracks\nfirst {cfg.warm.duration_s:.0f} s'),
          ('twist fit', f'{fx["w_deg"]:.2f} °/s\naxis sweep'),
          ('seed BA', f'{fx["n_tracks"]} points\n{fx["seed_rms1"]:.2f} px'),
          ('progressive', f'{fx["n_slices"]} slices\n{fx["map_size"]} landmarks'),
          ('final BA', f'{fx["n_final"]} points\n{fx["final_rms"]:.2f} px')]
fig, ax = plt.subplots(figsize=(8.4, 2.3))
fig.subplots_adjust(0, 0, 1, 1)
ax.set_xlim(0, 8.4); ax.set_ylim(0, 2.3); ax.axis('off')
n = len(stages); w, h, gap = 0.88, 1.2, 0.13
x0 = (8.4 - (n * w + (n - 1) * gap)) / 2
groups = [(0, 2, 'front end'), (3, 5, 'warm start'), (6, 7, 'map building')]
for a, b, g in groups:
    xa = x0 + a * (w + gap); xb = x0 + b * (w + gap) + w
    ax.plot([xa, xb], [1.95, 1.95], color=GREY, lw=0.8)
    ax.text((xa + xb) / 2, 2.02, g, ha='center', fontsize=8.5, color=DARK)
for i, (t, sub) in enumerate(stages):
    x = x0 + i * (w + gap)
    hl = i in (2, 4, 6)
    ax.add_patch(FancyBboxPatch((x, 0.55), w, h, boxstyle='round,pad=0.02,rounding_size=0.08', fc=RED if hl else PALE, ec='none'))
    ax.text(x + w / 2, 0.55 + h - 0.22, t, ha='center', va='center', fontsize=9, fontweight='bold', color='white' if hl else BLACK)
    ax.text(x + w / 2, 0.55 + 0.42, sub, ha='center', va='center', fontsize=7.8, color='white' if hl else DARK, linespacing=1.25)
    if i < n - 1:
        ax.annotate('', xy=(x + w + gap - 0.01, 0.55 + h / 2), xytext=(x + w + 0.01, 0.55 + h / 2),
                    arrowprops=dict(arrowstyle='-|>', color=DARK, lw=0.9, mutation_scale=8))
ax.text(4.2, 0.18, 'all numbers from the ROT-NOM run shown in this deck', ha='center', fontsize=7.5, color=GREY)
save(fig, 'F01_overview')
