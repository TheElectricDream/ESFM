// A MATLAB variable's view with its controls: time window, mode and smooth playback
// for events and tracks. Requests are coalesced: while one view is being built in
// MATLAB, further changes collapse into one request with the latest settings.
import { api, el, fail, fmtNum, latest, tc } from './app.js';
import { AnyView } from './viewers.js';

const LABELS = { frame: 'Frame', cloud3d: '3-D Events', rate: 'Rate', trajectory: 'Trajectory', landmarks: 'Cloud', tracks: 'Tracks', log: 'Loop Log', votes: 'Votes', series: 'Plot', image: 'Image' };
export const viewLabel = k => LABELS[k] || tc(k);
const MODE_TIPS = { polarity: 'ON events blue, OFF red', count: 'Events per pixel, log scale', accepted: 'Accepted events coloured by flow direction, rejected grey', flow: 'Accepted events only, coloured by their normal-flow direction' };

export class ViewPanel {
  constructor(ctlHost, viewHost, metaEl) {
    this.ctl = ctlHost; this.host = viewHost; this.meta = metaEl; this.any = new AnyView(viewHost);
    this.opts = {}; this.expr = null; this.kind = null; this.seq = 0;
    this.playing = false; this.speed = 1; this.last = null;
    this.fetch = latest(() => this.load());
    this.reload = () => this.fetch();
  }
  clear() { this.stop(); this.any.clear(); this.ctl.hidden = true; this.ctl.innerHTML = ''; if (this.meta) this.meta.textContent = ''; this.expr = null; this.last = null; }
  async open(expr, kind, keep = false) {
    this.stop();
    if (!keep || expr !== this.expr || kind !== this.kind) { this.opts = {}; this.last = null; }
    this.expr = expr; this.kind = kind; await this.load();
  }
  async load() {
    if (!this.expr) return;
    const seq = ++this.seq;
    if (this.meta && !this.playing) this.meta.textContent = 'Asking MATLAB…';
    try {
      const p = await api.post('/api/matlab/view', { expr: this.expr, kind: this.kind, opts: this.opts });
      if (seq !== this.seq) return;
      this.any.show(p);
      const sig = JSON.stringify([p.kind, p.modes, p.mode, p.t_range, p.space]);
      if (sig !== this.ctlSig) { this.controls(p); this.ctlSig = sig; } else this.sync(p);
      this.last = p;
      if (this.meta) this.meta.textContent = this.metaText(p);
    } catch (e) { this.stop(); if (seq === this.seq) { fail(e, `View ${this.expr}`); if (this.meta) this.meta.textContent = ''; } }
  }
  metaText(p) {
    if (p.kind === 'frame' && p.count != null) return `${this.expr} · ${p.count.toLocaleString()} events in ${fmtNum(p.dt * 1000, 1)} ms from ${fmtNum(p.t0, 3)} s`;
    if (p.kind === 'points') return `${this.expr} · ${p.n.toLocaleString()} points` + (p.t0 != null ? ` from ${fmtNum(p.t0, 3)} s` : '');
    if (p.kind === 'lines') return `${this.expr} · ${p.n} tracks between ${fmtNum(p.t0, 2)} and ${fmtNum(p.t0 + p.dt, 2)} s`;
    if (p.meta) return `${this.expr} · ` + Object.entries(p.meta).map(([k, v]) => `${tc(k.replace(/_/g, ' '))} ${Array.isArray(v) ? v.map(x => fmtNum(x, 4)).join(' ') : fmtNum(v, 4)}`).join(' · ');
    return this.expr;
  }
  timed(p) { return p.t_range && (p.kind === 'frame' || p.kind === 'points' || p.kind === 'lines'); }
  controls(p) {
    const c = this.ctl; c.innerHTML = ''; this.w = {};
    const modes = p.modes || (p.kind === 'points' && p.space === 'image' ? ['polarity', 'accepted', 'flow'] : null);
    if (modes) {
      const seg = el('div', { class: 'segmented sm', title: 'What the events are coloured by' });
      const cur = p.mode || this.opts.mode || 'polarity';
      for (const m of modes) seg.append(el('button', { class: m === cur ? 'active' : '', text: tc(m), title: MODE_TIPS[m] || m,
        onclick: e => { this.opts.mode = m; [...seg.children].forEach(b => b.classList.toggle('active', b === e.target)); this.fetch(); } }));
      c.append(seg);
    }
    if (this.timed(p)) {
      const [a, b] = p.t_range; const t0 = p.t0 ?? a, dt = p.dt ?? 1;
      const unit = p.kind === 'lines' ? 1 : 1000;
      const play = el('button', { class: 'btn btn-xs', text: '▶ Play', title: 'Play the window smoothly through the data (MATLAB builds each view; the next is asked for as soon as one arrives)', onclick: () => this.playing ? this.stop() : this.play() });
      const speeds = el('div', { class: 'segmented sm', title: 'Playback speed relative to real time' });
      for (const v of [0.25, 1, 4, 16]) speeds.append(el('button', { class: v === this.speed ? 'active' : '', text: `${v === 0.25 ? '¼' : v}×`, title: `${v}× real time`,
        onclick: e => { this.speed = v; [...speeds.children].forEach(x => x.classList.toggle('active', x === e.target)); } }));
      const slider = el('input', { type: 'range', min: a, max: b, step: (b - a) / 4000, value: t0, style: 'flex:1;min-width:160px', title: 'Drag to scrub through the data' });
      const t0in = el('input', { class: 'input sm mono', type: 'number', step: '0.01', value: (+t0).toFixed(3), style: 'width:100px', title: 'Window start [s]' });
      const dtin = el('input', { class: 'input sm mono', type: 'number', step: unit === 1 ? '0.5' : '5', value: +(dt * unit).toFixed(3), style: 'width:80px', title: unit === 1 ? 'Window length [s]' : 'Window length [ms]' });
      this.w = { slider, t0in, dtin, play, a, b, unit };
      slider.oninput = () => this.setT0(+slider.value);
      t0in.onchange = () => this.setT0(+t0in.value);
      dtin.onchange = () => { this.opts.dt = Math.max(1e-3, +dtin.value / unit); this.fetch(); };
      const step = s => el('button', { class: 'btn btn-xs', text: s > 0 ? '▶|' : '|◀', title: s > 0 ? 'Next window' : 'Previous window', onclick: () => this.setT0((this.opts.t0 ?? t0) + s * (this.opts.dt ?? dt)) });
      c.append(play, speeds, step(-1), slider, step(1), el('span', { class: 'muted small', text: 'T₀ [s]' }), t0in,
        el('span', { class: 'muted small', text: unit === 1 ? 'Window [s]' : 'Window [ms]' }), dtin);
    }
    c.hidden = !c.childElementCount;
  }
  sync(p) { if (this.w?.slider && p.t0 != null && !this.dragging) { this.w.slider.value = p.t0; this.w.t0in.value = (+p.t0).toFixed(3); } }
  setT0(v) {
    const { a, b } = this.w; this.opts.t0 = Math.min(b, Math.max(a, v));
    this.w.slider.value = this.opts.t0; this.w.t0in.value = this.opts.t0.toFixed(3); this.fetch();
  }
  play() {
    if (!this.w?.slider) return; this.playing = true; this.w.play.textContent = '❚❚ Pause';
    let lastT = performance.now();
    const tick = async () => {
      if (!this.playing) return;
      const now = performance.now(), adv = (now - lastT) / 1000 * this.speed; lastT = now;
      const dt = this.opts.dt ?? this.last?.dt ?? 0.05;
      let t = (this.opts.t0 ?? this.last?.t0 ?? this.w.a) + adv;
      if (t > this.w.b - dt) t = this.w.a;
      this.opts.t0 = t; this.w.slider.value = t; this.w.t0in.value = t.toFixed(3);
      await this.load();
      if (this.playing) requestAnimationFrame(tick);
    };
    tick();
  }
  stop() { this.playing = false; if (this.w?.play) this.w.play.textContent = '▶ Play'; }
}
