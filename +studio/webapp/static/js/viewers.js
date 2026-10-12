// Viewers shared by every page: frames (zoom/pan canvas), point clouds (three.js),
// series (stacked line plots) and track lines over a frame.
import * as THREE from 'three';
import { OrbitControls } from '/vendor/three/OrbitControls.js';
import { b64bytes, el, fmtNum, tc } from './app.js';

export const COLORS = ['#4c8dff', '#3ccf7e', '#f5a524', '#f0545a', '#b38cff', '#2fd0d0', '#ff8fd0', '#c7cdd8'];

// ====================== FrameView ======================
export class FrameView {
  constructor(host) {
    this.host = host;
    this.canvas = el('canvas', { class: 'frame-canvas' });
    this.readout = el('div', { class: 'readout', hidden: true });
    this.legend = el('div', { class: 'legend', hidden: true });
    host.append(this.canvas, this.readout, this.legend);
    this.ctx = this.canvas.getContext('2d');
    this.off = document.createElement('canvas');
    this.w = 0; this.h = 0; this.zoom = 1; this.panX = 0; this.panY = 0; this.fit = true;
    this.overlay = null;
    this.ro = new ResizeObserver(() => this.draw()); this.ro.observe(host);
    host.addEventListener('wheel', e => this._wheel(e), { passive: false });
    host.addEventListener('mousedown', e => this._drag(e));
    host.addEventListener('mousemove', e => this._move(e));
    host.addEventListener('mouseleave', () => { this.readout.hidden = true; });
    host.addEventListener('dblclick', () => { this.fit = true; this.draw(); });
  }
  destroy() { this.ro.disconnect(); this.canvas.remove(); this.readout.remove(); this.legend.remove(); }
  setImage(rgba, w, h) {
    if (w !== this.w || h !== this.h) { this.off.width = w; this.off.height = h; this.w = w; this.h = h; this.fit = true; }
    const data = rgba instanceof Uint8ClampedArray ? rgba : new Uint8ClampedArray(rgba.buffer || rgba);
    this.off.getContext('2d').putImageData(new ImageData(data, w, h), 0, 0);
    this.draw();
  }
  setSize(w, h) { this.off.width = w; this.off.height = h; this.w = w; this.h = h; const c = this.off.getContext('2d'); c.fillStyle = '#0b0d11'; c.fillRect(0, 0, w, h); this.draw(); }
  setLegend(html) { this.legend.innerHTML = html || ''; this.legend.hidden = !html; }
  setOverlay(fn) { this.overlay = fn; this.draw(); }
  _layout() {
    const W = this.host.clientWidth, H = this.host.clientHeight;
    if (this.fit && this.w) { this.zoom = Math.min(W / this.w, H / this.h) * 0.98; this.panX = (W - this.w * this.zoom) / 2; this.panY = (H - this.h * this.zoom) / 2; }
    return [W, H];
  }
  draw() {
    const [W, H] = this._layout(); const dpr = window.devicePixelRatio || 1;
    this.canvas.width = W * dpr; this.canvas.height = H * dpr;
    this.canvas.style.width = W + 'px'; this.canvas.style.height = H + 'px'; this.canvas.style.left = '0'; this.canvas.style.top = '0';
    const c = this.ctx; c.setTransform(dpr, 0, 0, dpr, 0, 0); c.clearRect(0, 0, W, H);
    if (!this.w) return;
    c.imageSmoothingEnabled = this.zoom < 1;
    c.drawImage(this.off, this.panX, this.panY, this.w * this.zoom, this.h * this.zoom);
    c.strokeStyle = '#262b35'; c.lineWidth = 1; c.strokeRect(this.panX - .5, this.panY - .5, this.w * this.zoom + 1, this.h * this.zoom + 1);
    if (this.overlay) { c.save(); this.overlay(c, (x, y) => [this.panX + x * this.zoom, this.panY + y * this.zoom], this.zoom); c.restore(); }
  }
  _wheel(e) {
    e.preventDefault(); if (!this.w) return;
    const r = this.host.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
    const f = Math.exp(-e.deltaY * 0.0015), z = Math.min(40, Math.max(0.1, this.zoom * f));
    this.panX = mx - (mx - this.panX) * z / this.zoom; this.panY = my - (my - this.panY) * z / this.zoom; this.zoom = z; this.fit = false; this.draw();
  }
  _drag(e) {
    if (e.button !== 0) return; const x0 = e.clientX, y0 = e.clientY, px = this.panX, py = this.panY;
    const mv = ev => { this.panX = px + ev.clientX - x0; this.panY = py + ev.clientY - y0; this.fit = false; this.draw(); };
    const up = () => { window.removeEventListener('mousemove', mv); window.removeEventListener('mouseup', up); };
    window.addEventListener('mousemove', mv); window.addEventListener('mouseup', up);
  }
  _move(e) {
    if (!this.w) return;
    const r = this.host.getBoundingClientRect();
    const x = (e.clientX - r.left - this.panX) / this.zoom, y = (e.clientY - r.top - this.panY) / this.zoom;
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) { this.readout.hidden = true; return; }
    this.readout.hidden = false; this.readout.textContent = `x ${x.toFixed(1)}  y ${y.toFixed(1)}  ·  ${this.zoom.toFixed(2)}×  (Double-Click: Fit)`;
    this.onHover?.(x, y);
  }
}

// ====================== PointsView ======================
export class PointsView {
  constructor(host) {
    this.host = host;
    this.renderer = new THREE.WebGLRenderer({ antialias: true });
    this.renderer.setPixelRatio(window.devicePixelRatio || 1);
    this.renderer.setClearColor(0x0a0c10);
    host.append(this.renderer.domElement);
    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(45, 1, 0.001, 1e6);
    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.group = new THREE.Group(); this.scene.add(this.group);
    this.info = el('div', { class: 'readout' }); host.append(this.info);
    this.corner = el('div', { class: 'corner' }); host.append(this.corner);
    this.size = 2.5;
    const sz = el('input', { type: 'range', min: '0.5', max: '8', step: '0.25', value: '2.5', style: 'width:110px', title: 'Point size' });
    sz.oninput = () => { this.size = +sz.value; if (this.points) this.points.material.size = this.size; };
    const reset = el('button', { class: 'btn btn-xs', text: 'Reset View', title: 'Frame the whole cloud again (drag to rotate, right-drag to pan, wheel to zoom; your view is kept while the data updates)', onclick: () => this.frameAll() });
    const views = ['Top', 'Front', 'Side'].map((n, i) => el('button', { class: 'btn btn-xs', text: n, title: `Look from the ${n.toLowerCase()}`, onclick: () => this.look(i) }));
    this.corner.append(reset, ...views, sz);
    this.ro = new ResizeObserver(() => this._resize()); this.ro.observe(host);
    this._alive = true;
    const loop = () => { if (!this._alive) return; this.controls.update(); this.renderer.render(this.scene, this.camera); requestAnimationFrame(loop); };
    loop();
  }
  destroy() { this._alive = false; this.ro.disconnect(); this.controls.dispose(); this.renderer.dispose(); this.renderer.domElement.remove(); this.info.remove(); this.corner.remove(); }
  _resize() { const W = this.host.clientWidth, H = this.host.clientHeight; if (!W || !H) return; this.renderer.setSize(W, H); this.camera.aspect = W / H; this.camera.updateProjectionMatrix(); }
  setPoints(p) {
    this.group.clear();
    const xyz = new Float32Array(b64bytes(p.xyz).buffer), rgb = b64bytes(p.rgb);
    const n = xyz.length / 3; const pos = new Float32Array(n * 3); const col = new Float32Array(n * 3);
    // image-space clouds: x right, y down (flip), t towards the viewer, scaled to the image size
    let tScale = 1, image = p.space === 'image';
    if (image && p.extent) tScale = 0.8 * Math.max(p.extent[0], p.extent[1]) / Math.max(p.extent[2], 1e-9);
    for (let i = 0; i < n; i++) {
      if (image) { pos[3 * i] = xyz[3 * i]; pos[3 * i + 1] = -xyz[3 * i + 1]; pos[3 * i + 2] = xyz[3 * i + 2] * tScale; }
      else { pos[3 * i] = xyz[3 * i]; pos[3 * i + 1] = xyz[3 * i + 1]; pos[3 * i + 2] = xyz[3 * i + 2]; }
      col[3 * i] = rgb[3 * i] / 255; col[3 * i + 1] = rgb[3 * i + 1] / 255; col[3 * i + 2] = rgb[3 * i + 2] / 255;
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3)); g.setAttribute('color', new THREE.BufferAttribute(col, 3));
    g.computeBoundingBox(); g.computeBoundingSphere();
    this.points = new THREE.Points(g, new THREE.PointsMaterial({ size: this.size, sizeAttenuation: false, vertexColors: true }));
    this.group.add(this.points);
    const box = g.boundingBox.clone();
    if (p.path) {
      const pp = new Float32Array(b64bytes(p.path).buffer);
      const lg = new THREE.BufferGeometry(); lg.setAttribute('position', new THREE.BufferAttribute(pp, 3));
      this.group.add(new THREE.Line(lg, new THREE.LineBasicMaterial({ color: 0xf5a524, transparent: true, opacity: .8 })));
      const s = new THREE.Mesh(new THREE.SphereGeometry(box.getSize(new THREE.Vector3()).length() * 0.01), new THREE.MeshBasicMaterial({ color: 0xf5a524 }));
      s.position.set(pp[0], pp[1], pp[2]); this.group.add(s);
      lg.computeBoundingBox(); box.union(lg.boundingBox);
    }
    const helper = new THREE.Box3Helper(box, 0x343a47); this.group.add(helper);
    const sizeV = box.getSize(new THREE.Vector3());
    const ax = new THREE.AxesHelper(Math.max(sizeV.x, sizeV.y, sizeV.z) * 0.15);
    ax.position.copy(box.min); this.group.add(ax);
    this.box = box; this.image = image;
    const labels = p.axes ? `Axes Red/Green/Blue: ${p.axes.join(', ')}${image ? ' (y Flipped, t Scaled)' : ''}` : '';
    this.info.textContent = `${(p.n || n).toLocaleString()} Points${p.total && p.total > p.n ? ` Of ${p.total.toLocaleString()}` : ''}${p.path ? ' · Orange: Camera Path' : ''} · ${labels}`;
    // frame the cloud only the first time: afterwards the user's view is kept, so it
    // can be moved while the data updates (playback, scrubbing); Reset View frames again
    if (!this._framed) this.frameAll();
    this._framed = true;
  }
  frameAll() {
    if (!this.box) return; const c = this.box.getCenter(new THREE.Vector3()), r = this.box.getSize(new THREE.Vector3()).length() / 2 || 1;
    this.controls.target.copy(c);
    if (this.image) this.camera.position.set(c.x + r * 0.9, c.y + r * 0.5, c.z + r * 1.6);
    else this.camera.position.set(c.x + r * 1.4, c.y + r * 0.9, c.z + r * 1.4);
    this.camera.near = r / 1000; this.camera.far = r * 100; this.camera.updateProjectionMatrix();
  }
  look(i) {
    if (!this.box) return; const c = this.box.getCenter(new THREE.Vector3()), r = this.box.getSize(new THREE.Vector3()).length() / 2 || 1;
    const d = [[0, r * 2.2, 0.001], [0, 0, r * 2.2], [r * 2.2, 0, 0]][i];
    this.controls.target.copy(c); this.camera.position.set(c.x + d[0], c.y + d[1], c.z + d[2]);
  }
}

// ====================== SeriesView ======================
export class SeriesView {
  constructor(host) {
    this.host = host; this.wrap = el('div', { class: 'series-wrap' }); host.append(this.wrap);
    this.ro = new ResizeObserver(() => this._redraw()); this.ro.observe(host);
    this.plots = [];
  }
  destroy() { this.ro.disconnect(); this.wrap.remove(); }
  setGroups(groups, extra) {
    this.wrap.innerHTML = ''; this.plots = [];
    for (const g of groups) {
      const keys = el('span', { class: 'keys' });
      g.ys.forEach((y, i) => keys.append(el('span', {}, el('i', { style: `display:inline-block;width:10px;height:3px;border-radius:2px;margin-right:5px;vertical-align:3px;background:${COLORS[i % COLORS.length]}` }), tc(y.name))));
      const box = el('div', { class: 'series-plot', title: 'Hover for values' }, el('h4', {}, tc(g.title || ''), keys));
      const cv = el('canvas'); const tip = el('div', { class: 'series-tip', hidden: true });
      box.append(cv, tip); this.wrap.append(box);
      const plot = { g, cv, tip, box };
      cv.addEventListener('mousemove', e => this._hover(plot, e)); cv.addEventListener('mouseleave', () => { tip.hidden = true; this._draw(plot); });
      this.plots.push(plot);
    }
    if (extra) this.wrap.append(extra);
    this._redraw();
  }
  _redraw() { for (const p of this.plots) this._draw(p); }
  _scale(p) {
    const x = p.g.x.map(Number); let lo = Infinity, hi = -Infinity;
    for (const y of p.g.ys) for (const v of [].concat(y.data)) if (v != null && isFinite(v)) { lo = Math.min(lo, v); hi = Math.max(hi, v); }
    if (!isFinite(lo)) { lo = 0; hi = 1; } if (lo === hi) { lo -= 1; hi += 1; }
    const pad = (hi - lo) * 0.06; return { x, x0: Math.min(...x), x1: Math.max(...x), y0: lo - pad, y1: hi + pad };
  }
  _draw(p, hoverI) {
    const cv = p.cv, dpr = window.devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
    if (!W) return; cv.width = W * dpr; cv.height = H * dpr;
    const c = cv.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0); c.clearRect(0, 0, W, H);
    const s = this._scale(p); p.s = s; const L = 58, R = 10, T = 6, B = 24; p.box_ = { L, R, T, B, W, H };
    const X = v => L + (v - s.x0) / ((s.x1 - s.x0) || 1) * (W - L - R), Y = v => T + (1 - (v - s.y0) / (s.y1 - s.y0)) * (H - T - B);
    c.font = '11px ui-monospace, monospace'; c.fillStyle = '#8b93a3'; c.strokeStyle = '#1e232c'; c.lineWidth = 1;
    for (const v of ticks(s.y0, s.y1, 5)) { const y = Y(v); c.beginPath(); c.moveTo(L, y); c.lineTo(W - R, y); c.stroke(); c.textAlign = 'right'; c.fillText(fmtNum(v, 3), L - 6, y + 4); }
    for (const v of ticks(s.x0, s.x1, 8)) { const x = X(v); c.beginPath(); c.moveTo(x, T); c.lineTo(x, H - B); c.stroke(); c.textAlign = 'center'; c.fillText(fmtNum(v, 3), x, H - 8); }
    c.textAlign = 'left'; c.fillStyle = '#5c6372'; c.fillText(p.g.xlabel || '', W - R - c.measureText(p.g.xlabel || '').width, H - B - 4);
    if (p.g.ylabel) { c.save(); c.translate(11, T + 4); c.fillText(p.g.ylabel, 0, 8); c.restore(); }
    p.g.ys.forEach((y, i) => {
      const d = [].concat(y.data); c.strokeStyle = COLORS[i % COLORS.length]; c.lineWidth = 1.4; c.beginPath(); let pen = false;
      for (let k = 0; k < d.length; k++) { const v = d[k]; if (v == null || !isFinite(v)) { pen = false; continue; } const px = X(s.x[k]), py = Y(v); if (pen) c.lineTo(px, py); else { c.moveTo(px, py); pen = true; } }
      c.stroke();
    });
    if (hoverI != null) { const x = X(s.x[hoverI]); c.strokeStyle = '#6a7385'; c.setLineDash([3, 3]); c.beginPath(); c.moveTo(x, T); c.lineTo(x, H - B); c.stroke(); c.setLineDash([]); }
  }
  _hover(p, e) {
    if (!p.s) return; const r = p.cv.getBoundingClientRect(), mx = e.clientX - r.left; const { L, R, W } = p.box_;
    const xv = p.s.x0 + (mx - L) / (W - L - R) * (p.s.x1 - p.s.x0);
    let best = 0, bd = Infinity; p.s.x.forEach((v, i) => { const d = Math.abs(v - xv); if (d < bd) { bd = d; best = i; } });
    this._draw(p, best);
    p.tip.hidden = false; p.tip.innerHTML = `${esc2(p.g.xlabel || 'x')} ${fmtNum(p.s.x[best], 4)}<br>` + p.g.ys.map((y, i) => `<span style="color:${COLORS[i % COLORS.length]}">●</span> ${esc2(tc(y.name))} ${fmtNum([].concat(y.data)[best], 4)}`).join('<br>');
    p.tip.style.left = Math.min(mx + 14, W - 180) + 'px'; p.tip.style.top = '28px';
  }
}
const esc2 = s => String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
function ticks(a, b, n) {
  const span = b - a; if (!(span > 0)) return [a]; const step0 = span / n, mag = 10 ** Math.floor(Math.log10(step0));
  const step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(s => s >= step0) || step0; const out = [];
  for (let v = Math.ceil(a / step) * step; v <= b + 1e-12; v += step) out.push(+v.toFixed(12)); return out;
}

// ====================== one host, any payload ======================
export class AnyView {
  constructor(host) { this.host = host; this.view = null; this.kind = null; }
  clear() { this.view?.destroy(); this.view = null; this.kind = null; }
  ensure(kind, Cls) { if (this.kind !== kind) { this.clear(); this.view = new Cls(this.host); this.kind = kind; } return this.view; }
  show(p) {
    if (p.kind === 'frame') {
      const v = this.ensure('frame', FrameView); v.setOverlay(null); v.setImage(b64bytes(p.rgba), p.w, p.h);
      v.setLegend(p.mode === 'polarity' ? '<span><i style="background:#4c8dff"></i>ON</span><span><i style="background:#f0545a"></i>OFF</span>' : p.legend ? esc2(tc(p.legend)) : '');
    } else if (p.kind === 'points') {
      const v = this.ensure('points', PointsView); v.setPoints(p);
    } else if (p.kind === 'series') {
      const v = this.ensure('series', SeriesView);
      let extra = null;
      if (p.image) { extra = el('div', { class: 'series-plot' }, el('h4', {}, 'Votes Per Attempt (Rows) And Scale (Columns)')); const cv = el('canvas', { style: 'width:100%;height:auto;image-rendering:pixelated' }); cv.width = p.image.w; cv.height = p.image.h; cv.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(b64bytes(p.image.rgba).buffer), p.image.w, p.image.h), 0, 0); extra.append(cv); }
      v.setGroups(p.groups, extra);
    } else if (p.kind === 'lines') {
      const v = this.ensure('frame', FrameView);
      if (p.background) v.setImage(dim(b64bytes(p.background)), p.w, p.h); else v.setSize(p.w, p.h);
      v.setLegend(`${p.shown} Of ${p.n} Tracks In The Window · Each Colour One Track`);
      v.setOverlay((c, T, z) => {
        c.lineWidth = Math.max(1, Math.min(2.2, z)); c.lineJoin = 'round';
        p.lines.forEach((ln, i) => {
          if (ln.length < 2) return; c.strokeStyle = `hsl(${(p.hue[i] * 360).toFixed(0)},85%,62%)`; c.beginPath();
          for (let k = 0; k < ln.length; k += 2) { const [x, y] = T(ln[k], ln[k + 1]); k ? c.lineTo(x, y) : c.moveTo(x, y); }
          c.stroke(); const [x, y] = T(ln[ln.length - 2], ln[ln.length - 1]); c.fillStyle = c.strokeStyle; c.fillRect(x - 1.5, y - 1.5, 3, 3);
        });
      });
    }
  }
}
function dim(bytes) { const a = new Uint8ClampedArray(bytes.buffer); for (let i = 0; i < a.length; i += 4) { a[i] *= .45; a[i + 1] *= .45; a[i + 2] *= .45; } return a; }
