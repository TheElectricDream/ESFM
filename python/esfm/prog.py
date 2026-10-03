"""+prog: progressive (streaming) map building, one 0.1 s slice at a time."""
import numpy as np
from scipy.spatial import cKDTree
from . import geom, traj, adjust
from .track import _ball


def create_map(tr, X, O):
    N = X.shape[0]
    nobs = np.bincount(O[:, 1].astype(int), minlength=N).astype(float)
    assert np.all(nobs > 0)
    nrm = np.zeros((N, 2))
    ids = O[:, 1].astype(int)
    order = np.lexsort((O[:, 0], ids))          # by id, then time
    last = np.r_[ids[order][1:] != ids[order][:-1], True]
    nrm[ids[order][last]] = O[order][last, 4:6]
    return dict(traj=tr, X=X.copy(), O=O.copy(), nobs=nobs, nrm=nrm, cand=[],
                knots_free=False, created_s=np.full(N, np.nan), alive=np.ones(N, bool), ratio=[])


def crossed(t_prev, t_now, period, origin):
    return np.floor((t_now - origin) / period) > np.floor((t_prev - origin) / period)


def slice_events(t, accept, centers, dt):
    acc = np.flatnonzero(accept)
    edges = np.r_[centers - dt / 2, centers[-1] + dt / 2]
    at = t[acc]
    prefix = np.count_nonzero(at < edges[0])
    counts, _ = np.histogram(at[at < edges[-1]], edges)
    last = prefix + np.cumsum(counts)          # exclusive end
    first = last - counts
    return acc, first, last


def warp_events(slc, tc):
    dt = slc['t'] - tc
    W = np.c_[slc['x'] - slc['flow'][:, 0] * dt, slc['y'] - slc['flow'][:, 1] * dt]
    return W, geom.unit_rows(slc['flow']) if len(dt) else np.zeros((0, 2))


def predict(m, tc, cam, cfg):
    ids = np.flatnonzero(m['alive'])
    X = m['X'][ids]
    R, T = traj.pose(m['traj'], tc)
    n = len(ids)
    uv, Y = geom.project(np.repeat(R, n, 0), np.repeat(T, n, 0), X, cam)
    h = cfg.prog.flow_half_step_s
    Rp, Tp = traj.pose(m['traj'], tc + h)
    Rm, Tm = traj.pose(m['traj'], tc - h)
    up, _ = geom.project(np.repeat(Rp, n, 0), np.repeat(Tp, n, 0), X, cam)
    um, _ = geom.project(np.repeat(Rm, n, 0), np.repeat(Tm, n, 0), X, cam)
    mg, sz = cfg.prog.image_margin_px, cam.image_size
    inside = ((Y[:, 2] > cfg.adjust.min_depth) & (uv[:, 0] > -mg) & (uv[:, 0] < sz[0] + mg)
              & (uv[:, 1] > -mg) & (uv[:, 1] < sz[1] + mg))
    return dict(ids=ids, uv=uv, Y=Y, flow=(up - um) / (2 * h), inside=inside)


def find_ambiguous(pred, nrm, cfg):
    L = len(pred['ids'])
    amb = np.zeros(L, bool)
    vis = np.flatnonzero(pred['inside'])
    if vis.size < 2:
        return amb
    pairs = cKDTree(pred['uv'][vis]).query_pairs(cfg.prog.gate_tangent_px, output_type='ndarray')
    if len(pairs) == 0:
        return amb
    k, l = vis[pairs[:, 0]], vis[pairs[:, 1]]
    nk = nrm[k]
    uv, fl = pred['uv'], pred['flow']
    same_line = np.abs(np.sum((uv[l] - uv[k]) * nk, 1)) < cfg.prog.gate_normal_px
    same_or = np.abs(np.sum(nk * nrm[l], 1)) > cfg.prog.min_normal_cos
    same_mo = np.sum(nk * fl[k], 1) * np.sum(nk * fl[l], 1) > 0
    hit = same_line & same_or & same_mo
    amb[k[hit]] = True
    amb[l[hit]] = True
    return amb


def associate(pred, W, D, slc, nrm, nobs, amb, cfg, keep_detail=False):
    L, E = len(pred['ids']), W.shape[0]
    rows, ks, mature, ratio = [], [], [], []
    used = np.zeros(E, bool)
    found = np.zeros(L, bool)
    detail = [] if keep_detail else None
    if E > 0:
        nbrs = _ball(W, pred['uv'], cfg.prog.gate_tangent_px)
        for k in np.argsort(-nobs, kind='stable'):
            if not pred['inside'][k]:
                continue
            cand = nbrs[k]
            cand = cand[~used[cand]]
            if cand.size < cfg.prog.min_claim_events:
                continue
            pe = W[cand] - pred['uv'][k]
            d = D[cand]
            ne = np.sum(pe * d, 1)
            te = pe[:, 0] * d[:, 1] - pe[:, 1] * d[:, 0]
            ok = ((np.abs(ne) < cfg.prog.gate_normal_px) & (np.abs(te) < cfg.prog.gate_tangent_px)
                  & (d @ pred['flow'][k] > 0) & (np.abs(d @ nrm[k]) > cfg.prog.min_normal_cos))
            if keep_detail:
                detail.append(dict(k=k, cand=cand, ok=ok))
            if ok.sum() < cfg.prog.min_claim_events:
                continue
            c = cand[ok]
            used[c] = True
            nm = geom.unit_rows(slc['flow'][c].mean(0))[0]
            rows.append([slc['t'][c].mean(), pred['ids'][k], slc['x'][c].mean(), slc['y'][c].mean(), nm[0], nm[1]])
            ks.append(k)
            mature.append(not amb[k])
            if mature[-1]:
                ratio.append(np.mean(d[ok] @ pred['flow'][k]) / np.mean(np.linalg.norm(slc['flow'][c], axis=1)))
    found[ks] = True
    out = dict(rows=np.array(rows).reshape(-1, 6), k=np.array(ks, int), mature=np.array(mature, bool),
               ratio=np.array(ratio), used=used, found=found)
    if keep_detail:
        out['detail'] = detail
    return out


def correct_motion(m, new_rows, tc, cam, cfg):
    w = cfg.prog.local_window_s
    recent = np.r_[m['O'][m['O'][:, 0] > tc - w], new_rows]
    free = traj.select_free_parameters(m['traj'], False, tc, tc - w, cfg.warm.free_mean_velocity)
    tr, _, info = adjust.refine(m['traj'], m['X'], recent, free, [], cfg.prog.correction_iterations, cam, cfg.adjust)
    return tr, info


def commit_observations(m, rows):
    if len(rows) == 0:
        return m
    m['O'] = np.r_[m['O'], rows]
    ids = np.unique(rows[:, 1].astype(int))
    m['nobs'][ids] += 1
    return m


def update_candidates(cand, W, slc, available, tc, cfg):
    E = W.shape[0]
    taken = np.zeros(E, bool)
    if not cand:
        return cand, taken
    max_miss = round(cfg.prog.cand_max_gap_s / cfg.data.slice_s)
    dtp = tc - np.array([c['t'] for c in cand])
    px = np.array([c['x'] for c in cand]) + np.array([c['vx'] for c in cand]) * dtp
    py = np.array([c['y'] for c in cand]) + np.array([c['vy'] for c in cand]) * dtp
    pool = np.flatnonzero(available)
    near = _ball(W[pool], np.c_[px, py], cfg.prog.cand_gate_px)
    keep = np.ones(len(cand), bool)
    for i, c in enumerate(cand):
        ids = pool[near[i]] if pool.size else np.zeros(0, int)
        ids = ids[~taken[ids]]
        if ids.size >= cfg.prog.cand_min_events:
            taken[ids] = True
            rx = W[ids, 0].mean() - px[i]
            ry = W[ids, 1].mean() - py[i]
            c['vx'] += cfg.prog.cand_vel_gain * rx / dtp[i]
            c['vy'] += cfg.prog.cand_vel_gain * ry / dtp[i]
            c['x'] = px[i] + cfg.prog.cand_pos_gain * rx
            c['y'] = py[i] + cfg.prog.cand_pos_gain * ry
            c['t'] = tc
            n = geom.unit_rows(slc['flow'][ids].mean(0))[0]
            c['hist'].append([tc, c['x'], c['y'], n[0], n[1]])
            c['miss'] = 0
        else:
            c['miss'] += 1
        keep[i] = c['miss'] <= max_miss
    return [c for c, k in zip(cand, keep) if k], taken


def promote_candidates(m, tc, cam, cfg):
    promo = dict(attempted=0, promoted=0, fail_depth=0, fail_rms=0, new_ids=[])
    if not m['cand']:
        return m, promo
    mature = np.zeros(len(m['cand']), bool)
    for i, c in enumerate(m['cand']):
        h = c['hist']
        if len(h) >= cfg.prog.cand_min_samples:
            turn = abs(traj.angle(m['traj'], h[-1][0])[0] - traj.angle(m['traj'], h[0][0])[0])
            mature[i] = turn >= np.deg2rad(cfg.prog.cand_min_turn_deg)
    for i in np.flatnonzero(mature):
        h = np.array(m['cand'][i]['hist'])
        S = h.shape[0]
        promo['attempted'] += 1
        R, T = traj.pose(m['traj'], h[:, 0])
        X = geom.triangulate(R, T, np.zeros(S, int), h[:, 1:3], h[:, 3:5], 1, cfg.adjust.tangent_weight, cam)
        pr, Y = geom.project(R, T, np.repeat(X, S, 0), cam)
        rms = np.sqrt(np.mean(np.sum((h[:, 1:3] - pr) * h[:, 3:5], 1) ** 2))
        okd = Y[:, 2].min() > cfg.prog.cand_min_depth
        okr = rms < cfg.prog.cand_max_rms_px
        promo['fail_depth'] += int(not okd)
        promo['fail_rms'] += int(not okr)
        if okd and okr:
            nid = m['X'].shape[0]
            m['X'] = np.r_[m['X'], X]
            m['O'] = np.r_[m['O'], np.c_[h[:, 0], np.full(S, nid), h[:, 1:5]]]
            m['nobs'] = np.r_[m['nobs'], S]
            m['nrm'] = np.r_[m['nrm'], h[-1:, 3:5]]
            m['created_s'] = np.r_[m['created_s'], tc]
            m['alive'] = np.r_[m['alive'], True]
            promo['promoted'] += 1
            promo['new_ids'].append(nid)
    m['cand'] = [c for c, mt in zip(m['cand'], mature) if not mt]
    return m, promo


def seed_candidates(cand, W, slc, available, tc, cfg):
    pool = np.flatnonzero(available)
    if pool.size == 0:
        return cand
    cells = np.floor(W[pool] / cfg.prog.seed_cell_px)
    _, g, count = np.unique(cells, axis=0, return_inverse=True, return_counts=True)
    g = g.ravel()
    for j in np.flatnonzero(count >= cfg.prog.cand_min_events):
        ids = pool[g == j]
        x, y = W[ids, 0].mean(), W[ids, 1].mean()
        v = slc['flow'][ids].mean(0)
        n = geom.unit_rows(v)[0]
        cand.append(dict(x=x, y=y, vx=v[0], vy=v[1], t=tc, hist=[[tc, x, y, n[0], n[1]]], miss=0))
    return cand


def step(m, slc, tc, cfg, cam, keep_detail=False):
    info = dict(explained=np.nan, matched=0, corrected=False, correction_steps=0, n_new=0)
    W, D = warp_events(slc, tc)
    detail = {}
    for pas in (1, 2):
        pred = predict(m, tc, cam, cfg)
        nrm_k = m['nrm'][pred['ids']]
        amb = find_ambiguous(pred, nrm_k, cfg)
        claims = associate(pred, W, D, slc, nrm_k, m['nobs'][pred['ids']], amb, cfg, keep_detail)
        if keep_detail:
            detail[f'pass{pas}'] = dict(pred=pred, amb=amb, claims=claims, traj=traj.copy_traj(m['traj']))
        if len(claims['rows']):
            m['nrm'][claims['rows'][:, 1].astype(int)] = claims['rows'][:, 4:6]
        if pas == 1 and m['knots_free']:
            m['traj'], corr = correct_motion(m, claims['rows'], tc, cam, cfg)
            info['corrected'] = True
            info['correction_steps'] = corr['accepted_steps']
        else:
            break
    m = commit_observations(m, claims['rows'])
    if len(claims['ratio']):
        m['ratio'].append(np.median(claims['ratio']))
    info['explained'] = claims['used'].mean() if len(claims['used']) else np.nan
    info['matched'] = int(claims['found'].sum())
    available = ~claims['used']
    m['cand'], taken = update_candidates(m['cand'], W, slc, available, tc, cfg)
    m, promo = promote_candidates(m, tc, cam, cfg)
    info['n_new'] = promo['promoted']
    info['promo'] = promo
    m['cand'] = seed_candidates(m['cand'], W, slc, available & ~taken, tc, cfg)
    info['n_cand'] = len(m['cand'])
    if keep_detail:
        detail.update(W=W, D=D, used=claims['used'], taken=taken, available=available)
        info['detail'] = detail
    return m, info


def local_adjust(m, tc, cam, cfg):
    w = cfg.prog.local_window_s
    in_win = m['O'][:, 0] > tc - w
    pts = np.unique(m['O'][in_win, 1].astype(int))
    rows = in_win | np.isin(m['O'][:, 1].astype(int), pts)
    free = traj.select_free_parameters(m['traj'], False, tc, tc - w, cfg.warm.free_mean_velocity)
    m['traj'], m['X'], info = adjust.refine(m['traj'], m['X'], m['O'][rows], free, pts,
                                            cfg.prog.local_iterations, cam, cfg.adjust)
    return m, info


def global_adjust(m, tc, cam, cfg):
    pts = np.flatnonzero(m['alive'])
    rows = np.isin(m['O'][:, 1].astype(int), pts)
    free = traj.select_free_parameters(m['traj'], True, tc if m['knots_free'] else None, None,
                                       cfg.warm.free_mean_velocity)
    m['traj'], m['X'], info = adjust.refine(m['traj'], m['X'], m['O'][rows], free, pts,
                                            cfg.prog.global_iterations, cam, cfg.adjust)
    return m, info


def final_refinement(m, end_time_s, cam, cfg):
    tr, X, N = m['traj'], m['X'], m['X'].shape[0]
    free = traj.select_free_parameters(tr, True, end_time_s, None, cfg.warm.free_mean_velocity)
    keep = np.flatnonzero(m['nobs'] >= cfg.final.min_obs)
    O = m['O'][np.isin(m['O'][:, 1].astype(int), keep)]
    tr, X, i1 = adjust.refine(tr, X, O, free, keep, cfg.final.iterations[0], cam, cfg.adjust)
    dn = adjust.normal_residuals(tr, X, O, cam)
    ids = O[:, 1].astype(int)
    prms = np.sqrt(np.bincount(ids, dn ** 2, N) / np.maximum(np.bincount(ids, minlength=N), 1))
    dropped = keep[prms[keep] >= cfg.final.max_point_rms_px]
    keep = keep[prms[keep] < cfg.final.max_point_rms_px]
    O = O[np.isin(O[:, 1].astype(int), keep)]
    tr, X, i2 = adjust.refine(tr, X, O, free, keep, cfg.final.iterations[1], cam, cfg.adjust)
    dn = adjust.normal_residuals(tr, X, O, cam)
    ids = O[:, 1].astype(int)
    first = np.full(N, np.inf); np.minimum.at(first, ids, O[:, 0])
    last = np.full(N, -np.inf); np.maximum.at(last, ids, O[:, 0])
    period = 2 * np.pi / abs(tr['omega'])
    revisit = (last[keep] - first[keep]) > cfg.final.revisit_fraction * period
    return dict(traj=tr, X=X, keep=keep, O=O, dn=dn, revisit=revisit, info=[i1, i2],
                point_rms_pass1=prms, dropped=dropped)


def calibrate_scale(X, ocfg):
    _, _, Vt = np.linalg.svd(X - X.mean(0), full_matrices=False)
    p = np.sort(X @ Vt[0])
    n = p.size
    e = np.interp((n - 1) * np.array([0.01, 0.99]), np.arange(n), p)
    span = e[1] - e[0]
    return dict(known_width_m=ocfg.known_width_m, span_model=span, m_per_unit=ocfg.known_width_m / span,
                method='provisional 1-99 percentile principal-axis span', provisional=True)
