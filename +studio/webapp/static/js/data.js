// Data page: open AEDAT4 / HDF5 recordings, look at them, convert them, hand them to the pipeline.
import { $, $$, api, busyButton, chooseFile, el, fail, fmtInt, fmtNum, latest, on, state, tc, toast } from './app.js';
import { AnyView, FrameView } from './viewers.js';

let any, mode = 'polarity', cloudColor = 'polarity', rate = null, playing = false, speed = 1, pipeWin = null;
const T0 = () => +$('#dataT0').value || 0, DT = () => Math.max(0.001, (+$('#dataDt').value || 50) / 1000);
const render = latest(draw);          // at most one request in flight; the latest settings win

export function init() {
  any = new AnyView($('#dataViewer'));
  $('#dataBrowse').onclick = $('#dataEmptyBrowse').onclick = async () => { const p = await chooseFile({ start: $('#dataPath').value }); if (p) { $('#dataPath').value = p; openRec(); } };
  $('#dataOpen').onclick = openRec;
  $('#dataClose').onclick = () => api.post('/api/data/close').catch(fail);
  $('#dataPath').onkeydown = e => { if (e.key === 'Enter') openRec(); };
  $$('#dataMode button').forEach(b => b.onclick = () => { mode = b.dataset.mode; $$('#dataMode button').forEach(x => x.classList.toggle('active', x === b)); updateRows(); render(); });
  $$('#dataCloudColor button').forEach(b => b.onclick = () => { cloudColor = b.dataset.v; $$('#dataCloudColor button').forEach(x => x.classList.toggle('active', x === b)); render(); });
  $$('#dataSpeed button').forEach(b => b.onclick = () => { speed = +b.dataset.v; $$('#dataSpeed button').forEach(x => x.classList.toggle('active', x === b)); });
  $('#dataT0').oninput = () => { syncSlider(); drawTimeline(); render(); };
  $('#dataDt').oninput = () => { drawTimeline(); render(); };
  $('#dataTau').oninput = () => render(); $('#dataUndist').onchange = () => render();
  $('#dataT0Slider').oninput = () => { if (!state.recording) return; setT0(+$('#dataT0Slider').value / 1000 * state.recording.duration_s); };
  $('#dataPlay').onclick = togglePlay;
  scrubbing($('#dataTimeline'));
  new ResizeObserver(() => drawTimeline()).observe($('#dataTimeline'));
  $('#convBtn').onclick = convert;
  $('#useBtn').onclick = useInPipeline;
  on('recording', d => {
    const pr = $('#dataProgress');
    if (d.loading) { pr.hidden = false; pr.firstElementChild.style.width = (100 * d.loading.fraction) + '%'; $('#dataPill').className = 'pill busy'; $('#dataPill').textContent = `Loading ${fmtInt(d.loading.events)}`; }
    else pr.hidden = true;
    if (d.error) { $('#dataPill').className = 'pill err'; $('#dataPill').textContent = 'Error'; toast(d.error, 'err'); }
    if (d.summary) loaded(d.summary);
    if (d.closed) closed();
  });
  on('convert', d => {
    const pr = $('#convProgress'); pr.hidden = d.state !== 'running'; pr.firstElementChild.style.width = (100 * (d.fraction || 0)) + '%';
    if (d.state === 'done') { toast(`Converted: ${d.out}`, 'ok'); $('#convBtn').disabled = false; $('#useHint').textContent = 'Converted. Use In Pipeline makes it the pipeline\'s input.'; }
    if (d.state === 'error') { $('#convBtn').disabled = false; }
  });
  on('config', loadPipeWindow);
  if (state.recording) { $('#dataPath').value = state.recording.path; loaded(state.recording); }
  else $('#dataPath').value = localStorage.getItem('studio.dataPath') || '';
  loadPipeWindow();
}
export function show() { if (any.view) any.view.draw?.(); }
export function hide() { if (playing) togglePlay(); }
export const currentT0 = () => T0();

function updateRows() { $('#dataTauRow').hidden = mode !== 'timesurface'; $('#dataCloudRow').hidden = mode !== 'cloud'; }
function syncSlider() { if (state.recording) $('#dataT0Slider').value = Math.round(T0() / state.recording.duration_s * 1000); }
function setT0(t) {
  if (!state.recording) return;
  t = Math.max(0, Math.min(state.recording.duration_s - DT(), t));
  $('#dataT0').value = t.toFixed(3); syncSlider(); drawTimeline(); render();
}

// timeline: click to jump, drag to scrub (the window follows the pointer)
function scrubbing(host) {
  const at = e => { const b = host.getBoundingClientRect(); return Math.max(0, Math.min(1, (e.clientX - b.left) / b.width)) * (state.recording?.duration_s || 0); };
  const label = $('#dataTlHover');
  host.addEventListener('pointerdown', e => {
    if (!state.recording) return;
    host.setPointerCapture(e.pointerId); host.classList.add('dragging');
    const move = ev => { setT0(at(ev) - DT() / 2); hover(ev); };
    const up = () => { host.classList.remove('dragging'); host.removeEventListener('pointermove', move); host.removeEventListener('pointerup', up); };
    host.addEventListener('pointermove', move); host.addEventListener('pointerup', up);
    move(e);
  });
  const hover = e => { if (!state.recording) return; const b = host.getBoundingClientRect(); label.hidden = false; label.style.left = (e.clientX - b.left) + 'px'; label.textContent = `${at(e).toFixed(2)} s`; };
  host.addEventListener('pointermove', hover);
  host.addEventListener('pointerleave', () => { label.hidden = true; });
}

async function openRec() {
  const p = $('#dataPath').value.trim(); if (!p) return;
  localStorage.setItem('studio.dataPath', p);
  try { await api.post('/api/data/open', { path: p }); } catch (e) { fail(e); }
}

async function loaded(s) {
  state.recording = s;
  $('#dataEmpty').hidden = true; $('#dataTimeline').hidden = false; $('#dataClose').hidden = false;
  $('#dataPill').className = 'pill ok'; $('#dataPill').textContent = s.kind.toUpperCase();
  $('#dataTitle').textContent = s.name;
  $('#dataPath').value = s.path;
  const kv = $('#dataSummary'); kv.hidden = false; kv.innerHTML = '';
  for (const [k, v, tip] of [['Camera', s.camera || '–', 'Camera that recorded it'], ['Resolution', `${s.width} × ${s.height}`, 'Sensor size [px]'],
    ['Events', fmtInt(s.events), 'Events in the recording'], ['Duration', `${s.duration_s.toFixed(2)} s`, 'First to last event'],
    ['Mean Rate', `${(s.rate_mev_s * 1000).toFixed(1)} kev/s`, 'Events per second on average'], ['ON Fraction', `${(100 * s.on_fraction).toFixed(1)} %`, 'Share of ON (brightness increase) events'],
    ['File', `${s.size_mb.toFixed(1)} MB`, 'Size on disk'], ['In Memory', `${s.memory_mb.toFixed(0)} MB`, 'Memory the Studio uses for it (Close frees it)']])
    kv.append(el('dt', { text: k, title: tip }), el('dd', { text: v, title: tip }));
  $('#convOut').value = s.kind === 'aedat4' ? `${homeDir()}/esfm_work/hdf5/${s.name.replace(/\.aedat4$/i, '')}.hdf5` : s.path;
  $('#convBtn').disabled = s.kind !== 'aedat4';
  $('#convBtn').title = s.kind === 'aedat4' ? 'Write the open AEDAT4 recording to the HDF5 file above in the pipeline\'s format (all events, timestamps kept). Needed once per recording.'
    : 'This recording is already HDF5: Use In Pipeline can take it directly';
  $('#useHint').textContent = s.kind === 'aedat4' ? 'Convert first: the pipeline reads HDF5.' : '';
  if (T0() > s.duration_s || T0() === 0) $('#dataT0').value = Math.min(s.duration_s / 2, 100).toFixed(3);
  syncSlider();
  try { rate = await api.get('/api/data/rate?bins=1200'); } catch (e) { rate = null; }
  drawTimeline(); render();
}
function closed() {
  state.recording = null; rate = null; any.clear(); $('#dataEmpty').hidden = false; $('#dataTimeline').hidden = true;
  $('#dataPill').className = 'pill'; $('#dataPill').textContent = 'None'; $('#dataSummary').hidden = true; $('#dataClose').hidden = true;
  $('#dataTitle').textContent = 'No Recording'; $('#dataMeta').textContent = ''; $('#dataCount').textContent = '';
}
function homeDir() { const m = (state.project || '').match(/^\/home\/[^/]+/); return m ? m[0] : '~'; }

async function draw() {
  if (!state.recording) return;
  const t0 = T0(), dt = DT(), und = $('#dataUndist').checked ? 1 : 0;
  try {
    if (mode === 'cloud') {
      const p = await api.get(`/api/data/cloud?t0=${t0}&dt=${dt}&n=80000&color=${cloudColor}&undistort=${und}`);
      any.show(p); $('#dataCount').textContent = `${fmtInt(p.total)} events`; $('#dataMeta').textContent = `${fmtNum(t0, 3)} s + ${fmtNum(dt * 1000, 1)} ms · 3-D (x, y, t)`; $('#dataHotInfo').textContent = '';
      return;
    }
    const url = mode === 'hot' ? '/api/data/hot' : `/api/data/frame?t0=${t0}&dt=${dt}&mode=${mode}&undistort=${und}&tau=${(+$('#dataTau').value || 30) / 1000}`;
    const r = await api.bin(url);
    const v = any.ensure('frame', FrameView); v.setOverlay(null);
    v.setImage(r.data, +r.headers['x-w'], +r.headers['x-h']);
    if (mode === 'hot') {
      const info = JSON.parse(r.headers['x-info']);
      v.setLegend(`Events Per Pixel Over The Whole Recording (Log) · Median ${info.median_rate_hz} Hz · ${fmtInt(info.active_pixels)} Active Pixels`);
      $('#dataHotInfo').innerHTML = 'Hottest: ' + info.top.slice(0, 5).map(h => `(${h.x}, ${h.y}) ${h.rate_hz} Hz`).join(' · ');
      $('#dataMeta').textContent = 'Whole Recording'; $('#dataCount').textContent = '';
      v.setOverlay((c, T) => { c.strokeStyle = '#f5a524'; c.lineWidth = 1.5; info.top.slice(0, 10).forEach(h => { const [x, y] = T(h.x + .5, h.y + .5); c.beginPath(); c.arc(x, y, 7, 0, 7); c.stroke(); }); });
    } else {
      $('#dataHotInfo').textContent = '';
      v.setLegend(mode === 'count' ? 'Events Per Pixel (Log)' : '<span><i style="background:#4c8dff"></i>ON</span><span><i style="background:#f0545a"></i>OFF</span>' + (mode === 'timesurface' ? '<span>Brightness: Recency</span>' : ''));
      $('#dataCount').textContent = `${fmtInt(+r.headers['x-count'])} events`;
      $('#dataMeta').textContent = `${fmtNum(t0, 3)} s + ${fmtNum(dt * 1000, 1)} ms${und ? ' · Undistorted' : ''}`;
    }
  } catch (e) { fail(e); }
}

function togglePlay() {
  playing = !playing; $('#dataPlay').textContent = playing ? '❚❚ Pause' : '▶ Play';
  if (!playing) return;
  let last = performance.now();
  (async function step() {
    if (!playing || !state.recording) return;
    const now = performance.now(); const adv = (now - last) / 1000 * speed; last = now;
    let t = T0() + adv; if (t > state.recording.duration_s - DT()) t = 0;
    $('#dataT0').value = t.toFixed(3); syncSlider(); drawTimeline();
    await draw(); requestAnimationFrame(step);
  })();
}

async function loadPipeWindow() {
  try {
    const c = await api.get('/api/config');
    const get = p => { const o = c.overrides[p]; if (o != null) return o; const v = (c.values || []).find(x => x.path === p); if (v) return v.value; return c.params.find(x => x.path === p)?.expr; };
    const a = parseFloat(get('data.start_time_s')), b = parseFloat(get('data.end_time_s'));
    const file = String(get('data.hdf5_file') || '').replace(/'/g, ''); const dir = String(get('data.hdf5_dir') || '').replace(/'/g, '');
    pipeWin = { a, b, file, path: dir.replace(/\/?$/, '/') + file };
    $('#useStart').value = a; $('#useEnd').value = b;
    $('#useHint').textContent = `Pipeline input now: ${file} [${a}, ${b}] s`;
    drawTimeline();
  } catch {}
}

async function convert() {
  try { $('#convBtn').disabled = true; await api.post('/api/data/convert', { out: $('#convOut').value, overwrite: $('#convOverwrite').checked }); }
  catch (e) { $('#convBtn').disabled = false; fail(e); }
}
async function useInPipeline() {
  const s = state.recording; const h5 = s && s.kind !== 'aedat4' ? s.path : $('#convOut').value;
  if (!confirm(`Make ${h5.split('/').pop()} [${$('#useStart').value}, ${$('#useEnd').value}] s the pipeline's input?\n\nThe pipeline starts fresh: every step resets and MATLAB's workspace is cleared.`)) return;
  await busyButton($('#useBtn'), async () => {
    try { await api.post('/api/data/use', { hdf5: h5, start: +$('#useStart').value, end: +$('#useEnd').value }); toast('Pipeline input set; the pipeline was reset and its workspace cleared.', 'ok'); loadPipeWindow(); }
    catch (e) { fail(e); }
  });
}

function drawTimeline() {
  const host = $('#dataTimeline'); const cv = host.querySelector('canvas'); const W = host.clientWidth, H = host.clientHeight; if (!W) return;
  const dpr = devicePixelRatio || 1; cv.width = W * dpr; cv.height = H * dpr; const c = cv.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.clearRect(0, 0, W, H); const s = state.recording; if (!s || !rate) return;
  const D = s.duration_s, X = t => t / D * W;
  const stem = p => p.split('/').pop().replace(/\.(aedat4|hdf5|h5)$/i, '');
  if (pipeWin && isFinite(pipeWin.a) && stem(s.path) === stem(pipeWin.file)) {
    c.fillStyle = 'rgba(76,141,255,.10)'; c.fillRect(X(pipeWin.a), 0, X(pipeWin.b) - X(pipeWin.a), H);
  }
  const n = rate.t.length, mx = Math.max(...rate.on.map((v, i) => v + rate.off[i])) || 1, bw = W / n, top = 18;
  for (let i = 0; i < n; i++) {
    const h1 = rate.on[i] / mx * (H - top - 4), h2 = rate.off[i] / mx * (H - top - 4);
    c.fillStyle = 'rgba(76,141,255,.75)'; c.fillRect(i * bw, H - h1, Math.max(bw, 1), h1);
    c.fillStyle = 'rgba(240,84,90,.7)'; c.fillRect(i * bw, H - h1 - h2, Math.max(bw, 1), h2);
  }
  c.fillStyle = '#8b93a3'; c.font = '10.5px ui-monospace, Menlo, Consolas, monospace'; c.textAlign = 'right'; c.fillText(`Peak ${(mx / 1e3).toFixed(0)} kev/s · ${D.toFixed(0)} s`, W - 8, 13);
  const x = X(T0()); c.fillStyle = 'rgba(245,165,36,.25)'; c.fillRect(x, 0, Math.max(2, X(DT())), H); c.fillStyle = '#f5a524'; c.fillRect(x, 0, 1.5, H);
}
