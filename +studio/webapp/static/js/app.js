// Event Studio: app shell. Pages are modules with init() (once) and show() (each visit).
import * as console_ from './console.js';

export const bus = new EventTarget();
export const state = { matlab: { state: 'offline' }, recording: null, live: null, overrides: {}, calibration: null, project: '' };

// ---------------- helpers ----------------
export const $ = (s, root = document) => root.querySelector(s);
export const $$ = (s, root = document) => [...root.querySelectorAll(s)];
export function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k === 'text') e.textContent = v;
    else if (k === 'html') e.innerHTML = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (k === 'dataset') Object.assign(e.dataset, v);
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat()) if (c != null) e.append(c.nodeType ? c : document.createTextNode(String(c)));
  return e;
}
export const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
export const on = (type, fn) => bus.addEventListener(type, e => fn(e.detail));
export function fmtNum(v, d = 3) {
  if (v == null || Number.isNaN(v)) return '–';
  const a = Math.abs(v);
  if (a !== 0 && (a >= 1e6 || a < 1e-3)) return v.toExponential(2);
  return (+v.toFixed(d)).toLocaleString();
}
export const fmtInt = v => v == null ? '–' : Math.round(v).toLocaleString();
export function fmtRate(v) { return v >= 1e6 ? (v / 1e6).toFixed(2) + ' Mev/s' : v >= 1e3 ? (v / 1e3).toFixed(1) + ' kev/s' : Math.round(v) + ' ev/s'; }
export function fmtAgo(t) { if (!t) return '–'; const s = Date.now() / 1000 - t; return s < 60 ? 'just now' : s < 3600 ? `${Math.round(s / 60)} min ago` : s < 86400 ? `${Math.round(s / 3600)} h ago` : new Date(t * 1000).toLocaleString(); }
export function b64bytes(s) { const bin = atob(s); const out = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; }
// Title Case for labels (not sentences): "data frame" -> "Data Frame"
export const tc = s => String(s ?? '').replace(/(^|[\s(\-/·:,])([a-z])/g, (m, a, b) => a + b.toUpperCase());
// Run FN at most one at a time; calls made while it runs collapse into one more run with the latest arguments
export function latest(fn) {
  let busy = false, next = null;
  return async function run(...args) {
    if (busy) { next = args; return; }
    busy = true;
    try { await fn(...args); } finally {
      busy = false;
      if (next) { const a = next; next = null; run(...a); }
    }
  };
}
export const debounce = (fn, ms = 250) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

// ---------------- API ----------------
async function call(method, url, body) {
  const r = await fetch(url, { method, headers: body ? { 'Content-Type': 'application/json' } : {}, body: body ? JSON.stringify(body) : undefined });
  const isJson = (r.headers.get('content-type') || '').includes('json');
  const data = isJson ? await r.json() : await r.arrayBuffer();
  if (!r.ok) { const e = new Error(data.error || r.statusText); e.status = r.status; e.data = data; throw e; }
  return data;
}
export const api = {
  get: (url) => call('GET', url),
  post: (url, body = {}) => call('POST', url, body),
  async bin(url) {
    const r = await fetch(url);
    if (!r.ok) { let m = r.statusText; try { m = (await r.json()).error; } catch {} const e = new Error(m); e.status = r.status; throw e; }
    const h = {}; r.headers.forEach((v, k) => { h[k.toLowerCase()] = v; });
    return { data: new Uint8ClampedArray(await r.arrayBuffer()), headers: h };
  },
};
export function toast(msg, kind = '', ms = 4500) {
  const t = el('div', { class: `toast ${kind}`, text: msg });
  $('#toasts').append(t);
  setTimeout(() => t.remove(), ms);
}
export function fail(e, what = '') {
  if (e?.status === 409 && e.data?.busy) toast(`MATLAB is busy (${e.data.busy}). Try again when it finishes.`, 'warn');
  else toast((what ? what + ': ' : '') + (e?.message || e), 'err', 7000);
  if (e?.data?.report) console_.logLine(e.data.report, 'err', 'matlab');
}
export async function busyButton(btn, fn, label) {
  const old = btn.innerHTML; btn.disabled = true; btn.innerHTML = `<span class="spinner"></span>${label ? ' ' + esc(label) : ''}`;
  try { return await fn(); } finally { btn.disabled = false; btn.innerHTML = old; }
}

// ---------------- file dialog ----------------
export function chooseFile({ title = 'Open a recording', start = '' } = {}) {
  const dlg = $('#fileDialog');
  $('#fileDialogTitle').textContent = title;
  let current = '', picked = '';
  return new Promise(resolve => {
    const list = $('#fileList');
    async function go(path) {
      try {
        const r = await api.get('/api/data/browse?path=' + encodeURIComponent(path || ''));
        current = r.path; $('#fileDir').value = r.path; list.innerHTML = '';
        $('#fileUp').disabled = !r.parent; $('#fileUp').onclick = () => go(r.parent);
        for (const d of r.dirs) list.append(el('button', { onclick: () => go(r.path + '/' + d), ondblclick: () => go(r.path + '/' + d) },
          el('span', { html: '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" opacity=".55"/></svg>' }), d));
        for (const f of r.files) {
          const b = el('button', {}, el('span', { html: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3" fill="#4c8dff"/><circle cx="6" cy="8" r="1.6" fill="#f0545a"/><circle cx="18" cy="16" r="1.6" fill="#4c8dff"/></svg>' }),
            f.name, el('span', { class: 'sz', text: (f.size / 1e6).toFixed(1) + ' MB' }));
          b.onclick = () => { $$('.folder-list button').forEach(x => x.classList.remove('sel')); b.classList.add('sel'); picked = r.path + '/' + f.name; $('#fileSel').textContent = picked; $('#fileOk').disabled = false; };
          b.ondblclick = () => { picked = r.path + '/' + f.name; done(picked); };
          list.append(b);
        }
        if (!r.dirs.length && !r.files.length) list.append(el('div', { class: 'hint', style: 'padding:10px', text: 'No folders or recordings here.' }));
      } catch (e) { fail(e); }
    }
    function done(v) { dlg.close(); resolve(v); }
    $('#fileOk').onclick = () => done(picked);
    $('#fileCancel').onclick = () => done(null);
    $('#fileDir').onkeydown = e => { if (e.key === 'Enter') go($('#fileDir').value); };
    $('#fileOk').disabled = true; $('#fileSel').textContent = '';
    api.get('/api/data/places').then(r => {
      $('#filePlaces').innerHTML = '';
      for (const p of r.places) $('#filePlaces').append(el('button', { onclick: () => go(p.path), title: p.path, text: p.name }));
      go(start ? start.replace(/\/[^/]*\.(aedat4|hdf5|h5)$/i, '') : (r.places[0]?.path || ''));
    });
    dlg.showModal();
  });
}

// ---------------- MATLAB status in the top bar ----------------
function showMatlab(m) {
  state.matlab = m;
  const b = $('#matlabBadge'), t = $('#matlabText');
  b.className = 'badge ' + ({ idle: 'badge-ok', busy: 'badge-busy', starting: 'badge-warn', offline: 'badge-bad' }[m.state] || 'badge-warn');
  const rel = m.info?.release ? `R${m.info.release}` : '';
  t.textContent = m.state === 'idle' ? `MATLAB ${rel}` : m.state === 'busy' ? `Busy: ${m.busy || ''}`.slice(0, 48) : m.state === 'starting' ? 'Starting MATLAB…' : 'MATLAB Offline';
  b.title = m.state === 'offline' ? 'No MATLAB connected. Run studio.start in MATLAB, or press Start MATLAB for a headless one.'
    : `${m.info?.desktop ? 'Your MATLAB desktop session' : 'Headless MATLAB'} (pid ${m.info?.pid ?? '?'}), ${m.info?.pwd ?? ''}`;
  $('#matlabStart').hidden = !(m.state === 'offline');
  bus.dispatchEvent(new CustomEvent('matlab-state', { detail: m }));
}
$('#matlabStart').onclick = () => busyButton($('#matlabStart'), () => api.post('/api/matlab/start').catch(fail), 'Starting');

// ---------------- pages ----------------
const pages = {
  data: () => import('./data.js'), live: () => import('./live.js'), camera: () => import('./camera.js'),
  pipeline: () => import('./pipeline.js'), code: () => import('./code.js'), build: () => import('./build.js'),
  matlab: () => import('./matlab.js'), journal: () => import('./journal.js'),
};
const loaded = {};
let currentPage = null;
export async function showPage(name, arg) {
  if (!pages[name]) name = 'pipeline';
  if (currentPage && currentPage !== name) loaded[currentPage]?.then(m => m.hide?.());
  currentPage = name;
  $$('.page').forEach(p => { p.hidden = p.id !== 'page-' + name; });
  $$('.page-tabs button').forEach(b => b.classList.toggle('active', b.dataset.page === name));
  if (location.hash.slice(1).split('/')[0] !== name) history.replaceState(null, '', '#' + name);
  if (!loaded[name]) loaded[name] = pages[name]().then(async m => { await m.init?.(); return m; });
  const m = await loaded[name];
  m.show?.(arg);
}
export const page = () => currentPage;
$$('.page-tabs button').forEach(b => b.onclick = () => showPage(b.dataset.page));
window.addEventListener('hashchange', () => showPage(location.hash.slice(1).split('/')[0]));

// ---------------- server events ----------------
function connectEvents() {
  const es = new EventSource('/api/stream');
  es.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.type === 'matlab') showMatlab(m.data);
    if (m.type === 'recording') { if (m.data.summary) state.recording = m.data.summary; if (m.data.closed) state.recording = null; topStats(); }
    if (m.type === 'live') { state.live = m.data; topStats(); }
    if (m.type === 'config') state.overrides = m.data.overrides;
    bus.dispatchEvent(new CustomEvent(m.type, { detail: m.data }));
  };
  es.onerror = () => { showMatlab({ state: 'offline' }); $('#projectLine').textContent = 'Studio server not reachable… retrying'; };
  es.onopen = () => refreshState();
}
function topStats() {
  const r = state.recording, l = state.live;
  $('#statEvents').hidden = !r;
  if (r) { $('#statEventsVal').textContent = `${(r.events / 1e6).toFixed(1)} M · ${r.duration_s.toFixed(0)} s`; $('#statEvents').title = r.path; }
  $('#statLive').hidden = !(l && l.running);
  if (l && l.running) $('#statLiveVal').textContent = fmtRate(l.rate_ev_s);
}
export async function refreshState() {
  const s = await api.get('/api/state');
  state.project = s.project; state.recording = s.recording.summary; state.live = s.live;
  state.overrides = s.overrides; state.calibration = s.calibration;
  $('#projectLine').textContent = s.project;
  $('#projectLine').title = `${s.project} · ${s.host}`;
  showMatlab(s.matlab);
  topStats();
  bus.dispatchEvent(new CustomEvent('state', { detail: s }));
  return s;
}

// ---------------- start ----------------
(async function start() {
  console_.init();
  connectEvents();
  try { const s = await refreshState(); console_.loadHistory(s.logs); } catch (e) { fail(e); }
  showPage(location.hash.slice(1).split('/')[0] || 'pipeline');
  const mem = m => { if (!m) return; const v = $('#statMemVal'); v.textContent = `${m.available_gb.toFixed(1)} / ${m.total_gb.toFixed(0)} GB`; v.style.color = m.available_gb < m.min_free_gb ? 'var(--stop)' : m.available_gb < 2 * m.min_free_gb ? 'var(--warn)' : ''; };
  setInterval(() => api.get('/api/memory').then(mem).catch(() => {}), 4000); api.get('/api/memory').then(mem).catch(() => {});
  setInterval(() => { if (state.live?.running) api.get('/api/live/status').then(l => { state.live = l; topStats(); }).catch(() => {}); }, 2000);
})();
