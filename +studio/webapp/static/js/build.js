// Build page: production -> deployable package -> standalone executable -> test run.
import { $, $$, api, busyButton, el, esc, fail, fmtAgo, on, state, toast } from './app.js';
import { AnyView } from './viewers.js';

let S = null, any, viewMode = 'log';
const pkg = () => $('#buildPkg').value.trim() || 'deployable';

export async function init() {
  any = new AnyView($('#buildViewer'));
  $('#genBtn').onclick = () => busyButton($('#genBtn'), generate, 'Generating');
  $('#compileBtn').onclick = () => busyButton($('#compileBtn'), compile, 'Compiling (about a minute)…');
  $('#runBtn').onclick = runExe;
  $('#runStop').onclick = () => api.post('/api/build/stop').catch(fail);
  $('#buildPkg').onchange = refresh;
  $$('#buildView button').forEach(b => b.onclick = () => setView(b.dataset.v));
  on('build-output', d => log(d.text));
  on('matlab-output', d => { if (d.run === 'compile') log(d.text); });
  on('build', () => { refresh(); });
  on('log', e => { if (e.source === 'build') log(`» ${e.text}\n`, e.level); });
  on('config', refresh);
  await refresh();
  try {
    const c = await api.get('/api/config');
    const v = p => c.overrides[p] ?? (c.values || []).find(x => x.path === p)?.value ?? c.params.find(x => x.path === p)?.expr ?? '';
    $('#runH5').value = (v('data.hdf5_dir') + v('data.hdf5_file')).replace(/'/g, '').replace(/\/\//g, '/');
    $('#runStart').value = parseFloat(v('data.start_time_s')); $('#runEnd').value = parseFloat(v('data.end_time_s'));
  } catch {}
  $('#runOut').value = (state.project || '') + '/.studio_cache/standalone_test';
}
export function show() { refresh(); }

function log(text, level) {
  const pre = $('#buildLog');
  pre.append(level === 'err' ? el('span', { class: 'l-err', text }) : level === 'ok' ? el('span', { class: 'l-ok', text }) : document.createTextNode(text));
  pre.scrollTop = pre.scrollHeight;
}
function setView(v) {
  viewMode = v; $$('#buildView button').forEach(b => b.classList.toggle('active', b.dataset.v === v));
  $('#buildLog').hidden = v !== 'log'; $('#buildViewer').hidden = v !== 'cloud';
  if (v === 'cloud') loadCloud();
}
async function refresh() {
  try { S = await api.get('/api/build?package=' + encodeURIComponent(pkg())); } catch (e) { return fail(e); }
  const g = S.generated, n = Object.keys(S.overrides_now).length;
  $('#buildOvrN').textContent = n;
  $('#genPill').className = 'pill ' + (!g ? '' : S.up_to_date && !S.overrides_differ ? 'ok' : 'warn');
  $('#genPill').textContent = !g ? 'Not Generated' : S.up_to_date && !S.overrides_differ ? 'Up To Date' : 'Out Of Date';
  const gm = $('#genMeta'); gm.innerHTML = '';
  const rows = g ? [['Generated', fmtAgo(S.generated_at)], ['Files', g.files], ['Overrides Baked In', Object.keys(g.overrides || {}).length || 'none'],
    ['Newest Source', `${S.newest_source} (${fmtAgo(S.newest_source_at)})`]] : [['Package', `+${pkg()} does not exist yet`]];
  if (g && !S.up_to_date) rows.push(['Why Out Of Date', `${S.newest_source} changed after generating`]);
  if (g && S.overrides_differ) rows.push(['Why Out Of Date', 'The overrides differ from those baked in']);
  for (const [k, v] of rows) gm.append(el('dt', { text: k, title: v }), el('dd', { text: v, title: v }));
  $('#exePill').className = 'pill ' + (!S.exe ? '' : S.exe_up_to_date ? 'ok' : 'warn');
  $('#exePill').textContent = !S.exe ? 'Not Built' : S.exe_up_to_date ? 'Up To Date' : 'Older Than The Package';
  const em = $('#exeMeta'); em.innerHTML = '';
  for (const [k, v] of S.exe ? [['Executable', S.exe], ['Built', fmtAgo(S.exe_at)], ['Size', `${S.exe_size_kb} kB (+ MATLAB Runtime)`], ['Run With', S.matlab_root || '–']] : [['Executable', 'None Yet']])
    em.append(el('dt', { text: k }), el('dd', { text: v, title: v }));
  $('#compileBtn').disabled = !g; $('#runBtn').disabled = !S.exe;
  const r = S.run; const running = r?.running;
  $('#runPill').className = 'pill ' + (running ? 'busy' : r?.code === 0 ? 'ok' : r?.code ? 'err' : '');
  $('#runPill').textContent = running ? 'Running' : r?.code === 0 ? 'Finished' : r?.code ? `Failed (${r.code})` : '';
  $('#runBtn').hidden = !!running; $('#runStop').hidden = !running;
  const rs = $('#runSummary'); rs.innerHTML = '';
  if (r?.summary) {
    for (const [name, sec] of r.summary.stages || []) rs.append(el('dt', { text: name }), el('dd', { text: `${sec.toFixed(1)} s` }));
    if (r.summary.final) rs.append(el('dt', { text: 'Result' }), el('dd', { text: r.summary.final }));
    if (r.summary.total) rs.append(el('dt', { text: 'Total' }), el('dd', { text: `${(+r.summary.total).toFixed(0)} s` }));
  }
  if (r && !running && r.code === 0 && r.out && viewMode !== 'cloud' && r.finished && Date.now() / 1000 - r.finished < 5) setView('cloud');
}
async function generate() {
  log(`\n$ make_deployable.py --package ${pkg()}${$('#buildOvr').checked ? ' (with overrides)' : ''}\n`);
  try { const r = await api.post('/api/build/generate', { package: pkg(), overrides: $('#buildOvr').checked }); toast(r.output, 'ok'); await refresh(); }
  catch (e) { fail(e, 'Generate'); }
}
async function compile() {
  if (S && !S.up_to_date && !confirm('The package is older than the production code. Compile it anyway? (Generate first to include your latest changes.)')) return;
  setView('log'); log(`\n$ ${pkg()}.build_standalone   (in MATLAB)\n`);
  try { await api.post('/api/build/compile', { package: pkg() }); toast('Compiled', 'ok'); }
  catch (e) { fail(e, 'Compile'); if (e.data?.output) log(e.data.output, 'err'); }
  await refresh();
}
async function runExe() {
  setView('log'); log(`\n$ run_posefromevents.sh … ${$('#runH5').value} ${$('#runStart').value} ${$('#runEnd').value}\n`);
  try { await api.post('/api/build/run', { package: pkg(), hdf5: $('#runH5').value, start: +$('#runStart').value, end: +$('#runEnd').value, out: $('#runOut').value }); await refresh(); }
  catch (e) { fail(e, 'Run'); }
}
async function loadCloud() {
  try { const p = await api.get('/api/build/cloud?out=' + encodeURIComponent($('#runOut').value)); any.show(p); }
  catch (e) { fail(e); }
}
