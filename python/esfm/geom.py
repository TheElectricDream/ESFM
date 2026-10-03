"""+geom. Rotations are [M, 3, 3] stacks; X_camera = R @ X_object + T."""
import numpy as np


def unit_rows(v):
    v = np.atleast_2d(v)
    return v / np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-12)


def rodrigues(a, theta):
    a = np.asarray(a, float).ravel()
    th = np.atleast_1d(np.asarray(theta, float)).ravel()
    c, s = np.cos(th), np.sin(th)
    C = 1 - c
    R = np.empty((th.size, 3, 3))
    R[:, 0, 0] = c + a[0] ** 2 * C
    R[:, 0, 1] = a[0] * a[1] * C - a[2] * s
    R[:, 0, 2] = a[0] * a[2] * C + a[1] * s
    R[:, 1, 0] = a[1] * a[0] * C + a[2] * s
    R[:, 1, 1] = c + a[1] ** 2 * C
    R[:, 1, 2] = a[1] * a[2] * C - a[0] * s
    R[:, 2, 0] = a[2] * a[0] * C - a[1] * s
    R[:, 2, 1] = a[2] * a[1] * C + a[0] * s
    R[:, 2, 2] = c + a[2] ** 2 * C
    return R


def apply_pose(R, T, X):
    return np.einsum('mij,mj->mi', R, X) + T


def project(R, T, X, cam):
    Y = apply_pose(R, T, X)
    z = np.maximum(Y[:, 2], 1e-6)
    return cam.focal * Y[:, :2] / z[:, None] + cam.principal, Y


def axis_tangent(a):
    a = np.asarray(a, float).ravel()
    t1 = np.cross(a, [1, 0, 0]) if abs(a[0]) < 0.9 else np.cross(a, [0, 1, 0])
    t1 = t1 / np.linalg.norm(t1)
    return t1, np.cross(a, t1)


def hemisphere_directions(n, pole):
    i = np.arange(n) + 0.5
    z = 1 - i / n
    phi = np.pi * (1 + np.sqrt(5)) * i
    r = np.sqrt(1 - z ** 2)
    d = np.c_[r * np.cos(phi), r * np.sin(phi), z]
    pole = np.asarray(pole, float).ravel()
    pole = pole / np.linalg.norm(pole)
    ref = np.zeros(3)
    ref[np.argmin(np.abs(pole))] = 1
    t1 = np.cross(pole, ref)
    t1 /= np.linalg.norm(t1)
    t2 = np.cross(pole, t1)
    return d[:, :1] * t1 + d[:, 1:2] * t2 + d[:, 2:3] * pole


def undistort_equidistant(xy, cam):
    """Kannala-Brandt inverse by 8 Newton steps, reprojected through an ideal pinhole."""
    xd = (xy[:, 0] - cam.principal[0]) / cam.focal[0]
    yd = (xy[:, 1] - cam.principal[1]) / cam.focal[1]
    th_d = np.sqrt(xd ** 2 + yd ** 2)
    th = th_d.copy()
    for _ in range(8):
        t2 = th ** 2
        f = th * (1 + cam.k1 * t2 + cam.k2 * t2 ** 2) - th_d
        df = 1 + 3 * cam.k1 * t2 + 5 * cam.k2 * t2 ** 2
        th = th - f / df
    scale = np.ones_like(th_d)
    nz = th_d > 1e-9
    scale[nz] = np.tan(th[nz]) / th_d[nz]
    return np.c_[cam.focal[0] * xd * scale + cam.principal[0],
                 cam.focal[1] * yd * scale + cam.principal[1]]


def triangulate(R, T, ii, uv, n, npts, eps_w, cam, return_cov=False):
    """Edge-weighted linear (DLT-style) triangulation, one point per id in ii."""
    m = (uv - cam.principal) / cam.focal
    mX, mY = m[:, 0:1], m[:, 1:2]
    A1 = mX * R[:, 2, :] - R[:, 0, :]
    A2 = mY * R[:, 2, :] - R[:, 1, :]
    b1 = T[:, 0] - m[:, 0] * T[:, 2]
    b2 = T[:, 1] - m[:, 1] * T[:, 2]
    tang = np.c_[-n[:, 1], n[:, 0]]
    An = n[:, 0:1] * A1 + n[:, 1:2] * A2
    bn = n[:, 0] * b1 + n[:, 1] * b2
    At = eps_w * (tang[:, 0:1] * A1 + tang[:, 1:2] * A2)
    bt = eps_w * (tang[:, 0] * b1 + tang[:, 1] * b2)
    ii = np.asarray(ii, int)
    AtA = np.zeros((npts, 3, 3))
    Atb = np.zeros((npts, 3))
    for r in range(3):
        Atb[:, r] = (np.bincount(ii, An[:, r] * bn, npts) + np.bincount(ii, At[:, r] * bt, npts))
        for c in range(3):
            AtA[:, r, c] = (np.bincount(ii, An[:, r] * An[:, c], npts)
                            + np.bincount(ii, At[:, r] * At[:, c], npts))
    Areg = AtA + 1e-9 * np.eye(3)
    X = np.linalg.solve(Areg, Atb[..., None])[..., 0]
    if not return_cov:
        return X
    res = np.r_[np.sum(An * X[ii], 1) - bn, np.sum(At * X[ii], 1) - bt]
    var = res @ res / max(res.size - 3 * npts, 1)
    return X, var * np.linalg.inv(Areg)
