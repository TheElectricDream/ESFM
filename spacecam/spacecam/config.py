"""Serializable simulation settings; distances in metres and times in seconds."""

import math
from dataclasses import asdict, dataclass, field
from pathlib import Path


@dataclass
class MotionConfig:
    position: list[float] = field(default_factory=lambda: [0.0, 0.0, 12.0])
    velocity: list[float] = field(default_factory=lambda: [0.25, 0.0, 0.0])
    attitude_deg: list[float] = field(default_factory=lambda: [15.0, 20.0, 0.0])
    angular_rate_deg: list[float] = field(default_factory=lambda: [0.0, 10.0, 5.0])
    inertia: list[float] = field(default_factory=lambda: [1.0, 1.5, 2.0])
    translation: str = "free"
    mu: float = 3.986004418e14
    gravity_center: list[float] = field(default_factory=lambda: [0.0, 0.0, -7000000.0])
    csv_path: str = ""
    integration_step: float = 0.005


@dataclass
class SimulationConfig:
    model_path: str = ""  # empty selects the built-in spacecraft
    model_scale: float = 1.0
    duration: float = 1.0
    fps: float = 120.0
    width: int = 320
    height: int = 240
    fov_deg: float = 45.0
    threshold_pos: float = 0.2
    threshold_neg: float = 0.2
    refractory_s: float = 0.0001
    log_epsilon: float = 0.001
    backend: str = "numpy"
    blender: str = "blender"
    samples: int = 16
    max_events: int = 5_000_000
    motion: MotionConfig = field(default_factory=MotionConfig)

    def to_dict(self):
        return asdict(self)

    @classmethod
    def from_dict(cls, data):
        data = dict(data)
        data["motion"] = MotionConfig(**data.get("motion", {}))
        return cls(**data)

    def validate(self):
        for name in ("model_scale", "duration", "fps", "threshold_pos", "threshold_neg", "log_epsilon"):
            value = getattr(self, name)
            if not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be finite and positive.")
        if not math.isfinite(self.refractory_s) or self.refractory_s < 0:
            raise ValueError("Refractory period must be finite and nonnegative.")
        if not math.isfinite(self.fov_deg) or not 1 <= self.fov_deg <= 160:
            raise ValueError("Horizontal field of view must be between 1 and 160 degrees.")
        for name, lo, hi in (
            ("width", 16, 4096),
            ("height", 16, 4096),
            ("samples", 1, 1024),
            ("max_events", 1, 100_000_000),
        ):
            value = getattr(self, name)
            if not isinstance(value, int) or not lo <= value <= hi:
                raise ValueError(f"{name} must be an integer between {lo} and {hi}.")
        if self.duration * self.fps > 10000:
            raise ValueError(
                "Prototype limit: 10,000 frame intervals per run; reduce duration or render rate."
            )
        if self.backend not in ("numpy", "esim"):
            raise ValueError("Choose numpy or esim event backend.")
        if self.model_path and not Path(self.model_path).is_file():
            raise ValueError("The selected model no longer exists.")
        m = self.motion
        for name in ("position", "velocity", "attitude_deg", "angular_rate_deg", "inertia", "gravity_center"):
            values = getattr(m, name)
            if len(values) != 3 or not all(math.isfinite(x) for x in values):
                raise ValueError(f"{name} must contain three finite values.")
        if min(m.inertia) <= 0 or 2 * max(m.inertia) > sum(m.inertia) + 1e-12:
            raise ValueError("Principal inertias must be positive and satisfy the triangle inequality.")
        if m.translation not in ("free", "gravity"):
            raise ValueError("Translation must be free or gravity.")
        if not math.isfinite(m.integration_step) or not 0.00001 <= m.integration_step <= 1:
            raise ValueError("Integration step must be between 0.00001 and 1 second.")
        if self.duration / m.integration_step > 2_000_000:
            raise ValueError("Too many dynamics steps; increase integration step or reduce duration.")
        if not math.isfinite(m.mu) or m.mu <= 0:
            raise ValueError("Gravitational parameter must be positive and finite.")
        if m.translation == "gravity" and sum((a - b) ** 2 for a, b in zip(m.position, m.gravity_center)) < 1:
            raise ValueError("Initial position must be at least 1 m from the gravity center.")
        if m.csv_path and not Path(m.csv_path).is_file():
            raise ValueError("Trajectory CSV does not exist.")
