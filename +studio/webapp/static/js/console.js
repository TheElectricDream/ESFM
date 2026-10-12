// The bottom console: MATLAB command window, workspace, inspector drawer, and the Studio log.
import { $, $$, api, bus, el, esc, fail, fmtNum, on, state, tc } from './app.js';
import { hint, loadSymbols, overlay, setWorkspace } from './completion.js';
import { ViewPanel, viewLabel } from './viewpanel.js';

let cm, history = [], hIdx = -1, logN = 0, live = null, wsTimer = null;

export function init() {
  // ---------- command window ----------
  cm = CodeMirror($('#cmdEditor'), {
    mode: 'octave', theme: 'studio', lineWrapping: true, viewportMargin: Infinity, matchBrackets: true, autoCloseBrackets: true,
    extraKeys: {
      Enter: run, 'Shift-Enter': c => c.replaceSelection('\n'), 'Ctrl-Enter': run,
      Up: c => (c.getCursor().line === 0 ? histStep(1) : CodeMirror.Pass), Down: c => (c.getCursor().line === c.lineCount() - 1 ? histStep(-1) : CodeMirror.Pass),
      Tab: c => c.showHint({ hint, completeSingle: false }), 'Ctrl-Space': c => c.showHint({ hint, completeSingle: false }),
      Esc: c => c.setValue(''),
    },
  });
  cm.addOverlay(overlay());
  cm.on('inputRead', (c, ch) => { if (ch.text[0] === '.') c.showHint({ hint, completeSingle: false }); });
  try { history = JSON.parse(localStorage.getItem('studio.history') || '[]'); } catch {}
  $('#cmdRun').onclick = () => run();
  loadSymbols();
  note('Type MATLAB commands here: they run in the connected MATLAB session\'s base workspace, like its Command Window. Enter runs, Shift+Enter adds a line, ↑ recalls, Tab completes.');

  on('matlab-output', d => {
    if (d.run === 'eval') { if (live) { live.textContent += d.text; scroll(); } return; }
    if (String(d.run).startsWith('step') || d.run === 'compile') { const pre = streamBlock(d.run); pre.textContent += d.text; scroll(); }
  });
  // refresh the workspace when MATLAB comes back from something that can change it
  // (not after the read-only requests, which would loop: listing makes MATLAB busy too)
  let lastBusy = null, firstIdle = true;
  const readOnly = /^(Workspace|Inspect|View |Read cfg|rehash|Code check|Open in editor)/;
  on('matlab-state', m => {
    if (m.state === 'busy') lastBusy = m.busy || '';
    $('#consoleBusy').hidden = m.state !== 'busy'; $('#consoleBusyText').textContent = m.busy || '';
    if (m.state === 'idle' && (firstIdle || (lastBusy != null && !readOnly.test(lastBusy))) && !wsTimer) {
      firstIdle = false; lastBusy = null; wsTimer = setTimeout(() => { wsTimer = null; refreshWorkspace(); }, 150);
    }
  });
  on('pipeline', p => { if (p.running?.current != null) { const s = p.steps[p.running.current]; streamTitle('step' + p.running.current, `── ${s.name} ──`); } });

  // ---------- workspace ----------
  $('#wsRefresh').onclick = refreshWorkspace;

  // ---------- log ----------
  on('log', e => logLine(e.text, e.level, e.source, e.t));

  // ---------- tabs (MATLAB page) ----------
  $$('#page-matlab .tabs button').forEach(b => b.onclick = () => {
    $$('#page-matlab .tabs button').forEach(x => x.classList.toggle('active', x === b));
    $$('#page-matlab .console-pane').forEach(p => p.classList.toggle('active', p.dataset.pane === b.dataset.tab));
    if (b.dataset.tab === 'cmd') cm.refresh();
  });
  $('#consoleClear').onclick = () => { const t = $('#page-matlab .tabs button.active').dataset.tab; if (t === 'log') { $('#logOut').innerHTML = ''; logN = 0; $('#logCount').textContent = '0'; } else $('#cmdOut').innerHTML = ''; };

  // ---------- drawer ----------
  $('#drawerClose').onclick = () => { $('#drawer').hidden = true; drawerPanel?.clear(); };
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !$('#drawer').hidden && !document.querySelector('dialog[open]')) $('#drawerClose').click(); });
}

function histStep(d) {
  if (!history.length) return;
  hIdx = Math.max(-1, Math.min(history.length - 1, hIdx + d));
  cm.setValue(hIdx < 0 ? '' : history[history.length - 1 - hIdx]); cm.setCursor(cm.lineCount(), 0);
}
function scroll() { const o = $('#cmdOut'); o.scrollTop = o.scrollHeight; }
function note(t) { $('#cmdOut').append(el('div', { class: 'c-note', text: t })); scroll(); }
function streamBlock(run) {
  let pre = $(`#cmdOut [data-run="${run}"]:last-of-type`);
  if (!pre || pre.dataset.closed) { pre = el('div', { 'data-run': run }); $('#cmdOut').append(pre); }
  return pre;
}
function streamTitle(run, title) {
  const last = $('#cmdOut').lastElementChild;
  if (last?.dataset.title === title) return;
  $$(`#cmdOut [data-run="${run}"]`).forEach(x => { x.dataset.closed = '1'; });
  $('#cmdOut').append(el('div', { class: 'c-note', 'data-title': title, text: title }));
}

export async function run(code) {
  if (typeof code !== 'string') code = cm.getValue();
  if (!code.trim()) return;
  if (state.matlab.state === 'offline') return fail(new Error('MATLAB is not connected (run studio.start in MATLAB, or press Start MATLAB)'));
  history = history.filter(h => h !== code); history.push(code); history = history.slice(-200); hIdx = -1;
  localStorage.setItem('studio.history', JSON.stringify(history));
  cm.setValue('');
  $('#cmdOut').append(el('div', { class: 'c-in', text: code }));
  live = el('div'); $('#cmdOut').append(live); scroll();
  const target = live;
  try {
    const r = await api.post('/api/matlab/eval', { code });
    target.textContent = r.output.replace(/^\n+/, '').replace(/\n+$/, '');
    if (r.elapsed > 2) target.append(el('div', { class: 'c-note', text: `(${r.elapsed.toFixed(1)} s)` }));
  } catch (e) {
    if (e.data?.output) target.textContent = e.data.output.replace(/\n+$/, '');
    target.append(el('div', { class: 'c-err', text: e.data?.report ? e.data.report.split('\nError in studio.Worker')[0] : e.message }));
  } finally { if (live === target) live = null; scroll(); }
}

// ---------- workspace ----------
export let workspace = [];
export async function refreshWorkspace(tries = 6) {
  if (state.matlab.state === 'offline') return;
  try { workspace = await api.get('/api/matlab/workspace'); }
  catch (e) { if (tries > 1 && (e.status === 409 || e.status === 503 || e.status === 504)) setTimeout(() => refreshWorkspace(tries - 1), 1500); return; }
  setWorkspace(workspace.map(v => v.name));
  const tb = $('#wsBody'); tb.innerHTML = '';
  $('#wsCount').textContent = workspace.length;
  for (const v of workspace) {
    const views = el('td', { class: 'v' });
    const SHORT = { cloud3d: '3-D', trajectory: 'Traj', landmarks: 'Cloud', series: 'Plot' };
    for (const k of v.views || []) views.append(el('button', { class: 'vbtn', text: SHORT[k] || viewLabel(k), title: `Show ${v.name} as ${viewLabel(k)}`, onclick: () => inspect(v.name, k) }));
    tb.append(el('tr', {},
      el('td', { class: 'n', text: v.name, title: `Inspect ${v.name}: its fields, values and views` }),
      el('td', { class: 'c', text: v.size, title: 'Size' }), el('td', { class: 'c', text: v.class, title: 'Class' }),
      el('td', { class: 'p', text: v.preview, title: v.preview }), views));
    tb.lastElementChild.firstElementChild.onclick = () => inspect(v.name);
  }
  bus.dispatchEvent(new CustomEvent('workspace', { detail: workspace }));
}

// ---------- inspector drawer ----------
let drawerPanel = null;
export async function inspect(expr, view) {
  const d = $('#drawer'); d.hidden = false;
  $('#drawerTitle').textContent = expr; $('#drawerMeta').textContent = '…';
  const body = $('#drawerBody'); body.innerHTML = '';
  let info;
  try { info = await api.post('/api/matlab/inspect', { expr }); } catch (e) { $('#drawerMeta').textContent = ''; return fail(e, `Inspect ${expr}`); }
  $('#drawerMeta').textContent = `${info.size} ${info.class}`;
  const chips = $('#drawerViews'); chips.innerHTML = '';
  const vhost = el('div', { class: 'viewer', hidden: true }); const vmeta = el('div', { class: 'meta small muted', style: 'margin:6px 2px 10px' });
  if (!drawerPanel) drawerPanel = null;
  drawerPanel?.clear(); drawerPanel = new ViewPanel($('#drawerCtl'), vhost, vmeta);
  const showView = k => { $$('#drawerViews .chip').forEach(c => c.classList.toggle('active', c.dataset.k === k)); vhost.hidden = false; drawerPanel.open(expr, k); };
  for (const k of info.views || []) chips.append(el('span', { class: 'chip', 'data-k': k, text: viewLabel(k), title: `Show ${expr} as ${viewLabel(k)}`, onclick: () => showView(k) }));
  if (expr.includes('.') || expr.includes('(') || expr.includes('{')) {
    const up = expr.replace(/(\.[A-Za-z]\w*|\(\d+(,\d+)*\)|\{\d+(,\d+)*\})$/, '');
    if (up !== expr) chips.prepend(el('span', { class: 'chip', text: '↑ ' + up, title: `Back to ${up}`, onclick: () => inspect(up) }));
  }
  body.append(vhost, vmeta);
  if (info.children) {
    const tree = el('div', { class: 'tree' });
    for (const c of info.children) {
      tree.append(el('div', { class: 'node' + (c.expandable ? ' exp' : ''), title: c.expandable ? `Open ${c.name}` : c.name, onclick: c.expandable ? () => inspect(c.name) : null },
        el('span', { class: 'nm', text: c.name.slice(expr.length).replace(/^\./, '') || c.name }),
        el('span', { class: 'cl', text: `${c.size} ${c.class}` }), el('span', { class: 'pv', text: c.preview, title: c.preview })));
    }
    body.append(tree);
  }
  if (info.stats) body.append(el('div', { class: 'meta small muted', style: 'margin:8px 2px', text: Object.entries(info.stats).map(([k, v]) => `${k} ${fmtNum(v, 5)}`).join('  ·  ') }));
  if (info.values) {
    const t = el('table', { class: 'numtable' }); const hdr = el('tr', {}, el('th', { text: '' }));
    for (let j = 0; j < info.shown[1]; j++) hdr.append(el('th', { text: j + 1 })); t.append(hdr);
    info.values.forEach((row, i) => { const tr = el('tr', {}, el('th', { text: i + 1 })); [].concat(row).forEach(v => tr.append(el('td', { text: fmtNum(v, 6) }))); t.append(tr); });
    body.append(el('div', { style: 'overflow:auto;max-height:420px;border:1px solid var(--border);border-radius:8px' }, t));
    const [r, c] = info.size.split('×').map(Number);
    if (r > info.shown[0] || c > info.shown[1]) body.append(el('p', { class: 'hint', text: `Showing ${info.shown[0]} × ${info.shown[1]} of ${info.size}.` }));
  }
  if (info.text != null) body.append(el('pre', { class: 'text', text: info.text }));
  if (view) showView(view); else if ((info.views || []).length && !info.children?.length && !info.values) showView(info.views[0]);
}

// ---------- log ----------
export function logLine(text, level = 'info', source = '', t) {
  const out = $('#logOut');
  const time = new Date((t || Date.now() / 1000) * 1000).toLocaleTimeString();
  out.append(el('div', { class: 'l-' + ({ ok: 'ok', err: 'err', warn: 'warn', cmd: 'cmd' }[level] || 'info') },
    el('span', { class: 'l-t', text: time }), source ? el('span', { class: 'l-src', text: source }) : null, text));
  logN++; $('#logCount').textContent = logN;
  if (out.childElementCount > 1500) out.firstElementChild.remove();
  out.scrollTop = out.scrollHeight;
}
export function loadHistory(entries) { for (const e of entries || []) logLine(e.text, e.level, e.source, e.t); }

// the page became visible: CodeMirror measures itself again, and the workspace is current
export function refresh() { cm?.refresh(); cm?.focus(); refreshWorkspace(); }
