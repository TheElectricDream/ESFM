// Live page: stream the DVXplorer (or replay a recording), record to AEDAT4.
import { $, $$, api, busyButton, el, fail, fmtInt, fmtRate, on, page, state, toast } from './app.js';
import { AnyView, FrameView } from './viewers.js';

let any, source = 'camera', mode = 'polarity', running = false, loopOn = false, frames = 0, fpsT = performance.now(), rateHist = [];

export function init() {
  any = new AnyView($('#liveViewer'));
  $$('#liveSource button').forEach(b => b.onclick = () => setSource(b.dataset.v));
  setSource(localStorage.getItem('studio.liveSource') || 'camera');
  loadRemote();
  $('#rmSave').onclick = () => saveRemote().then(() => toast('Remote settings saved', 'ok', 2000)).catch(fail);
  $('#rmTest').onclick = () => busyButton($('#rmTest'), testRemote, 'Testing');
  $$('#liveMode button').forEach(b => b.onclick = () => { mode = b.dataset.mode; $$('#liveMode button').forEach(x => x.classList.toggle('active', x === b)); });
  $('#liveScan').onclick = scan;
  $('#liveStart').onclick = () => busyButton($('#liveStart'), start, 'Starting').then(() => state.live && status(state.live));
  $('#liveStop').onclick = () => api.post('/api/live/stop').then(status).catch(fail);
  $('#recBtn').onclick = toggleRecord;
  $('#recFolder').value = (state.project || '') + '/recordings';
  on('live', status);
  scan();
  if (state.live) status(state.live);
}
export function show() { if (running) startLoop(); }
export function hide() { loopOn = false; }

function setSource(v) {
  source = v; localStorage.setItem('studio.liveSource', v);
  $$('#liveSource button').forEach(x => x.classList.toggle('active', x.dataset.v === v));
  $('#liveCamBox').hidden = v !== 'camera'; $('#liveRemoteBox').hidden = v !== 'remote'; $('#liveReplayBox').hidden = v !== 'replay';
}
const RM = { host: '#rmHost', user: '#rmUser', password: '#rmPass', port: '#rmPort', key_file: '#rmKey', python: '#rmPython', remote_dir: '#rmDir', serial: '#rmSerial' };
async function loadRemote() {
  try { const r = await api.get('/api/settings/remote'); for (const [k, sel] of Object.entries(RM)) $(sel).value = r[k] ?? ''; } catch (e) { fail(e); }
}
function saveRemote() {
  const v = {}; for (const [k, sel] of Object.entries(RM)) v[k] = k === 'port' ? +$(sel).value || 22 : $(sel).value.trim();
  return api.post('/api/settings/remote', v);
}
async function testRemote() {
  const out = $('#rmResult'); out.className = 'hint'; out.textContent = 'Connecting…';
  try {
    await saveRemote();
    const r = await api.post('/api/live/remote/test');
    const cam = r.usb.some(l => /152a/i.test(l));
    out.className = 'hint ' + (cam ? 'ok-text' : 'warn-text');
    out.textContent = `Connected to ${r.host}. ${r.python || 'No Python found'}. ${cam ? 'iniVation camera on USB: ' + r.usb.join('; ') : 'No iniVation camera on its USB.'}`;
  } catch (e) { out.className = 'hint err-text'; out.textContent = e.message; }
}

async function scan() {
  try {
    const d = await api.get('/api/live/discover');
    const box = $('#liveDevices');
    if (!d.available) { box.textContent = d.reason; return; }
    box.innerHTML = d.devices.length ? d.devices.map(x => `<span class="mono">${x.cameraModel || x.deviceName || 'Camera'} ${x.serialNumber || ''}</span>`).join('<br>')
      : 'No camera found on this computer. Plug in the DVXplorer Micro and press Rescan, or use Remote for the Orin.' + (d.reason ? `<br><span class="err-text">${d.reason}</span>` : '');
  } catch (e) { fail(e); }
}
async function start() {
  $('#liveErr').hidden = true;
  try {
    if (source === 'remote') await saveRemote();
    const st = source === 'camera' ? await api.post('/api/live/camera', {})
      : source === 'remote' ? await api.post('/api/live/remote', {})
      : await api.post('/api/live/replay', { speed: +$('#liveSpeed').value || 1, t_start: +$('#liveFrom').value || 0, loop: true });
    status(st);
  } catch (e) {
    $('#liveErr').hidden = false; $('#liveErr').textContent = e.message;
    if (source === 'replay' && e.status === 404) toast('Open a recording on the Data page first.', 'warn');
  }
}
function status(st) {
  state.live = st; running = !!st.running;
  $('#livePill').className = 'pill' + (running ? ' live' : st.error ? ' err' : '');
  $('#livePill').textContent = running ? (st.source === 'replay' ? 'Replay' : st.source === 'remote' && st.stage !== 'Streaming' ? 'Connecting' : 'Live') : st.error ? 'Error' : 'Stopped';
  $('#liveStage').hidden = !(running && st.stage && st.stage !== 'Streaming'); $('#liveStage').textContent = st.stage || '';
  $('#liveErr').hidden = !st.error; $('#liveErr').textContent = st.error || '';
  $('#liveStart').disabled = running; $('#liveStop').disabled = !running;
  $('#liveEmpty').hidden = running;
  $('#liveTitle').textContent = running ? st.name : 'Live Events';
  $('#recBtn').disabled = !running;
  $('#recPill').className = 'pill' + (st.recording ? ' err' : ''); $('#recPill').textContent = st.recording ? `● ${fmtInt(st.recording.events)}` : 'Off';
  $('#recBtn').textContent = st.recording ? '■ Stop Recording' : st.source === 'camera' ? '● Record To AEDAT4' : '● Record To HDF5';
  const kv = $('#liveStats'); kv.innerHTML = '';
  const rows = [['Source', { camera: 'Camera', remote: 'Remote', replay: 'Replay' }[st.source] || '–'], ['Resolution', `${st.width} × ${st.height}`], ['Event Rate', fmtRate(st.rate_ev_s || 0)], ['Total', fmtInt(st.total)], ['Uptime', `${st.uptime_s} s`]];
  if (st.replay) rows.push(['Replay At', `${st.replay.position ?? '–'} s (${st.replay.speed}×)`]);
  if (st.recording) rows.push(['Recording', st.recording.path.split('/').pop()]);
  for (const [k, v] of rows) kv.append(el('dt', { text: k }), el('dd', { text: v }));
  controls(st.controls);
  if (running && page() === 'live') startLoop();
}
function controls(list) {
  $('#liveControlsCard').hidden = !list?.length; const box = $('#liveControls'); if (!list?.length) return;
  if (box.dataset.sig === JSON.stringify(list.map(c => c.key))) return; box.dataset.sig = JSON.stringify(list.map(c => c.key)); box.innerHTML = '';
  for (const c of list) {
    if (c.kind === 'bool') {
      const i = el('input', { type: 'checkbox' }); i.checked = !!c.value;
      i.onchange = () => api.post('/api/live/control', { key: c.key, value: i.checked }).catch(fail);
      box.append(el('label', { class: 'toggle', title: `${c.label}: mirror the image on the camera` }, i, el('span'), c.label));
    } else {
      const i = el('input', { class: 'input sm mono', type: 'number', value: c.value });
      i.onchange = () => api.post('/api/live/control', { key: c.key, value: +i.value }).catch(fail);
      box.append(el('label', { class: 'field', title: `${c.label}: the camera's contrast threshold for this polarity (higher: fewer, stronger events)` }, el('span', { class: 'field-label', text: c.label }), i));
    }
  }
}
async function toggleRecord() {
  try { const st = await api.post('/api/live/record', { on: !state.live?.recording, folder: $('#recFolder').value }); status(st); } catch (e) { fail(e); }
}

function startLoop() {
  if (loopOn) return; loopOn = true;
  (async function tick() {
    if (!loopOn || !running || page() !== 'live') { loopOn = false; return; }
    const und = $('#liveUndist').checked ? 1 : 0;
    try {
      if (mode === 'cloud') {
        const p = await api.get(`/api/live/cloud?window=${Math.max(+$('#liveWindow').value || 33, 100)}`); any.show(p);   // the 3-D view keeps the user's angle
        await new Promise(r => setTimeout(r, 250));
      } else {
        const r = await api.bin(`/api/live/frame?window=${+$('#liveWindow').value || 33}&mode=${mode}&tau=${+$('#liveTau').value || 30}&undistort=${und}`);
        const v = any.ensure('frame', FrameView); v.setImage(r.data, +r.headers['x-w'], +r.headers['x-h']);
        v.setLegend('<span><i style="background:#4c8dff"></i>ON</span><span><i style="background:#f0545a"></i>OFF</span>');
        const rate = +r.headers['x-rate']; rateHist.push(rate); if (rateHist.length > 200) rateHist.shift();
        $('#liveMeta').textContent = `${fmtInt(+r.headers['x-count'])} events in the window · ${fmtRate(rate)}`;
      }
      frames++; const now = performance.now();
      if (now - fpsT > 1000) {
        $('#liveFps').textContent = `${(frames * 1000 / (now - fpsT)).toFixed(0)} fps`; frames = 0; fpsT = now; drawRate();
        api.get('/api/live/status').then(status).catch(() => {});
      }
    } catch (e) { if (e.status !== 404) { fail(e); loopOn = false; return; } await new Promise(r => setTimeout(r, 300)); }
    requestAnimationFrame(tick);
  })();
}
function drawRate() {
  const cv = $('#liveRate'), W = cv.clientWidth, H = cv.clientHeight; if (!W) return; const dpr = devicePixelRatio || 1;
  cv.width = W * dpr; cv.height = H * dpr; const c = cv.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0); c.clearRect(0, 0, W, H);
  const mx = Math.max(...rateHist, 1); c.strokeStyle = '#4c8dff'; c.lineWidth = 1.5; c.beginPath();
  rateHist.forEach((v, i) => { const x = i / Math.max(rateHist.length - 1, 1) * W, y = H - 2 - v / mx * (H - 6); i ? c.lineTo(x, y) : c.moveTo(x, y); }); c.stroke();
  c.fillStyle = '#8b93a3'; c.font = '10.5px ui-monospace, Menlo, Consolas, monospace'; c.fillText(`Max ${fmtRate(mx)}`, 4, 11);
}
