"""Camera intrinsics: OpenCV XML calibration files in the project folder.

The pipeline reads fx, fy, cx, cy, the first two distortion coefficients
(k1, k2 of the equidistant/Kannala-Brandt model) and the image size
(io.read_calibration). The XML may hold four coefficients; all are kept.
"""
import re
import shutil
from pathlib import Path

from . import config_model
from .common import ApiError, backup, root


def _num(s):
    return float(s.rstrip("."))


def _fmt(v):
    r = repr(float(v))
    return r[:-2] + "." if r.endswith(".0") else r


def files():
    out = []
    for p in sorted(root().glob("*.xml")):
        t = p.read_text(errors="replace")
        if "<camera_matrix" in t:
            out.append(p.name)
    return out


def active_file():
    ov = config_model.overrides().get("camera.calibration_xml")
    expr = ov
    if expr is None:
        p = next((q for q in config_model.parse()["params"] if q["path"] == "camera.calibration_xml"), None)
        expr = p["expr"] if p else ""
    parts = re.findall(r"'([^']*)'", expr or "")
    return "".join(parts), ov is not None


def read(name):
    p = _path(name)
    t = p.read_text()
    k = re.search(r"<camera_matrix.*?<data>(.*?)</data>", t, re.S)
    d = re.search(r"<distortion_coefficients.*?<data>(.*?)</data>", t, re.S)
    w = re.search(r"<image_width>\s*(\d+)", t)
    h = re.search(r"<image_height>\s*(\d+)", t)
    if not (k and d and w and h):
        raise ApiError("Missing camera_matrix, distortion_coefficients or image size")
    K = [_num(v) for v in k.group(1).split()]
    D = [_num(v) for v in d.group(1).split()]
    block = re.search(r"<opencv_storage>\s*<(\w+)>", t)

    def tag(name_):
        m = re.search(rf"<{name_}>\s*\"?(.*?)\"?\s*</{name_}>", t, re.S)
        return m.group(1).strip() if m else None
    return {"file": name, "camera": block.group(1) if block else "", "fx": K[0], "fy": K[4], "cx": K[2], "cy": K[5],
            "skew": K[1], "dist": D, "width": int(w.group(1)), "height": int(h.group(1)),
            "fisheye": tag("use_fisheye_model") == "1", "error_px": tag("calibration_error"),
            "time": tag("calibration_time"), "pattern": tag("pattern_type")}


def _path(name):
    if not re.fullmatch(r"[\w.\-]+\.xml", name or ""):
        raise ApiError("Invalid calibration file name")
    p = root() / name
    if not p.is_file():
        raise ApiError(f"No such file: {name}", 404)
    return p


def write(name, values, save_as=None):
    p = _path(name)
    if save_as:
        if not re.fullmatch(r"[\w.\-]+\.xml", save_as):
            raise ApiError("Invalid new file name (letters, digits, . _ - and .xml)")
        q = root() / save_as
        if q.exists():
            raise ApiError(f"{save_as} exists")
        shutil.copy2(p, q)
        p = q
    t = p.read_text()
    cur = read(p.name)
    fx, fy = float(values.get("fx", cur["fx"])), float(values.get("fy", cur["fy"]))
    cx, cy = float(values.get("cx", cur["cx"])), float(values.get("cy", cur["cy"]))
    D = [float(v) for v in values.get("dist", cur["dist"])]
    if fx <= 0 or fy <= 0:
        raise ApiError("Focal lengths must be positive")
    if len(D) != len(cur["dist"]):
        raise ApiError(f"Expected {len(cur['dist'])} distortion coefficients")
    K = [fx, cur["skew"], cx, 0, fy, cy, 0, 0, 1]
    kd = "\n      " + " ".join(_fmt(v) for v in K[:5]) + "\n      " + " ".join(_fmt(v) for v in K[5:])
    dd = "\n      " + " ".join(_fmt(v) for v in D)
    t = re.sub(r"(<camera_matrix.*?<data>)(.*?)(</data>)", lambda m: m.group(1) + kd + m.group(3), t, count=1, flags=re.S)
    t = re.sub(r"(<distortion_coefficients.*?<data>)(.*?)(</data>)", lambda m: m.group(1) + dd + m.group(3), t, count=1, flags=re.S)
    for tag_, key in (("image_width", "width"), ("image_height", "height")):
        if key in values:
            t = re.sub(rf"<{tag_}>\s*\d+\s*</{tag_}>", f"<{tag_}>{int(values[key])}</{tag_}>", t, count=1)
    bk = backup(p) if not save_as else None
    p.write_text(t)
    return {"saved": p.name, "backup": str(bk.relative_to(root())) if bk else None, "values": read(p.name)}
