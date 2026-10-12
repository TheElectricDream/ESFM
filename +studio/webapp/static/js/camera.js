// Camera page: read, edit and save the intrinsics; see what the lens model does.
import { $, $$, api, busyButton, chooseFile, el, fail, fmtNum, latest, on, refreshState, state, toast } from './app.js';
import { FrameView } from './viewers.js';

let view, cur = null, orig = null, bg = 'none', bgImg = null, files = [], active = '';

export async function init() {
  view = new FrameView($('#calViewer'));
  $('#calFile').onchange = () => load($('#calFile').value);
  $$('[data-k]', $('#page-camera')).forEach(i => i.oninput = edited);
  $('#calRevert').onclick = () => { if (orig) fill(orig); };
  $('#calSave').onclick = () => save();
  $('#calSaveAs').onclick = () => { const n = prompt('New calibration file name (.xml):', (cur?.file || 'calibration.xml').replace(/\.xml$/, '_edited.xml')); if (n) save(n); };
  $('#calUse').onclick = () => busyButton($('#calUse'), async () => { try { await api.post('/api/calib/use', { name: $('#calFile').value }); await refreshList(); toast('The pipeline now uses ' + $('#calFile').value + '. Steps from Undistort on will rerun.', 'ok'); } catch (e) { fail(e); } });
  $$('#calBg button').forEach(b => b.onclick = () => { bg = b.dataset.v; $$('#calBg button').forEach(x => x.classList.toggle('active', x === b)); framePicker(); loadBg(); });
  const pick = () => { syncFrameSlider(); loadBg(); };
  $('#calT0').oninput = pick; $('#calDt').oninput = pick;
  $('#calT0Slider').oninput = () => { if (!state.recording) return; $('#calT0').value = (+$('#calT0Slider').value / 1000 * state.recording.duration_s).toFixed(2); loadBg(); };
  on('recording', () => { if (bg === 'data') { framePicker(); loadBg(); } });
  $('#calUndist').onchange = draw;
  await refreshList();
}
export function show() { framePicker(); if (bg !== 'none') loadBg(); }

// Data Frame: any frame of the open recording, chosen with the slider or the time
function framePicker() {
  const box = $('#calFramePick'); box.hidden = bg !== 'data';
  if (bg !== 'data') return;
  const r = state.recording, hint = $('#calFrameHint');
  $('#calT0Slider').disabled = $('#calT0').disabled = $('#calDt').disabled = !r;
  hint.innerHTML = '';
  if (!r) {
    hint.append('No recording is open. ', el('button', { class: 'btn btn-xs', text: 'Open One…', title: 'Pick a recording; it opens on the Data page too',
      onclick: async () => { const p = await chooseFile(); if (p) api.post('/api/data/open', { path: p }).catch(fail); } }));
    return;
  }
  hint.textContent = `${r.name}, 0 – ${r.duration_s.toFixed(1)} s`;
  if (+$('#calT0').value > r.duration_s) $('#calT0').value = (r.duration_s / 2).toFixed(2);
  syncFrameSlider();
}
function syncFrameSlider() { if (state.recording) $('#calT0Slider').value = Math.round(+$('#calT0').value / state.recording.duration_s * 1000); }

async function refreshList() {
  const r = await api.get('/api/calib'); files = r.files; active = r.active;
  const s = $('#calFile'); s.innerHTML = '';
  for (const f of files) s.append(el('option', { value: f, text: f + (f === active ? '  (pipeline)' : '') }));
  s.value = cur?.file && files.includes(cur.file) ? cur.file : active;
  $('#calPill').textContent = r.overridden ? 'Override' : 'config.m'; $('#calPill').className = 'pill' + (r.overridden ? ' warn' : '');
  if (s.value) await load(s.value);
}
async function load(name) {
  try { orig = await api.get('/api/calib/file?name=' + encodeURIComponent(name)); fill(orig); }
  catch (e) { fail(e); }
}
function fill(c) {
  cur = JSON.parse(JSON.stringify(c));
  for (const i of $$('[data-k]', $('#page-camera'))) { i.value = c[i.dataset.k]; i.classList.remove('changed'); }
  const d = $('#calDist'); d.innerHTML = '';
  c.dist.forEach((v, k) => {
    const i = el('input', { class: 'input mono', type: 'number', step: '0.0001', value: v, 'data-d': k }); i.oninput = edited;
    d.append(el('label', { class: 'field', title: k > 1 ? `k${k + 1}: kept in the file, not used by the pipeline` : `k${k + 1}: equidistant distortion coefficient (θ_d = θ(1 + k1 θ² + k2 θ⁴ …))` },
      el('span', { class: 'field-label', text: `k${k + 1}` + (k > 1 ? ' (Unused)' : '') }), i));
  });
  $('#calModel').textContent = c.fisheye ? 'Fisheye (Equidistant)' : 'Pinhole';
  const m = $('#calMeta'); m.innerHTML = '';
  for (const [k, v, tip] of [['Camera', c.camera, 'Camera named in the file'], ['Reprojection Error', c.error_px ? `${(+c.error_px).toFixed(3)} px` : '–', 'RMS error of the calibration'],
    ['Calibrated', c.time || '–', 'When the calibration was made'], ['Pattern', c.pattern || '–', 'Calibration target'], ['Used By Pipeline', c.file === active ? 'Yes' : 'No', 'Whether the pipeline reads this file']])
    m.append(el('dt', { text: k, title: tip }), el('dd', { text: v, title: tip }));
  view.setSize(c.width, c.height); draw();
}
function edited() {
  if (!cur) return;
  for (const i of $$('[data-k]', $('#page-camera'))) { cur[i.dataset.k] = +i.value; i.classList.toggle('changed', +i.value !== +orig[i.dataset.k]); }
  for (const i of $$('[data-d]', $('#page-camera'))) { cur.dist[+i.dataset.d] = +i.value; i.classList.toggle('changed', +i.value !== orig.dist[+i.dataset.d]); }
  draw();
}
async function save(saveAs) {
  try {
    const r = await api.post('/api/calib/save', { name: orig.file, values: { fx: cur.fx, fy: cur.fy, cx: cur.cx, cy: cur.cy, width: cur.width, height: cur.height, dist: cur.dist }, save_as: saveAs || null });
    toast(`Saved ${r.saved}` + (r.backup ? ` (backup in ${r.backup})` : ''), 'ok'); cur = null; await refreshList(); $('#calFile').value = r.saved; await load(r.saved);
  } catch (e) { fail(e); }
}

// ---- lens model: equidistant (Kannala-Brandt) ----
function distort(xu, yu, c) {       // ideal pinhole normalised -> distorted pixel
  const r = Math.hypot(xu, yu); if (r < 1e-12) return [c.cx, c.cy];
  const th = Math.atan(r), t2 = th * th; const k = c.dist;
  const thd = th * (1 + (k[0] || 0) * t2 + (k[1] || 0) * t2 * t2 + (k[2] || 0) * t2 ** 3 + (k[3] || 0) * t2 ** 4);
  const s = thd / r; return [c.fx * xu * s + c.cx, c.fy * yu * s + c.cy];
}
const loadBg = latest(async () => {
  try {
    if (bg === 'none') bgImg = null;
    if (bg === 'data') {
      if (!state.recording) { bgImg = null; draw(); return; }
      const t0 = +$('#calT0').value || 0, dt = Math.max(1, +$('#calDt').value || 200) / 1000;
      const r = await api.bin(`/api/data/frame?t0=${t0}&dt=${dt}&mode=polarity`); bgImg = { data: r.data, w: +r.headers['x-w'], h: +r.headers['x-h'] };
    }
    if (bg === 'live') { const r = await api.bin('/api/live/frame?window=200&mode=polarity'); bgImg = { data: r.data, w: +r.headers['x-w'], h: +r.headers['x-h'] }; }
  } catch (e) { bgImg = null; fail(e); }
  draw();
});
function draw() {
  if (!cur) return; const c = cur, w = c.width, h = c.height, und = $('#calUndist').checked;
  // background: raw frame, or remapped through the model (each ideal pixel samples where the lens put it)
  const img = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < w * h; i++) { img[4 * i] = 11; img[4 * i + 1] = 13; img[4 * i + 2] = 17; img[4 * i + 3] = 255; }
  if (bgImg && bgImg.w === w && bgImg.h === h) {
    if (!und) img.set(bgImg.data);
    else for (let v = 0; v < h; v++) for (let u = 0; u < w; u++) {
      const [x, y] = distort((u - c.cx) / c.fx, (v - c.cy) / c.fy, c); const xi = Math.round(x), yi = Math.round(y);
      if (xi < 0 || yi < 0 || xi >= w || yi >= h) continue; const s = 4 * (yi * w + xi), d = 4 * (v * w + u);
      img[d] = bgImg.data[s]; img[d + 1] = bgImg.data[s + 1]; img[d + 2] = bgImg.data[s + 2];
    }
  }
  view.setImage(img, w, h);
  let maxShift = 0;
  for (const [u, v] of [[0, 0], [w, 0], [0, h], [w, h]]) { const [x, y] = distort((u - c.cx) / c.fx, (v - c.cy) / c.fy, c); maxShift = Math.max(maxShift, Math.hypot(x - u, y - v)); }
  $('#calSummary').textContent = `fx ${fmtNum(c.fx, 2)} · fy ${fmtNum(c.fy, 2)} · c (${fmtNum(c.cx, 1)}, ${fmtNum(c.cy, 1)}) · k1 ${fmtNum(c.dist[0], 5)} · Corner Shift ${maxShift.toFixed(2)} px · Horizontal FOV ${(2 * Math.atan(Math.max(c.cx, w - c.cx) / c.fx) * 180 / Math.PI).toFixed(1)}°`;
  view.setLegend((und ? 'Undistorted Image: Grid Lines Are Straight' : 'Raw Image: The Grid Shows Where Straight Lines Land Through The Lens')
    + (bg === 'data' && state.recording ? ` · Frame At ${(+$('#calT0').value).toFixed(2)} s` : ''));
  view.setOverlay((g, T) => {
    g.lineWidth = 1; const step = 40;
    const line = pts => { g.beginPath(); pts.forEach(([x, y], i) => { const [X, Y] = T(x, y); i ? g.lineTo(X, Y) : g.moveTo(X, Y); }); g.stroke(); };
    g.strokeStyle = 'rgba(76,141,255,.55)';
    for (let u = 0; u <= w; u += step) { const pts = []; for (let v = 0; v <= h; v += 8) pts.push(und ? [u, v] : distort((u - c.cx) / c.fx, (v - c.cy) / c.fy, c)); line(pts); }
    for (let v = 0; v <= h; v += step) { const pts = []; for (let u = 0; u <= w; u += 8) pts.push(und ? [u, v] : distort((u - c.cx) / c.fx, (v - c.cy) / c.fy, c)); line(pts); }
    g.strokeStyle = '#f5a524'; g.lineWidth = 1.5; const [px, py] = T(c.cx, c.cy);
    g.beginPath(); g.moveTo(px - 12, py); g.lineTo(px + 12, py); g.moveTo(px, py - 12); g.lineTo(px, py + 12); g.stroke();
    g.fillStyle = '#f5a524'; g.font = '11px ui-monospace, Menlo, Consolas, monospace'; g.fillText('Principal Point', px + 8, py - 8);
    g.strokeStyle = 'rgba(255,255,255,.25)'; const [qx, qy] = T(w / 2, h / 2); g.beginPath(); g.arc(qx, qy, 4, 0, 7); g.stroke();
  });
}
