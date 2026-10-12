// Pipeline page: main.m step by step in MATLAB, each step's parameters and outputs.
import { $, $$, api, bus, busyButton, el, esc, fail, fmtNum, on, showPage, state, tc, toast } from './app.js';
import { inspect, refreshWorkspace, workspace } from './console.js';
import { overlay } from './completion.js';
import { ViewPanel, viewLabel } from './viewpanel.js';

let P = null, C = null, sel = 0, panel, logs = {}, peek = null, lastView = {}, epoch = null;
const KIND_ORDER = { experiment: 0, tunable: 1, fixed: 2, derived: 3, linked: 4 };

export async function init() {
  panel = new ViewPanel($('#stepViewCtl'), $('#stepViewer'), $('#stepViewMeta'));
  $('#pipeRunAll').onclick = () => run(lastRunnable(), 'to');
  $('#pipeCancel').onclick = () => api.post('/api/pipeline/cancel').then(() => toast('Stopping after the current step', 'warn')).catch(fail);
  $('#pipeReset').onclick = async () => {
    const clear = confirm('Forget which steps have run?\n\nOK also clears MATLAB\'s base workspace; Cancel keeps it and only resets the step list.');
    try { P = await api.post('/api/pipeline/reset', { clear_workspace: clear }); renderSteps(); renderDetail(); if (clear) refreshWorkspace(); } catch (e) { fail(e); }
  };
  $('#ovrClear').onclick = async () => { if (!confirm('Remove every parameter override?')) return; try { C = await api.post('/api/config/clear', {}); afterConfig(); } catch (e) { fail(e); } };
  $('#ovrSave').onclick = async () => {
    if (!confirm(`Write ${Object.keys(C.overrides).length} override(s) into config.m? A backup of config.m is kept in .studio_cache/history.`)) return;
    try { const r = await api.post('/api/config/save', {}); C = r.config; toast(`Saved into config.m: ${r.saved.join(', ')}`, 'ok'); afterConfig(); } catch (e) { fail(e); }
  };
  on('pipeline', p => {
    const was = P?.running;
    if (epoch != null && p.epoch !== epoch) { logs = {}; lastView = {}; panel.clear(); panel.stamp = null; sel = 0; }   // started fresh
    epoch = p.epoch; P = p; renderSteps(); renderDetail(true); if (was && !p.running) onRunDone();
  });
  on('matlab-output', d => { if (String(d.run).startsWith('step')) { const k = +d.run.slice(4); logs[k] = (logs[k] || '') + d.text; if (k === sel) { const pre = $('#stepLog'); if (pre) { pre.textContent = logs[k]; pre.scrollTop = pre.scrollHeight; } } } });
  on('workspace', () => renderOutputs());
  on('config', async () => { C = await api.get('/api/config'); afterConfig(); });
  on('matlab-state', m => { if (m.state === 'idle' && C && !C.values) loadConfig(true); });
  await Promise.all([load(), loadConfig(state.matlab.state === 'idle')]);
  const firstPending = P.steps.findIndex(s => s.state.status !== 'done');
  sel = firstPending < 0 ? 0 : firstPending;
  renderSteps(); renderDetail();
}
export function show() { renderSteps(); }

async function load() { P = await api.get('/api/pipeline'); epoch = P.epoch; }
async function loadConfig(refresh) { try { C = await api.get('/api/config' + (refresh ? '?refresh=1' : '')); afterConfig(); } catch (e) { fail(e); } }
function afterConfig() { renderOverrides(); renderInput(); if (P) renderDetail(true); }
const lastRunnable = () => { const i = P.steps.findIndex(s => /^inspect/i.test(s.name)); return (i < 0 ? P.steps.length : i) - 1; };

async function run(step, mode) {
  try { const r = await api.post('/api/pipeline/run', { step, mode }); for (const k of r.todo) logs[k] = ''; if (r.todo.length) { sel = r.todo[0]; renderSteps(); renderDetail(); } }
  catch (e) { fail(e); }
}
function onRunDone() {
  refreshWorkspace();
  const st = P.steps[sel]?.state;
  if (st?.status === 'error') toast(`${P.steps[sel].name} failed: ${st.error}`, 'err', 8000);
}

// ---------------- sidebar ----------------
function renderSteps() {
  if (!P) return; const box = $('#steps'); box.innerHTML = '';
  const running = P.running?.current;
  P.steps.forEach((s, i) => {
    const st = i === running ? 'running' : s.state.status;
    const tm = s.state.elapsed != null ? (s.state.elapsed < 1 ? `${(s.state.elapsed * 1000).toFixed(0)} ms` : `${s.state.elapsed.toFixed(1)} s`) : '';
    const runBtn = el('button', { class: 'btn btn-xs run', text: '▶', title: `Run every step up to and including ${s.name}`, onclick: e => { e.stopPropagation(); run(i, 'to'); } });
    const tip = { done: `Done in ${tm}. Click to see its parameters and outputs.`, stale: `Out of date: ${s.state.stale_reason || 'something it depends on changed'}`,
      error: `Failed: ${s.state.error || ''}`, running: 'Running now', pending: 'Not run yet' }[st] || '';
    box.append(el('div', { class: `step ${st} ${i === sel ? 'sel' : ''}`, onclick: () => { sel = i; renderSteps(); renderDetail(); }, title: tip },
      el('span', { class: 'num', text: st === 'done' ? '✓' : st === 'error' ? '!' : i }), el('span', { class: 'nm', text: s.name }),
      el('span', { class: 'row', style: 'gap:6px' }, el('span', { class: 'tm', text: tm }), runBtn)));
  });
  const busy = !!P.running;
  $('#pipePill').className = 'pill' + (busy ? ' busy' : '');
  $('#pipePill').textContent = busy ? `Running ${P.steps[P.running.current]?.name || ''}` : `${P.steps.filter(s => s.state.status === 'done').length} / ${P.steps.length} Done`;
  $('#pipeRunAll').disabled = busy; $('#pipeCancel').hidden = !busy;
}
function value(path) {
  if (!C) return { text: '', from: '' };
  if (C.overrides[path] != null) return { text: C.overrides[path], from: 'override' };
  const v = (C.values || []).find(x => x.path === path); if (v) return { text: v.value, from: 'matlab', cls: v.class };
  const p = C.params.find(x => x.path === path) || C.constants.find(x => x.path === path);
  return { text: p ? p.expr : '', from: 'config' };
}
function renderInput() {
  const kv = $('#pipeInput'); kv.innerHTML = ''; if (!C) return;
  const f = value('data.hdf5_file').text, d = value('data.hdf5_dir').text, a = value('data.start_time_s').text, b = value('data.end_time_s').text, x = value('camera.calibration_xml').text;
  const short = p => { const parts = p.replace(/'/g, '').split('/').filter(Boolean); return (parts.length > 2 ? '…/' : '/') + parts.slice(-2).join('/'); };
  const xml = x.replace(/['[\]\s]/g, '');
  for (const [k, v, full] of [['Recording', f.replace(/'/g, ''), f], ['Folder', short(d), d], ['Window', `${a} – ${b} s`, 'cfg.data.start_time_s – end_time_s'], ['Intrinsics', xml.length > 30 ? xml.slice(0, 14) + '…' + xml.slice(-14) : xml, xml]])
    kv.append(el('dt', { text: k }), el('dd', { text: v, title: (full || v).replace(/'/g, '') }));
}
function renderOverrides() {
  const box = $('#ovrList'); box.innerHTML = ''; if (!C) return;
  const o = Object.entries(C.overrides); $('#ovrCount').textContent = o.length;
  $('#ovrClear').disabled = $('#ovrSave').disabled = !o.length;
  if (!o.length) box.append(el('span', { class: 'muted', text: 'None: the pipeline runs config.m as it is.' }));
  const doc = Object.fromEntries((C.params || []).concat(C.constants || []).map(p => [p.path, p]));
  for (const [k, v] of o) box.append(el('div', { class: 'row' }, el('span', { class: 'mono grow', style: 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap', title: `cfg.${k} = ${v}   (config.m: ${doc[k]?.expr ?? '–'})${doc[k]?.comment ? '\n' + doc[k].comment : ''}`, html: `<span class="muted">${esc(k)}</span> = ${esc(v)}` }),
    el('button', { class: 'btn btn-ghost btn-xs', text: '✕', title: `Back to config.m (${doc[k]?.expr ?? ''})`, onclick: () => setParam(k, '') })));
}

// ---------------- step detail ----------------
function renderDetail(soft) {
  if (!P) return; const s = P.steps[sel]; if (!s) return;
  const left = $('#stepLeft');
  if (soft && left.dataset.step === String(sel) && document.activeElement?.closest?.('#stepLeft')) { statusBox(s); return; }
  left.dataset.step = sel; left.innerHTML = '';
  const st = P.running?.current === sel ? 'running' : s.state.status;
  const pill = { done: 'ok', error: 'err', stale: 'warn', running: 'busy' }[st] || '';
  left.append(el('div', { class: 'step-title' }, el('span', { class: 'muted mono', text: `#${s.id}` }), el('h2', { text: s.name }), el('span', { class: 'grow' }),
    el('span', { class: `pill ${pill}`, title: 'Step state', text: st === 'done' ? `Done · ${fmtNum(s.state.elapsed, 2)} s` : st === 'stale' ? 'Out Of Date' : tc(st) })));
  const intro = leadingComment(s.code);
  if (intro) left.append(el('p', { class: 'muted', style: 'margin:0;font-size:12.5px', text: intro }));
  const btns = el('div', { class: 'row wrap' },
    el('button', { class: 'btn btn-go btn-sm', text: sel > 0 ? '▶ Run To Here' : '▶ Run', title: 'Run every step that is not up to date, up to and including this one', onclick: () => run(sel, 'to'), disabled: !!P.running }),
    sel > 0 ? el('button', { class: 'btn btn-sm', text: 'Run This Step Only', title: 'Run just this step; it uses the earlier steps\' variables already in the workspace', onclick: () => run(sel, 'only'), disabled: !!P.running }) : null,
    el('span', { class: 'grow' }),
    el('button', { class: 'btn btn-sm', text: 'Edit In Code', title: `Open main.m at this step (line ${s.line})`, onclick: () => showPage('code', { path: 'main.m', line: s.line }) }));
  left.append(btns, el('div', { id: 'stepStatus' }));
  statusBox(s);

  // functions it calls
  if (s.calls.length) {
    const chips = el('div', { class: 'chips' });
    for (const f of s.calls) chips.append(el('span', { class: 'chip mono', text: f, title: `Open ${f} on the Code page`, onclick: () => showPage('code', { func: f }) }));
    left.append(el('section', {}, el('div', { class: 'card-head', style: 'margin-bottom:6px' }, el('h2', { text: 'Calls' })), chips));
  }
  // parameters
  left.append(paramsCard(s));
  // log
  const pre = el('pre', { class: 'step-log', id: 'stepLog', title: 'What the step printed in MATLAB', text: logs[sel] || (s.state.status === 'done' ? '(Printed in the MATLAB page\'s command window when the step ran.)' : 'Not run yet.') });
  left.append(el('section', {}, el('div', { class: 'card-head', style: 'margin-bottom:6px' }, el('h2', { text: 'Output' }), s.state.changed?.length ? el('span', { class: 'sub', title: s.state.changed.join(', '), text: `${s.state.changed.length} Variables Changed` }) : null), pre));
  // code
  const det = el('details', { class: 'code-peek' }, el('summary', { class: 'muted small', style: 'cursor:pointer;margin-bottom:6px', title: 'The code this step runs, from main.m', text: `Code (${s.lines} Lines Of main.m From Line ${s.line})` }));
  const holder = el('div'); det.append(holder);
  det.ontoggle = () => { if (det.open && !holder.firstChild) { peek = CodeMirror(holder, { value: s.code, mode: 'octave', theme: 'studio', readOnly: true, lineNumbers: true, firstLineNumber: s.line + 1, viewportMargin: Infinity }); peek.addOverlay(overlay()); } };
  left.append(det);
  renderOutputs();
}
function leadingComment(code) {
  const out = [];
  for (const l of code.split('\n')) {
    if (/^\s*$/.test(l) || /^\s*%-----%/.test(l) || /^\s*%%/.test(l)) { if (out.length) break; continue; }
    if (!/^\s*%/.test(l)) break;
    out.push(l.replace(/^\s*%\s?/, ''));
  }
  return out.join(' ');
}
function statusBox(s) {
  const box = $('#stepStatus'); if (!box) return; box.innerHTML = '';
  if (s.state.status === 'stale') box.append(el('div', { class: 'callout warn', text: `Out of date: ${s.state.stale_reason || 'something it depends on changed'}. Run again to refresh its outputs.` }));
  if (s.state.status === 'error') box.append(el('div', { class: 'callout err' }, el('b', { text: s.state.error }), el('pre', { text: (s.state.report || '').split('\nError in studio.Worker')[0] })));
  if (state.matlab.state === 'offline') box.append(el('div', { class: 'callout warn', text: 'MATLAB is not connected. Run studio.start in MATLAB, or use Start MATLAB at the top right.' }));
}

const KIND_TIP = { fixed: 'Fixed: validated in earlier tests (still editable)', derived: 'Derived: computed in config.m from other values (read-only here; edit what it is computed from)',
  linked: 'Linked: the same value as a constant or another field (read-only here; edit that one)', experiment: 'Experiment: still under test', tunable: '' };
function paramsCard(s) {
  const card = el('section', {});
  const secs = s.is_config ? ['constants'] : s.sections.filter(x => x !== 'output' || /export/i.test(s.name));
  card.append(el('div', { class: 'card-head', style: 'margin-bottom:4px' }, el('h2', { text: 'Parameters' }),
    el('span', { class: 'sub', title: 'The cfg sections this step and the functions it calls read', text: s.is_config ? 'Shared Constants' : `cfg.${secs.join(', cfg.')}` })));
  if (!C) { card.append(el('p', { class: 'hint', text: 'Loading…' })); return card; }
  if (s.is_config) card.append(el('p', { class: 'sec-doc', text: 'This step builds cfg from config.m (plus the overrides on the left). These constants feed several sections below.' }));
  if (!secs.length) card.append(el('p', { class: 'hint', text: 'This step reads no cfg parameters.' }));
  const order = { experiment: 0, tunable: 1, fixed: 2, derived: 3, linked: 4 };
  for (const sec of secs) {
    const items = (sec === 'constants' ? C.constants : C.params.filter(p => p.section === sec)).slice().sort((a, b) => order[a.kind] - order[b.kind]);
    if (!items.length) continue;
    const doc = C.sections.find(x => x.name === sec)?.doc;
    const g = el('div', { class: 'params', style: 'margin-top:8px' });
    if (sec !== 'constants') g.append(el('div', { class: 'muted small', style: 'font-weight:600;letter-spacing:.06em;margin:4px 0 2px', title: doc || '' }, `cfg.${sec}`));
    if (doc) g.append(el('p', { class: 'sec-doc', text: doc.replace(/^\w+:\s*/, '') }));
    for (const p of items) g.append(paramRow(p, p.kind === 'derived' || p.kind === 'linked'));
    card.append(g);
  }
  return card;
}
function paramRow(p, readOnly) {
  const v = value(p.path), ovr = C.overrides[p.path] != null;
  const name = p.section === 'constants' ? p.path : p.name;
  const tip = [p.section === 'constants' ? `${p.path} (constant in config.m)` : `cfg.${p.path}`,
    p.comment || '(no description in config.m)', KIND_TIP[p.kind], `config.m line ${p.line}: ${p.expr}`, ovr ? `Overridden here: ${C.overrides[p.path]}` : ''].filter(Boolean).join('\n');
  const row = el('div', { class: 'param' + (ovr ? ' ovr' : ''), title: tip },
    el('span', { class: 'pn', text: name }),
    el('span', { class: `kind ${p.kind}`, text: p.kind === 'tunable' ? '' : tc(p.kind), title: KIND_TIP[p.kind] || 'Tunable' }));
  if (readOnly) row.append(el('span', { class: 'ro2', text: v.text, title: `${v.text}  =  ${p.expr}` }), el('span'));
  else {
    const inp = el('input', { class: 'input sm mono', value: v.text, spellcheck: 'false', title: tip + '\n\nAny MATLAB expression; Enter applies, Esc cancels.' });
    const commit = () => { const t = inp.value.trim(); if (t === v.text) return; setParam(p.path, t === p.expr || (!ovr && t === '') ? '' : t, inp); };
    inp.onkeydown = e => { if (e.key === 'Enter') inp.blur(); if (e.key === 'Escape') { inp.value = v.text; inp.blur(); } };
    inp.onblur = commit;
    row.append(inp, el('button', { class: 'btn btn-ghost btn-xs reset', text: '↺', title: `Back to config.m: ${p.expr}`, onclick: () => setParam(p.path, '') }));
  }
  return row;
}
async function setParam(path, expr, inp) {
  inp?.classList.remove('bad');
  try {
    C = await api.post('/api/config/override', { path, expr });
    const t = expr ? `cfg.${path} = ${expr}` : `cfg.${path} back to config.m`;
    toast(t + (C.applied_to_workspace ? ' (cfg in the workspace updated)' : ''), 'ok', 2500);
    afterConfig(); renderDetail();
  } catch (e) { inp?.classList.add('bad'); fail(e); }
}

// ---------------- outputs (right) ----------------
function renderOutputs() {
  if (!P) return; const s = P.steps[sel]; const box = $('#stepOutputs'); box.innerHTML = '';
  const ws = new Map(workspace.map(v => [v.name, v]));
  const names = [...new Set([...(s.state.changed || []), ...s.outputs])].filter(n => ws.has(n));
  $('#stepViewTitle').textContent = names.length ? 'Outputs' : 'Outputs (Run The Step)';
  let first = null;
  for (const n of names) {
    const v = ws.get(n);
    if (!v.views?.length) { box.append(el('span', { class: 'chip', title: `${n}: ${v.size} ${v.class}, ${v.preview}. Click to inspect.`, onclick: () => inspect(n) }, n)); continue; }
    for (const k of v.views) {
      const c = el('span', { class: 'chip', 'data-key': `${n}|${k}`, title: `Show ${n} (${v.size} ${v.class}) as ${viewLabel(k)}`, onclick: () => openView(n, k, null) }, n, el('span', { class: 'k', text: viewLabel(k) }));
      box.append(c); first ??= [n, k];
    }
  }
  const want = lastView[sel], stamp = `${sel}:${s.state.ran_at || ''}`;
  if (want && names.includes(want[0])) openView(...want, stamp);
  else if (first && s.state.status === 'done') openView(...first, stamp);
  else { panel.clear(); panel.stamp = null; $('#stepEmpty').hidden = false; }
}
function openView(name, kind, stamp) {
  lastView[sel] = [name, kind]; $('#stepEmpty').hidden = true;
  $$('#stepOutputs .chip').forEach(c => c.classList.toggle('active', c.dataset.key === `${name}|${kind}`));
  // the same view of the same results is already on screen: keep it (and its window)
  if (stamp && panel.expr === name && panel.kind === kind && panel.stamp === stamp) return;
  const keep = panel.expr === name && panel.kind === kind;
  panel.stamp = stamp || `${sel}:${Date.now()}`;
  panel.open(name, kind, keep);
}
