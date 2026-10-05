"""6DOF propagation: inertial translation and torque-free Euler rigid-body equations."""

import csv
from dataclasses import dataclass

import numpy as np
from scipy.integrate import solve_ivp
from scipy.spatial.transform import Rotation

from .config import SimulationConfig


@dataclass
class Trajectory:
    t: np.ndarray
    position: np.ndarray
    velocity: np.ndarray
    quaternion: np.ndarray  # body-to-world, w x y z
    omega: np.ndarray  # body-frame rad/s

    def save(self, path):
        np.savetxt(
            path,
            np.column_stack((self.t, self.position, self.velocity, self.quaternion, self.omega)),
            delimiter=",",
            comments="",
            header="t,x,y,z,vx,vy,vz,qw,qx,qy,qz,wx,wy,wz",
        )


def read_velocity_csv(path, duration):
    """Fixed-step velocity knots, linearly interpolated; optional prescribed body rates."""
    with open(path, newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        fields = set(reader.fieldnames or [])
        if not {"t", "vx", "vy", "vz"} <= fields:
            raise ValueError("CSV requires t,vx,vy,vz headers (seconds and m/s).")
        rows = list(reader)
    if len(rows) < 2:
        raise ValueError("CSV needs at least two velocity samples.")
    has_rates = bool(fields & {"wx", "wy", "wz"})
    if has_rates and not {"wx", "wy", "wz"} <= fields:
        raise ValueError("CSV angular rates require all of wx,wy,wz (rad/s).")
    if fields & {"x", "y", "z"} and not {"x", "y", "z"} <= fields:
        raise ValueError("Initial CSV position requires all of x,y,z.")
    try:
        keys = ["t", "vx", "vy", "vz"] + (["wx", "wy", "wz"] if has_rates else [])
        data = np.array([[float(row[key]) for key in keys] for row in rows])
        p0 = np.array([float(rows[0][k]) for k in ("x", "y", "z")]) if "x" in fields else None
    except (ValueError, TypeError, KeyError) as exc:
        raise ValueError(
            "CSV has missing or nonnumeric values. Position is required only in its first row."
        ) from exc
    if not np.isfinite(data).all() or (p0 is not None and not np.isfinite(p0).all()):
        raise ValueError("CSV values must be finite.")
    t = data[:, 0]
    dt = np.diff(t)
    if abs(t[0]) > 1e-9 or np.any(dt <= 0) or not np.allclose(dt, dt[0], rtol=1e-5, atol=1e-9):
        raise ValueError("CSV timestamps must start at zero and increase at fixed time steps.")
    if t[-1] < duration - 1e-9:
        raise ValueError(f"CSV ends at {t[-1]:g} s, before the requested {duration:g} s duration.")
    return t, data[:, 1:4], data[:, 4:] if has_rates else None, p0


def quaternion_derivative(q, omega):
    w, xyz = q[0], q[1:]
    return 0.5 * np.r_[-np.dot(xyz, omega), w * omega + np.cross(xyz, omega)]


def propagate(config: SimulationConfig, cancelled=lambda: False):
    config.validate()
    m = config.motion
    count = int(np.floor(config.duration * config.fps))
    times = np.arange(count + 1, dtype=float) / config.fps
    if count == 0 or config.duration - times[-1] > 1e-10:
        times = np.r_[times, config.duration]
    else:
        times[-1] = config.duration
    inertia = np.asarray(m.inertia)
    # scipy's lowercase xyz convention: extrinsic roll, pitch, yaw.
    q_xyzw = Rotation.from_euler("xyz", m.attitude_deg, degrees=True).as_quat()
    q0 = q_xyzw[[3, 0, 1, 2]]
    csv_data = read_velocity_csv(m.csv_path, config.duration) if m.csv_path else None
    p0 = csv_data[3] if csv_data is not None and csv_data[3] is not None else m.position
    y0 = np.r_[p0, m.velocity, q0, np.deg2rad(m.angular_rate_deg)]

    def derivative(t, y):
        if cancelled():
            raise InterruptedError("Simulation cancelled.")
        p, v, q, omega = y[:3], y[3:6], y[6:10], y[10:13]
        acceleration = np.zeros(3)
        if csv_data is not None:
            knots, velocities, rates, _ = csv_data
            v = np.array([np.interp(t, knots, velocities[:, k]) for k in range(3)])
            if rates is not None:
                omega = np.array([np.interp(t, knots, rates[:, k]) for k in range(3)])
        elif m.translation == "gravity":
            r = p - m.gravity_center
            radius = np.linalg.norm(r)
            if radius < 1:
                raise ValueError("Trajectory reached the gravity-center singularity.")
            acceleration = -m.mu * r / radius**3
        angular_acceleration = -np.cross(omega, inertia * omega) / inertia
        if csv_data is not None and csv_data[2] is not None:
            angular_acceleration = np.zeros(3)
        return np.r_[v, acceleration, quaternion_derivative(q, omega), angular_acceleration]

    solution = solve_ivp(
        derivative, (0, config.duration), y0, t_eval=times, rtol=1e-9, atol=1e-11, max_step=m.integration_step
    )
    if not solution.success:
        raise ValueError(f"Dynamics integration failed: {solution.message}")
    states = solution.y.T
    quats = states[:, 6:10]
    quats /= np.linalg.norm(quats, axis=1, keepdims=True)
    velocities, omega = states[:, 3:6], states[:, 10:13]
    if csv_data is not None:
        knots, vs, rates, _ = csv_data
        velocities = np.column_stack([np.interp(times, knots, vs[:, k]) for k in range(3)])
        if rates is not None:
            omega = np.column_stack([np.interp(times, knots, rates[:, k]) for k in range(3)])
    return Trajectory(times, states[:, :3], velocities, quats, omega)
