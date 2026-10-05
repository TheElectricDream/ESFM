"""Qt desktop workbench. Start with `python -m spacecam`."""

import importlib.util
import json
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import numpy as np
from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg
from matplotlib.figure import Figure
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from PySide6.QtCore import QProcess, QSettings, Qt, QTimer
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QSlider,
    QSpinBox,
    QSplitter,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)
from scipy.spatial.transform import Rotation

from .config import MotionConfig, SimulationConfig
from .dynamics import read_velocity_csv
from .events import event_image, export_csv, export_hdf5
from .models import SUPPORTED, load_model
from .paths import PROJECT_ROOT, RUN_ROOT
from .pipeline import read_result


def button(text, callback):
    widget = QPushButton(text)
    widget.clicked.connect(callback)
    return widget


def number(value, low=-1e9, high=1e9, decimals=4, step=0.1):
    widget = QDoubleSpinBox()
    widget.setRange(low, high)
    widget.setDecimals(decimals)
    widget.setSingleStep(step)
    widget.setValue(value)
    widget.setKeyboardTracking(False)
    return widget


class VectorInput(QWidget):
    def __init__(self, values, low=-1e9, high=1e9):
        super().__init__()
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        self.fields = [number(value, low, high) for value in values]
        for label, field in zip("XYZ", self.fields):
            field.setPrefix(label + " ")
            field.setMinimumWidth(65)
            field.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
            row.addWidget(field)

    def values(self):
        return [field.value() for field in self.fields]

    def set_values(self, values):
        for field, value in zip(self.fields, values):
            field.setValue(value)


class PlotCanvas(FigureCanvasQTAgg):
    def __init__(self, projection=None):
        figure = Figure(figsize=(4, 3), facecolor="#101722", layout="constrained")
        super().__init__(figure)
        self.axes = figure.add_subplot(111, projection=projection)
        self.style()

    def style(self):
        self.axes.set_facecolor("#101722")
        self.axes.tick_params(colors="#a9bdd1", labelsize=8)
        for axis in (self.axes.xaxis, self.axes.yaxis):
            axis.label.set_color("#a9bdd1")
        if hasattr(self.axes, "zaxis"):
            self.axes.zaxis.label.set_color("#a9bdd1")
            for axis in (self.axes.xaxis, self.axes.yaxis, self.axes.zaxis):
                axis.set_pane_color((0.09, 0.13, 0.18, 1))
        self.axes.title.set_color("#e7eff6")


class ImagePane(QLabel):
    def __init__(self, text):
        super().__init__(text)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMinimumSize(180, 140)
        self.setStyleSheet("background: #0f1622; border: 1px solid #2c3e50; border-radius: 6px;")
        self.source = QPixmap()

    def set_source(self, source):
        if isinstance(source, np.ndarray):
            data = np.ascontiguousarray(source, dtype=np.uint8)
            image = QImage(
                data.data, data.shape[1], data.shape[0], data.strides[0], QImage.Format.Format_RGB888
            )
            self.source = QPixmap.fromImage(image.copy())
        else:
            self.source = QPixmap(str(source))
        self.fit_image()

    def fit_image(self):
        if not self.source.isNull():
            self.setPixmap(
                self.source.scaled(
                    self.size(),
                    Qt.AspectRatioMode.KeepAspectRatio,
                    Qt.TransformationMode.SmoothTransformation,
                )
            )

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.fit_image()


class SimulatorWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("ESFM · Spacecraft Event Camera Lab")
        self.resize(1550, 940)
        settings_path = PROJECT_ROOT / "settings.ini"
        self.settings = QSettings(str(settings_path), QSettings.Format.IniFormat)
        if not settings_path.exists():
            previous_settings = QSettings("ESFM", "Spacecam")
            for key in previous_settings.allKeys():
                self.settings.setValue(key, previous_settings.value(key))
        self.workspace = tempfile.TemporaryDirectory(prefix="spacecam-")
        self.run_root = RUN_ROOT
        self.result = None
        self.process = None
        self.run_dir = None
        self.close_pending = False
        self.mesh = None
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.advance_frame)
        root = QWidget()
        layout = QVBoxLayout(root)
        heading = QLabel("SPACECRAFT / EVENT CAMERA LAB")
        heading.setStyleSheet("font-size: 22px; font-weight: 700; color: #69d6ea; padding: 8px;")
        layout.addWidget(heading)
        caption = QLabel("Choose a spacecraft  →  set motion and sensor  →  render, inspect and export")
        layout.addWidget(caption)
        panes = QSplitter(Qt.Orientation.Horizontal)
        self.model_group = self.build_model_pane()
        self.control_scroll = self.build_controls()
        panes.addWidget(self.model_group)
        panes.addWidget(self.control_scroll)
        panes.addWidget(self.build_results())
        panes.setSizes([480, 460, 540])
        layout.addWidget(panes, 1)
        footer = QHBoxLayout()
        self.run_button = button("Run simulation", self.start_run)
        self.run_button.setStyleSheet("background: #187d90; font-weight: 700; padding: 10px 26px;")
        self.cancel_button = button("Cancel", self.cancel_run)
        self.cancel_button.setEnabled(False)
        self.progress = QProgressBar()
        self.progress.setRange(0, 1)
        self.progress.setValue(0)
        footer.addWidget(self.run_button)
        footer.addWidget(self.cancel_button)
        footer.addWidget(self.progress, 1)
        layout.addLayout(footer)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(1000)
        self.log.setMaximumHeight(105)
        layout.addWidget(self.log)
        self.setCentralWidget(root)
        self.restore_models()
        self.refresh_library()
        self.refresh_model()
        self.log.appendPlainText(
            "Ready. NumPy prototype is selected; choose UZH ESIM after installing esim_py."
        )

    def build_model_pane(self):
        group = QGroupBox("1 / Spacecraft & initial pose")
        layout = QVBoxLayout(group)
        self.models = QComboBox()
        self.models.addItem("Demo · spacecraft with solar panels", "")
        layout.addWidget(self.models)
        row = QHBoxLayout()
        row.addWidget(button("Add CAD…", self.add_model))
        row.addWidget(button("Add folder…", self.add_model_folder))
        row.addWidget(button("Refresh library", self.refresh_library))
        layout.addLayout(row)
        self.preview = PlotCanvas("3d")
        self.preview.setMinimumHeight(280)
        layout.addWidget(self.preview, 1)
        self.model_info = QLabel()
        self.model_info.setWordWrap(True)
        layout.addWidget(self.model_info)
        hint = QLabel(
            "Drag to orbit the inspection view. Use pose fields below to change the simulated object."
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)
        form = QFormLayout()
        self.scale = number(1, 0.000001, 1000000, 6)
        self.position = VectorInput([0, 0, 12])
        self.attitude = VectorInput([15, 20, 0], -360, 360)
        form.addRow("Metres / model unit", self.scale)
        form.addRow("Position (m)", self.position)
        form.addRow("Roll / pitch / yaw (°)", self.attitude)
        layout.addLayout(form)
        self.auto_range_button = button("Auto range", self.auto_range)
        self.auto_range_button.setToolTip(
            "Center the object and fit its initial pose in the camera frame with a 5% border. "
            "Apply again after changing scale, attitude, FOV or resolution."
        )
        layout.addWidget(self.auto_range_button)
        layout.addWidget(button("Reset pose", self.reset_pose))
        for field in self.attitude.fields:
            field.valueChanged.connect(self.update_preview)
        self.scale.valueChanged.connect(self.refresh_model)
        self.models.currentIndexChanged.connect(self.refresh_model)
        return group

    def build_controls(self):
        panel = QWidget()
        layout = QVBoxLayout(panel)
        motion = QGroupBox("2 / Motion · 6DOF")
        form = QFormLayout(motion)
        form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.WrapAllRows)
        self.motion_mode = QComboBox()
        self.motion_mode.addItems(["Initial state → dynamics", "CSV velocity history"])
        form.addRow("Input", self.motion_mode)
        self.csv_path = QLineEdit()
        self.csv_path.setPlaceholderText("t,vx,vy,vz · optional wx,wy,wz and initial x,y,z")
        csv_row = QWidget()
        csv_layout = QHBoxLayout(csv_row)
        csv_layout.setContentsMargins(0, 0, 0, 0)
        csv_layout.addWidget(self.csv_path)
        self.csv_button = button("…", self.choose_csv)
        csv_layout.addWidget(self.csv_button)
        form.addRow("CSV", csv_row)
        self.velocity = VectorInput([0.25, 0, 0])
        self.omega = VectorInput([0, 10, 5], -100000, 100000)
        self.inertia = VectorInput([1, 1.5, 2], 0.0001, 1e9)
        form.addRow("Velocity (m/s)", self.velocity)
        form.addRow("Initial body rate (°/s)", self.omega)
        form.addRow("Principal inertia (kg·m²)", self.inertia)
        self.translation = QComboBox()
        self.translation.addItem("Free drift", "free")
        self.translation.addItem("Central gravity", "gravity")
        self.gravity_center = VectorInput([0, 0, -7000000])
        self.mu = number(3.986004418e14, 0.001, 1e22, 3, 1e10)
        self.integration_step = number(0.005, 0.00001, 1, 5, 0.001)
        form.addRow("Translation", self.translation)
        form.addRow("Gravity center (m)", self.gravity_center)
        form.addRow("μ (m³/s²)", self.mu)
        form.addRow("Max dynamics step (s)", self.integration_step)
        note = QLabel(
            "Torque-free rotation about principal body axes. CSV rates, when present, prescribe rotation. "
            "Camera stays at the origin: X right, Y down, Z forward."
        )
        note.setWordWrap(True)
        form.addRow(note)
        layout.addWidget(motion)
        self.motion_mode.currentIndexChanged.connect(self.update_motion_mode)
        self.translation.currentIndexChanged.connect(self.update_motion_mode)
        self.update_motion_mode()
        sensor = QGroupBox("3 / Camera & event simulation")
        form = QFormLayout(sensor)
        form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.WrapAllRows)
        self.duration = number(1, 0.001, 3600, 3)
        self.fps = number(120, 1, 10000, 2, 30)
        self.width = QSpinBox()
        self.width.setRange(16, 4096)
        self.width.setValue(320)
        self.height = QSpinBox()
        self.height.setRange(16, 4096)
        self.height.setValue(240)
        self.fov = number(45, 1, 160, 2, 5)
        self.threshold_pos = number(0.2, 0.001, 10, 4, 0.01)
        self.threshold_neg = number(0.2, 0.001, 10, 4, 0.01)
        self.refractory = number(100, 0, 1e6, 2, 10)
        self.epsilon = number(0.001, 0.000001, 1, 6, 0.001)
        self.samples = QSpinBox()
        self.samples.setRange(1, 1024)
        self.samples.setValue(16)
        self.max_events = QSpinBox()
        self.max_events.setRange(1, 100000000)
        self.max_events.setValue(5000000)
        self.backend = QComboBox()
        self.backend.addItem("NumPy prototype (ESIM-style approximation)", "numpy")
        available = importlib.util.find_spec("esim_py") is not None
        self.backend.addItem("UZH ESIM · " + ("installed" if available else "requires esim_py"), "esim")
        self.blender = QLineEdit(self.settings.value("blender", shutil.which("blender") or "blender"))
        blender_row = QWidget()
        blender_layout = QHBoxLayout(blender_row)
        blender_layout.setContentsMargins(0, 0, 0, 0)
        blender_layout.addWidget(self.blender)
        blender_layout.addWidget(button("…", self.choose_blender))
        for label, widget in [
            ("Duration (s)", self.duration),
            ("Render rate (frames/s)", self.fps),
            ("Width (px)", self.width),
            ("Height (px)", self.height),
            ("Horizontal FOV (°)", self.fov),
            ("ON threshold (log intensity)", self.threshold_pos),
            ("OFF threshold (log intensity)", self.threshold_neg),
            ("Refractory period (µs)", self.refractory),
            ("Log epsilon", self.epsilon),
            ("Cycles samples / pixel", self.samples),
            ("Maximum events", self.max_events),
            ("Event engine", self.backend),
            ("Blender executable", blender_row),
        ]:
            form.addRow(label, widget)
        layout.addWidget(sensor)
        estimate = QLabel(
            "Higher render rates capture faster motion but take longer. Start with a short, low-resolution run."
        )
        estimate.setWordWrap(True)
        layout.addWidget(estimate)
        row = QHBoxLayout()
        row.addWidget(button("Save settings…", self.save_settings))
        row.addWidget(button("Load settings…", self.load_settings))
        layout.addLayout(row)
        layout.addStretch()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(panel)
        scroll.setMinimumWidth(380)
        return scroll

    def build_results(self):
        group = QGroupBox("4 / Inspect & export")
        layout = QVBoxLayout(group)
        self.summary = QLabel("Run a simulation or open a saved run.")
        self.summary.setWordWrap(True)
        layout.addWidget(self.summary)
        tabs = QTabWidget()
        images = QWidget()
        image_layout = QVBoxLayout(images)
        image_layout.addWidget(QLabel("Blender camera frame"))
        self.frame_image = ImagePane("Rendered frames appear here")
        self.events_image = ImagePane("Event accumulation appears here")
        image_layout.addWidget(self.frame_image, 1)
        image_layout.addWidget(QLabel("Events · cyan ON / coral OFF"))
        image_layout.addWidget(self.events_image, 1)
        tabs.addTab(images, "Frames + events")
        self.rate_plot = PlotCanvas()
        tabs.addTab(self.rate_plot, "Event rate")
        self.trajectory_plot = PlotCanvas("3d")
        tabs.addTab(self.trajectory_plot, "Trajectory")
        layout.addWidget(tabs, 1)
        self.time_label = QLabel("t = 0.000 s")
        layout.addWidget(self.time_label)
        self.scrubber = QSlider(Qt.Orientation.Horizontal)
        self.scrubber.setRange(0, 0)
        self.scrubber.valueChanged.connect(self.show_frame)
        layout.addWidget(self.scrubber)
        row = QHBoxLayout()
        self.play_button = button("Play", self.toggle_play)
        self.play_button.setEnabled(False)
        row.addWidget(self.play_button)
        row.addWidget(QLabel("Event window (ms)"))
        self.window_ms = number(20, 0.01, 10000, 2, 5)
        self.window_ms.valueChanged.connect(self.show_frame)
        row.addWidget(self.window_ms)
        layout.addLayout(row)
        row = QHBoxLayout()
        row.addWidget(button("Open run…", self.open_run))
        self.save_run_button = button("Save full run…", self.save_run)
        self.save_run_button.setEnabled(False)
        row.addWidget(self.save_run_button)
        layout.addLayout(row)
        self.export_button = button("Export events · HDF5 / CSV / NPZ…", self.export_events)
        self.export_button.setEnabled(False)
        layout.addWidget(self.export_button)
        return group

    def update_motion_mode(self):
        csv_mode = self.motion_mode.currentIndex() == 1
        self.csv_path.setEnabled(csv_mode)
        self.csv_button.setEnabled(csv_mode)
        self.velocity.setEnabled(not csv_mode)
        self.translation.setEnabled(not csv_mode)
        gravity = not csv_mode and self.translation.currentData() == "gravity"
        self.gravity_center.setEnabled(gravity)
        self.mu.setEnabled(gravity)

    def restore_models(self):
        for path in self.settings.value("models", [], type=list):
            if not Path(path).is_absolute():
                path = str(PROJECT_ROOT / path)
            if Path(path).is_file():
                self.register_model(path)

    def register_model(self, path):
        path = str(Path(path).resolve())
        index = self.models.findData(path)
        if index < 0:
            self.models.addItem(Path(path).name, path)
            index = self.models.count() - 1
            self.models.setItemData(index, path, Qt.ItemDataRole.ToolTipRole)
        return index

    def persist_models(self):
        paths = []
        for i in range(1, self.models.count()):
            path = Path(self.models.itemData(i))
            try:
                path = path.relative_to(PROJECT_ROOT)
            except ValueError:
                pass
            paths.append(str(path))
        self.settings.setValue("models", paths)

    def add_model(self):
        paths, _ = QFileDialog.getOpenFileNames(
            self, "Add spacecraft models", "", "CAD meshes (*.stl *.obj *.ply *.glb *.gltf *.step *.stp)"
        )
        for path in paths:
            self.models.setCurrentIndex(self.register_model(path))
        self.persist_models()

    def add_model_folder(self):
        path = QFileDialog.getExistingDirectory(self, "Choose a model library folder")
        if path:
            self.scan_model_folder(Path(path), select_first=True)

    def scan_model_folder(self, folder, *, select_first=False):
        paths = sorted(
            item for item in folder.rglob("*")
            if item.is_file() and item.suffix.lower() in SUPPORTED
        )
        indices = [self.register_model(path) for path in paths]
        self.persist_models()
        self.log.appendPlainText(f"Model library: {len(paths)} supported file(s) in {folder}")
        if indices and select_first:
            self.models.setCurrentIndex(indices[0])
        elif not indices:
            self.log.appendPlainText("No supported models found. Use STL, OBJ, PLY, GLB, GLTF, STEP or STP.")

    def refresh_library(self):
        folders = {PROJECT_ROOT / "cad-models"}
        for folder in sorted(folders):
            if folder.is_dir():
                self.scan_model_folder(folder)

    def refresh_model(self):
        try:
            self.mesh = load_model(self.models.currentData() or "", self.scale.value())
            sizes = " × ".join(f"{x:.3g}" for x in self.mesh.extents)
            self.model_info.setText(
                f"{len(self.mesh.faces):,} triangles · {sizes} m\nBody origin: bounding-box center"
            )
            self.update_preview()
        except Exception as exc:
            self.mesh = None
            message = f"Could not load {self.models.currentText()}: {exc}"
            self.model_info.setText(message)
            self.log.appendPlainText(message)
            self.preview.axes.clear()
            self.preview.draw_idle()

    def update_preview(self):
        if self.mesh is None:
            return
        axes = self.preview.axes
        elevation, azimuth = axes.elev, axes.azim
        axes.clear()
        # Keep the preview responsive for large CAD files; rendering uses all faces.
        indices = np.linspace(0, len(self.mesh.faces) - 1, min(15000, len(self.mesh.faces)), dtype=int)
        triangles = self.mesh.triangles[indices]
        rotation = Rotation.from_euler("xyz", self.attitude.values(), degrees=True)
        triangles = rotation.apply(triangles.reshape(-1, 3)).reshape(-1, 3, 3)
        visual = self.mesh.visual
        if hasattr(visual, "to_color"):
            visual = visual.to_color()
            # Texture conversion returns detached vertex colors; face-color
            # interpolation needs the mesh topology attached to that visual.
            visual.mesh = self.mesh
        colors = visual.face_colors[indices] / 255
        collection = Poly3DCollection(triangles, facecolors=colors, edgecolors="#536478", linewidths=0.12)
        axes.add_collection3d(collection)
        extent = max(np.linalg.norm(self.mesh.extents) / 2, 0.01)
        axes.set(
            xlim=(-extent, extent),
            ylim=(-extent, extent),
            zlim=(-extent, extent),
            xlabel="X (m)",
            ylabel="Y (m)",
            zlabel="Z (m)",
        )
        axes.set_box_aspect((1, 1, 1))
        axes.view_init(elev=elevation, azim=azimuth)
        self.preview.style()
        self.preview.draw_idle()

    def reset_pose(self):
        self.position.set_values([0, 0, 12])
        self.attitude.set_values([15, 20, 0])

    def auto_range(self):
        try:
            if self.mesh is None:
                raise ValueError("Select a valid model before using Auto range.")
            if self.motion_mode.currentIndex() == 1 and self.csv_path.text().strip():
                initial_position = read_velocity_csv(
                    self.csv_path.text().strip(), self.duration.value()
                )[3]
                if initial_position is not None:
                    raise ValueError(
                        "The CSV overrides the initial position. Remove its x,y,z columns "
                        "to use Auto range, or use initial-state motion."
                    )
            vertices = Rotation.from_euler(
                "xyz", self.attitude.values(), degrees=True
            ).apply(self.mesh.vertices)
            horizontal = np.tan(np.deg2rad(self.fov.value()) / 2) * 0.9
            vertical = horizontal * self.height.value() / self.width.value()
            distance = max(
                np.max(np.abs(vertices[:, 0]) / horizontal - vertices[:, 2]),
                np.max(np.abs(vertices[:, 1]) / vertical - vertices[:, 2]),
                0.02 - np.min(vertices[:, 2]),
            )
            # Round upward so the position control cannot reduce the fit distance.
            distance = np.ceil(distance * 10000) / 10000
            if distance > self.position.fields[2].maximum():
                raise ValueError("Model is too large to auto-range; reduce metres / model unit.")
            self.position.set_values([0, 0, distance])
            self.log.appendPlainText(
                f"Auto range: initial position (0, 0, {distance:g}) m; "
                "whole model fits with a 5% border. Motion may leave the frame later."
            )
        except Exception as exc:
            self.error(exc)

    def choose_csv(self):
        path, _ = QFileDialog.getOpenFileName(self, "Velocity history", "", "CSV (*.csv)")
        if path:
            self.csv_path.setText(path)

    def choose_blender(self):
        path, _ = QFileDialog.getOpenFileName(self, "Select Blender executable")
        if path:
            self.blender.setText(path)

    def configuration(self):
        config = SimulationConfig(
            model_path=self.models.currentData() or "",
            model_scale=self.scale.value(),
            duration=self.duration.value(),
            fps=self.fps.value(),
            width=self.width.value(),
            height=self.height.value(),
            fov_deg=self.fov.value(),
            threshold_pos=self.threshold_pos.value(),
            threshold_neg=self.threshold_neg.value(),
            refractory_s=self.refractory.value() * 1e-6,
            log_epsilon=self.epsilon.value(),
            backend=self.backend.currentData(),
            blender=self.blender.text().strip(),
            samples=self.samples.value(),
            max_events=self.max_events.value(),
            motion=MotionConfig(
                position=self.position.values(),
                velocity=self.velocity.values(),
                attitude_deg=self.attitude.values(),
                angular_rate_deg=self.omega.values(),
                inertia=self.inertia.values(),
                translation=self.translation.currentData(),
                mu=self.mu.value(),
                gravity_center=self.gravity_center.values(),
                csv_path=self.csv_path.text().strip() if self.motion_mode.currentIndex() else "",
                integration_step=self.integration_step.value(),
            ),
        )
        if self.motion_mode.currentIndex() and not config.motion.csv_path:
            raise ValueError("Select a trajectory CSV, or switch to initial-state input.")
        config.validate()
        return config

    def save_settings(self):
        try:
            config = self.configuration()
            path, _ = QFileDialog.getSaveFileName(self, "Save settings", "spacecam.json", "JSON (*.json)")
            if path:
                Path(path).write_text(json.dumps(config.to_dict(), indent=2), encoding="utf-8")
        except Exception as exc:
            self.error(exc)

    def load_settings(self):
        path, _ = QFileDialog.getOpenFileName(self, "Load settings", "", "JSON (*.json)")
        if not path:
            return
        try:
            config = SimulationConfig.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))
            config.validate()
            self.models.setCurrentIndex(self.register_model(config.model_path) if config.model_path else 0)
            for widget, value in [
                (self.scale, config.model_scale),
                (self.duration, config.duration),
                (self.fps, config.fps),
                (self.width, config.width),
                (self.height, config.height),
                (self.fov, config.fov_deg),
                (self.threshold_pos, config.threshold_pos),
                (self.threshold_neg, config.threshold_neg),
                (self.refractory, config.refractory_s * 1e6),
                (self.epsilon, config.log_epsilon),
                (self.samples, config.samples),
                (self.max_events, config.max_events),
                (self.integration_step, config.motion.integration_step),
                (self.mu, config.motion.mu),
            ]:
                widget.setValue(value)
            for widget, value in [
                (self.position, config.motion.position),
                (self.velocity, config.motion.velocity),
                (self.attitude, config.motion.attitude_deg),
                (self.omega, config.motion.angular_rate_deg),
                (self.inertia, config.motion.inertia),
                (self.gravity_center, config.motion.gravity_center),
            ]:
                widget.set_values(value)
            self.backend.setCurrentIndex(self.backend.findData(config.backend))
            self.translation.setCurrentIndex(self.translation.findData(config.motion.translation))
            self.blender.setText(config.blender)
            self.csv_path.setText(config.motion.csv_path)
            self.motion_mode.setCurrentIndex(bool(config.motion.csv_path))
        except Exception as exc:
            self.error(exc)

    def start_run(self):
        try:
            config = self.configuration()
            if self.mesh is None:
                raise ValueError("Load a valid model before running.")
            # Validate trajectory input before launching any expensive rendering.
            if config.motion.csv_path:
                from .dynamics import read_velocity_csv

                read_velocity_csv(config.motion.csv_path, config.duration)
            if not shutil.which(config.blender):
                raise ValueError(
                    "Blender was not found. Set its executable path in Camera & event simulation."
                )
            if config.backend == "esim" and importlib.util.find_spec("esim_py") is None:
                raise ValueError(
                    "Install UZH esim_py using the README instructions or select NumPy prototype."
                )
            self.settings.setValue("blender", config.blender)
            self.run_dir = self.run_root / datetime.now().strftime("run-%Y%m%d-%H%M%S-%f")
            config_path = Path(self.workspace.name) / "current-config.json"
            config_path.write_text(json.dumps(config.to_dict()), encoding="utf-8")
            self.log.appendPlainText(f"Starting {config.backend} run → {self.run_dir}")
            self.set_running(True)
            self.process = QProcess(self)
            self.process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
            self.process.readyReadStandardOutput.connect(self.read_process_output)
            self.process.finished.connect(self.run_finished)
            self.process.errorOccurred.connect(self.process_error)
            self.process.start(
                sys.executable,
                ["-u", "-m", "spacecam.cli", "--config", str(config_path), "--output", str(self.run_dir)],
            )
        except Exception as exc:
            self.set_running(False)
            self.error(exc)

    def set_running(self, running):
        self.run_button.setEnabled(not running)
        self.cancel_button.setEnabled(running)
        self.model_group.setEnabled(not running)
        self.control_scroll.setEnabled(not running)
        self.progress.setRange(0, 0 if running else 1)
        self.progress.setValue(0)

    def read_process_output(self):
        if self.process:
            text = bytes(self.process.readAllStandardOutput()).decode("utf-8", errors="replace").strip()
            if text:
                self.log.appendPlainText(text)

    def process_error(self, error):
        if error == QProcess.ProcessError.FailedToStart:
            self.set_running(False)
            self.error(RuntimeError(self.process.errorString()))
            self.process.deleteLater()
            self.process = None

    def cancel_run(self):
        if self.run_dir and self.process:
            self.run_dir.mkdir(parents=True, exist_ok=True)
            (self.run_dir / "CANCEL").touch()
            self.cancel_button.setEnabled(False)
            self.log.appendPlainText("Cancelling; waiting for render/event subprocess to stop…")

    def run_finished(self, exit_code, exit_status):
        self.read_process_output()
        self.set_running(False)
        self.process.deleteLater()
        self.process = None
        if exit_code == 0:
            try:
                self.set_result(read_result(self.run_dir))
                self.progress.setValue(1)
            except Exception as exc:
                self.error(exc)
        elif not (self.run_dir / "CANCEL").exists():
            self.error(RuntimeError(f"Simulation failed. Details are in the log below and in {self.run_dir}"))
        if self.close_pending:
            self.close()

    def set_result(self, result):
        self.timer.stop()
        self.play_button.setText("Play")
        self.result = result
        on_count = np.count_nonzero(result.events["p"] > 0)
        self.summary.setText(
            f"{len(result.events):,} events · {on_count:,} ON / {len(result.events) - on_count:,} OFF\n"
            f"{len(result.times)} frames · {result.config.duration:g} s · engine: {result.config.backend}"
        )
        self.scrubber.setRange(0, len(result.times) - 1)
        self.scrubber.setValue(min(1, len(result.times) - 1))
        self.show_frame()
        self.play_button.setEnabled(True)
        self.save_run_button.setEnabled(True)
        self.export_button.setEnabled(True)
        axes = self.rate_plot.axes
        axes.clear()
        bins = np.linspace(0, result.config.duration, min(101, len(result.times) + 1))
        for polarity, color, label in [(1, "#3ed2f5", "ON"), (-1, "#ff6958", "OFF")]:
            counts, _ = np.histogram(result.events["t"][result.events["p"] == polarity], bins=bins)
            axes.step(bins[:-1], counts / np.diff(bins), where="post", color=color, label=label)
        axes.set(xlabel="Time (s)", ylabel="Events / second")
        axes.legend()
        self.rate_plot.style()
        self.rate_plot.draw_idle()
        trajectory = np.atleast_2d(np.loadtxt(result.directory / "trajectory.csv", delimiter=",", skiprows=1))
        axes = self.trajectory_plot.axes
        axes.clear()
        axes.plot(trajectory[:, 1], trajectory[:, 2], trajectory[:, 3], color="#3ed2f5")
        axes.scatter(*trajectory[0, 1:4], color="#ffbd69", label="Start")
        axes.set(xlabel="X (m)", ylabel="Y (m)", zlabel="Z (m)")
        axes.legend()
        self.trajectory_plot.style()
        self.trajectory_plot.draw_idle()

    def show_frame(self, *_):
        if self.result is None:
            return
        index = self.scrubber.value()
        time = self.result.times[index]
        self.time_label.setText(f"t = {time:.4f} s · frame {index + 1}/{len(self.result.times)}")
        self.frame_image.set_source(self.result.directory / "frames" / f"{index:06d}.png")
        self.events_image.set_source(
            event_image(
                self.result.events,
                self.result.config.width,
                self.result.config.height,
                time - self.window_ms.value() / 1000,
                time,
            )
        )

    def toggle_play(self):
        if self.timer.isActive():
            self.timer.stop()
            self.play_button.setText("Play")
        else:
            self.timer.start(max(16, round(1000 / self.result.config.fps)))
            self.play_button.setText("Pause")

    def advance_frame(self):
        self.scrubber.setValue((self.scrubber.value() + 1) % len(self.result.times))

    def open_run(self):
        path = QFileDialog.getExistingDirectory(self, "Open saved simulation run")
        if path:
            try:
                self.set_result(read_result(path))
            except Exception as exc:
                self.error(exc)

    def save_run(self):
        parent = QFileDialog.getExistingDirectory(
            self, "Choose destination; a new run folder will be created"
        )
        if parent and self.result:
            try:
                destination = Path(parent) / datetime.now().strftime("spacecam-%Y%m%d-%H%M%S-%f")
                if destination.resolve().is_relative_to(self.result.directory.resolve()):
                    raise ValueError("Choose a destination outside the source run folder.")
                shutil.copytree(self.result.directory, destination)
                self.log.appendPlainText(f"Saved complete run to {destination}")
            except Exception as exc:
                self.error(exc)

    def export_events(self):
        if self.result is None:
            return
        path, selected = QFileDialog.getSaveFileName(
            self, "Export events", "events.hdf5",
            "HDF5 for MATLAB (*.hdf5);;NumPy recording (*.npz);;CSV (*.csv)"
        )
        if path:
            try:
                suffix = ".hdf5" if "HDF5" in selected else ".csv" if "CSV" in selected else ".npz"
                destination = Path(path)
                if destination.suffix.lower() != suffix:
                    destination = destination.with_suffix(suffix)
                if suffix == ".csv":
                    export_csv(self.result.events, destination)
                elif suffix == ".hdf5":
                    export_hdf5(self.result.events, destination)
                else:
                    np.savez_compressed(destination, events=self.result.events)
                self.log.appendPlainText(f"Exported {len(self.result.events):,} events to {destination}")
            except Exception as exc:
                self.error(exc)

    def error(self, exc):
        QMessageBox.critical(self, "Spacecraft simulator", str(exc))

    def closeEvent(self, event):
        if self.process is not None:
            self.close_pending = True
            self.cancel_run()
            event.ignore()
            return
        # Keep completed runs on disk even if the user closes before exporting.
        self.timer.stop()
        self.workspace.cleanup()
        event.accept()


def configure_application(app):
    app.setOrganizationName("ESFM")
    app.setApplicationName("Spacecam")
    app.setStyle("Fusion")
    app.setStyleSheet("""
        QWidget { background: #17212e; color: #dce6ef; font-size: 12px; }
        QGroupBox { border: 1px solid #34485c; border-radius: 7px; margin-top: 16px; padding-top: 12px; }
        QGroupBox::title { subcontrol-origin: margin; left: 10px; color: #8ddde9; font-weight: bold; }
        QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox, QPlainTextEdit { background: #101722; padding: 4px; border: 1px solid #34485c; border-radius: 3px; }
        QPushButton { background: #293e52; border: 1px solid #405970; border-radius: 4px; padding: 6px; }
        QPushButton:hover { background: #37546e; }
        QWidget:disabled { color: #738392; }
        QTabBar::tab { padding: 8px; }
        QTabBar::tab:selected { background: #293e52; }
        QProgressBar { border: 1px solid #34485c; border-radius: 4px; text-align: center; }
        QProgressBar::chunk { background: #187d90; }
    """)


def main():
    app = QApplication.instance() or QApplication(sys.argv)
    configure_application(app)
    window = SimulatorWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
