"""config.m + derived_parameters.m as nested namespaces."""
from types import SimpleNamespace as NS
import os

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def config(hdf5_path=None, start_time_s=60.0, end_time_s=185.0):
    cfg = NS()
    cfg.data = NS(hdf5_path=hdf5_path, start_time_s=start_time_s, end_time_s=end_time_s)
    cfg.camera = NS(calibration_xml=os.path.join(
        REPO, 'calibration_camera_DVXplorerM_DXUS0047-2026_07_27_11_26_49-fisheye.xml'))
    cfg.output = NS(known_width_m=1.27, scale_endpoint_ids=[])
    cfg.surface = NS(cell_s=0.8)
    cfg.warm = NS(duration_s=6.0, rate_seeds_deg_s=[2, 4, 6, 8, 10])
    cfg.traj = NS(knot_spacing_s=1.0)
    return derived_parameters(cfg)


def derived_parameters(cfg):
    MIN_EVENTS, GATE_PX, MAX_RMS_PX, MIN_OBS, MAX_GAP_S, LM_ITERS = 3, 3.0, 2.0, 20, 1.5, 10

    cfg.data.slice_s = 0.1

    s = cfg.surface
    s.cell_px = 8
    s.sigma_s = s.cell_s * 0.0375
    s.min_events_per_cell = 15
    s.min_time_normal = 0.05
    s.max_planarity_ratio = 0.45
    s.min_warped_support = MIN_EVENTS
    s.split_polarities = True
    s.two_offset_grids = True

    gp = 0.6
    cfg.track = NS(gate_px=GATE_PX, seed_cell_px=2 * GATE_PX, min_events=MIN_EVENTS,
                   gain_position=gp, gain_velocity=gp ** 2 / (2 - gp),
                   max_miss=round(MAX_GAP_S / cfg.data.slice_s), min_length=MIN_OBS)

    cfg.adjust = NS(tangent_weight=0.15, cauchy_px=4.0, min_depth=0.2, depth_weight=50,
                    lambda_rotation=250, lambda_translation=100, pull_fraction=0.1,
                    gauge_weight=5e3, centroid_weight=50, damping0=1e-3, damping_down=3,
                    damping_up=4, max_attempts=6, step_tol=1e-8)

    w = cfg.warm
    w.cauchy_px = cfg.adjust.cauchy_px
    w.min_depth = cfg.adjust.min_depth
    w.tangent_weight = cfg.adjust.tangent_weight
    w.free_mean_velocity = False
    w.max_velocity_per_s = 0.2
    w.max_centre_offset = 1.0
    w.hemisphere_directions = 13
    w.base_axis = [0, -1, 0]
    w.max_function_evals = 600
    w.adjust_iterations = LM_ITERS

    h = cfg.traj.knot_spacing_s
    cfg.prog = NS(local_every_s=h, local_window_s=3 * h, global_growth=1.25,
                  flow_half_step_s=cfg.data.slice_s / 2, gate_normal_px=GATE_PX,
                  gate_tangent_px=s.cell_px, image_margin_px=s.cell_px,
                  min_normal_cos=0.5, min_claim_events=MIN_EVENTS,
                  correction_iterations=3, local_iterations=LM_ITERS,
                  global_iterations=LM_ITERS, cand_gate_px=GATE_PX,
                  cand_max_gap_s=MAX_GAP_S, cand_min_events=MIN_EVENTS,
                  seed_cell_px=2 * GATE_PX, cand_pos_gain=gp,
                  cand_vel_gain=gp ** 2 / (2 - gp), cand_min_samples=12,
                  cand_min_turn_deg=8.0, cand_min_depth=cfg.adjust.min_depth,
                  cand_max_rms_px=MAX_RMS_PX)

    cfg.final = NS(min_obs=MIN_OBS, iterations=[LM_ITERS, LM_ITERS],
                   max_point_rms_px=MAX_RMS_PX, revisit_fraction=0.8)
    return cfg
