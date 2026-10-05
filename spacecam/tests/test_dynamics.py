import numpy as np
import pytest
from scipy.spatial.transform import Rotation

from spacecam.config import MotionConfig, SimulationConfig
from spacecam.dynamics import propagate, read_velocity_csv


def test_constant_translation_and_principal_axis_rotation():
    c = SimulationConfig(
        duration=0.25,
        fps=20,
        motion=MotionConfig(
            position=[1, 2, 10], velocity=[2, -1, 0.5], attitude_deg=[0, 0, 0], angular_rate_deg=[0, 0, 90]
        ),
    )
    result = propagate(c)
    np.testing.assert_allclose(
        result.position, np.array(c.motion.position) + result.t[:, None] * c.motion.velocity
    )
    np.testing.assert_allclose(
        result.quaternion[-1], [np.cos(np.pi / 16), 0, 0, np.sin(np.pi / 16)], atol=1e-9
    )
    assert result.t[-1] == c.duration
    assert np.all(np.diff(result.t) > 0)


def test_torque_free_conserves_energy_and_inertial_momentum():
    c = SimulationConfig(
        duration=2, fps=30, motion=MotionConfig(angular_rate_deg=[30, 70, 110], inertia=[2, 3, 4])
    )
    result = propagate(c)
    energy = 0.5 * np.sum(result.omega**2 * c.motion.inertia, axis=1)
    np.testing.assert_allclose(energy, energy[0], rtol=1e-8)
    rotations = Rotation.from_quat(result.quaternion[:, [1, 2, 3, 0]])
    momentum = rotations.apply(result.omega * c.motion.inertia)
    np.testing.assert_allclose(momentum, np.tile(momentum[0], (len(momentum), 1)), atol=1e-8)
    np.testing.assert_allclose(np.linalg.norm(result.quaternion, axis=1), 1, atol=1e-12)


def test_circular_central_gravity_orbit():
    radius = 7e6
    mu = 3.986004418e14
    speed = np.sqrt(mu / radius)
    c = SimulationConfig(
        duration=10,
        fps=1,
        motion=MotionConfig(
            position=[radius, 0, 0],
            velocity=[0, speed, 0],
            translation="gravity",
            gravity_center=[0, 0, 0],
            angular_rate_deg=[0, 0, 0],
            integration_step=0.2,
        ),
    )
    result = propagate(c)
    angle = speed / radius * result.t
    np.testing.assert_allclose(result.position[:, 0], radius * np.cos(angle), atol=1e-5)
    np.testing.assert_allclose(result.position[:, 1], radius * np.sin(angle), atol=1e-5)


def test_csv_integrates_velocity_and_prescribed_body_rates(tmp_path):
    path = tmp_path / "states.csv"
    path.write_text("t,vx,vy,vz,wx,wy,wz,x,y,z\n0,0,0,0,0,0,1,2,3,10\n1,2,0,0,0,0,1,,,\n2,0,0,0,0,0,1,,,\n")
    c = SimulationConfig(duration=2, fps=10, motion=MotionConfig(csv_path=str(path), attitude_deg=[0, 0, 0]))
    result = propagate(c)
    np.testing.assert_allclose(result.position[-1], [4, 3, 10], atol=1e-7)
    np.testing.assert_allclose(result.quaternion[-1], [np.cos(1), 0, 0, np.sin(1)], atol=1e-8)
    np.testing.assert_allclose(result.omega, np.tile([0, 0, 1], (len(result.t), 1)))


@pytest.mark.parametrize(
    "body",
    [
        "t,vx,vy,vz\n0,0,0,0\n0,0,0,0\n",
        "t,vx,vy,vz\n0,0,0,0\n1,0,0,0\n3,0,0,0\n",
        "t,vx,vy,vz\n0,nan,0,0\n1,0,0,0\n",
        "t,vx,vy,vz,wx\n0,0,0,0,1\n1,0,0,0,1\n",
    ],
)
def test_invalid_csv_rejected(tmp_path, body):
    path = tmp_path / "bad.csv"
    path.write_text(body)
    with pytest.raises(ValueError):
        read_velocity_csv(path, 1)


def test_csv_must_cover_duration(tmp_path):
    path = tmp_path / "short.csv"
    path.write_text("t,vx,vy,vz\n0,0,0,0\n1,0,0,0\n")
    with pytest.raises(ValueError, match="before"):
        read_velocity_csv(path, 2)


@pytest.mark.parametrize(
    "change",
    [{"duration": float("nan")}, {"fps": 0}, {"width": 0}, {"threshold_pos": -1}, {"refractory_s": -1}],
)
def test_invalid_config(change):
    with pytest.raises(ValueError):
        SimulationConfig(**change).validate()


def test_cancellation():
    with pytest.raises(InterruptedError):
        propagate(SimulationConfig(), lambda: True)
