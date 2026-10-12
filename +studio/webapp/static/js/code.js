// Code page: the pipeline's .m files in an editor with completion, help on hover,
// go-to-definition (Ctrl+click), callers, and MATLAB's Code Analyzer.
import { $, $$, api, debounce, el, esc, fail, on, state, tc, toast } from './app.js';
import { funcInfo, hint, loadSymbols, overlay } from './completion.js';

let cm, files = [], tabs = [], current = null, collapsed = new Set(['deployable']), tip;

export async function init() {
  cm = CodeMirror($('#editorWrap'), {
    mode: 'octave', theme: 'studio', lineNumbers: true, matchBrackets: true, autoCloseBrackets: true, styleActiveLine: true,
    indentUnit: 4, tabSize: 4, indentWithTabs: false, gutters: ['CodeMirror-linenumbers', 'lint'],
    extraKeys: {
      'Ctrl-S': () => save(), 'Cmd-S': () => save(), 'Ctrl-Space': c => c.showHint({ hint, completeSingle: false }),
      'Ctrl-/': 'toggleComment', 'Cmd-/': 'toggleComment', Tab: c => c.somethingSelected() ? c.indentSelection('add') : c.replaceSelection('    '),
      'Ctrl-G': 'jumpToLine', 'Ctrl-F': 'findPersistent',
    },
  });
  cm.addOverlay(overlay());
  cm.getWrapperElement().hidden = true;
  cm.on('inputRead', (c, ch) => { if (ch.text[0] === '.' || /^[A-Za-z]$/.test(ch.text[0]) && wordBefore(c).length >= 3) c.showHint({ hint, completeSingle: false }); });
  const liveLint = debounce(() => lint(), 600);
  cm.on('change', () => { if (current) { current.dirty = current.doc.getValue() !== current.saved; renderTabs(); renderTree(); liveLint(); } });
  cm.on('cursorActivity', () => { const p = cm.getCursor(); $('#editorPos').textContent = `Ln ${p.line + 1}, Col ${p.ch + 1}`; });
  tip = el('div', { class: 'cm-tooltip', hidden: true }); document.body.append(tip);
  cm.getWrapperElement().addEventListener('mousemove', hover);
  cm.getWrapperElement().addEventListener('mouseleave', () => { tip.hidden = true; });
  cm.getWrapperElement().addEventListener('mousedown', e => { if (e.ctrlKey || e.metaKey) { const f = symbolAt(e); if (f) { e.preventDefault(); openFunc(f.text); } } });
  $('#codeFilter').oninput = renderTree;
  $('#codeSave').onclick = () => save();
  $('#codeRevert').onclick = revert;
  $('#codeOpenMatlab').onclick = () => current && api.post('/api/code/open', { path: current.path, line: cm.getCursor().line + 1 }).catch(fail);
  window.addEventListener('beforeunload', e => { if (tabs.some(t => t.dirty)) { e.preventDefault(); e.returnValue = ''; } });
  on('code-saved', d => { const t = tabs.find(x => x.path === d.path); if (t && !t.dirty) reloadTab(t); });
  await Promise.all([loadIndex(), loadSymbols()]);
  const last = JSON.parse(localStorage.getItem('studio.tabs') || '[]');
  for (const p of last) if (files.some(f => f.path === p)) await openFile(p, null, true);
  if (!tabs.length) await openFile('main.m');
}
export async function show(arg) {
  cm.refresh();
  if (arg?.path) await openFile(arg.path, arg.line);
  if (arg?.func) await openFunc(arg.func);
}

const wordBefore = c => (c.getLine(c.getCursor().line).slice(0, c.getCursor().ch).match(/[A-Za-z_][\w.]*$/) || [''])[0];

async function loadIndex() { const r = await api.get('/api/code/index'); files = r.files; renderTree(); }
function renderTree() {
  const box = $('#fileTree'); box.innerHTML = ''; const q = $('#codeFilter').value.toLowerCase();
  const groups = new Map([['Scripts', []]]);
  for (const f of files) { const g = f.pkg ? '+' + f.pkg.split('.')[0] : f.path.startsWith('tests/') ? 'tests' : 'Scripts'; if (!groups.has(g)) groups.set(g, []); groups.get(g).push(f); }
  for (const [g, list] of groups) {
    const shown = list.filter(f => !q || f.full.toLowerCase().includes(q) || (f.h1 || '').toLowerCase().includes(q));
    if (!shown.length) continue;
    const key = g.replace('+', ''); const closed = collapsed.has(key) && !q;
    box.append(el('div', { class: 'pkg', title: closed ? 'Show its files' : 'Hide its files', onclick: () => { collapsed.has(key) ? collapsed.delete(key) : collapsed.add(key); renderTree(); } },
      el('span', { text: (closed ? '▸ ' : '▾ ') + g + (list[0]?.readonly ? '  (generated)' : '') }), el('span', { text: shown.length })));
    if (closed) continue;
    for (const f of shown) {
      const t = tabs.find(x => x.path === f.path);
      box.append(el('div', { class: `f ${current?.path === f.path ? 'sel' : ''} ${f.readonly ? 'ro' : ''}`, title: f.h1 || f.path, onclick: () => openFile(f.path) },
        el('span', { text: f.name }), t?.dirty ? el('span', { class: 'dot' }) : null));
    }
  }
}

async function openFile(path, line, quiet) {
  let t = tabs.find(x => x.path === path);
  if (!t) {
    try {
      const r = await api.get('/api/code/file?path=' + encodeURIComponent(path));
      t = { path, doc: CodeMirror.Doc(r.text, 'octave'), saved: r.text, mtime: r.mtime, readonly: r.readonly, entry: r.entry, dirty: false, lint: [] };
      tabs.push(t);
    } catch (e) { if (!quiet) fail(e); return; }
  }
  select(t);
  if (line) { cm.setCursor({ line: line - 1, ch: 0 }); cm.scrollIntoView({ line: line - 1, ch: 0 }, 120); cm.focus(); }
  lint();
  localStorage.setItem('studio.tabs', JSON.stringify(tabs.map(x => x.path)));
}
async function openFunc(full) {
  const f = files.find(x => x.full === full); if (!f) return toast(`${full} is not a pipeline function`, 'warn');
  await openFile(f.path, 1);
}
function select(t) {
  current = t; $('#editorEmpty').hidden = true; cm.getWrapperElement().hidden = false;
  cm.swapDoc(t.doc); cm.setOption('readOnly', t.readonly); cm.refresh();
  $('#editorPath').textContent = t.path + (t.readonly ? '  (Generated, Read-Only: Edit Production And Regenerate On The Build Page)' : '');
  $('#codeSave').disabled = t.readonly;
  renderTabs(); renderTree(); renderSide(); showLint();
}
function renderTabs() {
  const box = $('#editorTabs'); box.innerHTML = '';
  for (const t of tabs) {
    const x = el('span', { class: 'x', text: '✕', onclick: e => { e.stopPropagation(); close(t); } });
    x.title = 'Close';
    box.append(el('button', { class: `${t === current ? 'active' : ''} ${t.dirty ? 'dirty' : ''}`, onclick: () => select(t), title: t.path + (t.dirty ? ' (unsaved changes)' : '') }, el('span', { class: 'nm', text: t.path.split('/').pop() }), x));
  }
}
function close(t) {
  if (t.dirty && !confirm(`${t.path} has unsaved changes. Close it anyway?`)) return;
  tabs = tabs.filter(x => x !== t); localStorage.setItem('studio.tabs', JSON.stringify(tabs.map(x => x.path)));
  if (current === t) { if (tabs.length) select(tabs[tabs.length - 1]); else { current = null; cm.getWrapperElement().hidden = true; $('#editorEmpty').hidden = false; renderTabs(); renderSide(); } }
  else renderTabs();
}
async function save(force = false) {
  const t = current; if (!t || t.readonly) return;
  const text = t.doc.getValue();
  try {
    const r = await api.post('/api/code/file', { path: t.path, text, mtime: t.mtime, force });
    t.saved = text; t.mtime = r.mtime; t.dirty = false; renderTabs(); renderTree();
    toast(`Saved ${t.path}`, 'ok', 2000);
    loadIndex(); loadSymbols(true).then(renderSide);
    lint();
  } catch (e) {
    if (e.data?.conflict) { if (confirm(`${t.path} changed on disk since you opened it (saved in MATLAB?).\n\nOK overwrites it with your version; Cancel keeps the disk version (use Revert to load it).`)) save(true); }
    else fail(e, 'Save');
  }
}
async function revert() {
  const t = current; if (!t) return; if (t.dirty && !confirm('Discard your changes and reload from disk?')) return; await reloadTab(t);
}
async function reloadTab(t) {
  const r = await api.get('/api/code/file?path=' + encodeURIComponent(t.path));
  const pos = t === current ? cm.getCursor() : null;
  t.doc.setValue(r.text); t.saved = r.text; t.mtime = r.mtime; t.dirty = false;
  if (pos) cm.setCursor(pos); renderTabs(); renderTree();
}

// ---------------- side panel ----------------
async function renderSide() {
  const t = current, f = t ? files.find(x => x.path === t.path) : null;
  const doc = $('#docBox'); doc.innerHTML = '';
  if (!f) { doc.textContent = '–'; $('#callerList').innerHTML = ''; $('#callsList').innerHTML = ''; return; }
  doc.title = 'The function\'s signature and help text';
  doc.append(el('div', { class: 'doc-sig', text: f.signature || f.kind }), el('pre', { class: 'doc-help', text: funcInfo(f.full)?.help || f.h1 || '' }));
  const calls = $('#callsList'); calls.innerHTML = '';
  for (const r of f.refs.filter(r => files.some(x => x.full === r && !x.readonly))) calls.append(el('a', { text: r, title: `Open ${r}`, onclick: () => openFunc(r) }));
  if (!calls.childElementCount) calls.append(el('span', { class: 'muted small', text: 'No pipeline functions.' }));
  const cl = $('#callerList'); cl.innerHTML = '<span class="muted small">…</span>';
  if (!f.pkg) { cl.innerHTML = '<span class="muted small">(script)</span>'; $('#callerCount').textContent = '–'; return; }
  try {
    const r = await api.get('/api/code/callers?name=' + encodeURIComponent(f.full)); cl.innerHTML = '';
    const own = r.callers.filter(c => !c.path.startsWith('+deployable'));
    $('#callerCount').textContent = own.length;
    for (const c of own) cl.append(el('a', { title: `${c.path}:${c.line}\n${c.text}`, onclick: () => openFile(c.path, c.line) }, el('span', { class: 'ln', text: `${c.path.replace(/^\+/, '')}:${c.line}` }), c.text));
    if (!own.length) cl.append(el('span', { class: 'muted small', text: 'Not called by the pipeline.' }));
  } catch { cl.innerHTML = ''; }
}

// ---------------- live checks ----------------
// The unsaved text is checked as you type: the Studio's own checks at once (unknown
// pipeline functions and cfg fields, names that exist nowhere), MATLAB's Code
// Analyzer on top whenever MATLAB is free.
let lintSeq = 0, marks = [];
async function lint() {
  const t = current; if (!t || !/\.m$/.test(t.path)) return;
  const seq = ++lintSeq, text = t.doc.getValue();
  $('#lintState').textContent = 'Checking…';
  try {
    const r = await api.post('/api/code/lint', { path: t.path, text });
    if (seq !== lintSeq || t !== current || t.doc.getValue() !== text) return;
    t.lint = r.messages; t.lintMatlab = r.matlab; showLint();
  } catch (e) { if (seq === lintSeq) $('#lintState').textContent = ''; }
}
function showLint() {
  for (const m of marks) m.clear(); marks = [];
  cm.clearGutter('lint');
  const list = $('#lintList'); list.innerHTML = ''; const t = current;
  if (!t || !t.lint) { $('#lintCount').textContent = '–'; $('#lintState').textContent = ''; return; }
  const errs = t.lint.filter(m => m.severity === 'error').length;
  $('#lintCount').textContent = t.lint.length;
  $('#lintState').textContent = (t.lint.length ? `${errs} Error${errs === 1 ? '' : 's'}, ${t.lint.length - errs} Warning${t.lint.length - errs === 1 ? '' : 's'}` : 'No Problems')
    + (t.lintMatlab ? '' : ' · MATLAB Busy: Studio Checks Only');
  $('#lintState').className = 'small ' + (errs ? 'err-text' : t.lint.length ? 'warn-text' : 'ok-text');
  if (!t.lint.length) list.append(el('span', { class: 'muted small', text: 'No problems found.' }));
  const byLine = new Map();
  for (const m of t.lint) {
    const ln = Math.max(0, m.line - 1), text = cm.getLine(ln) ?? '';
    const from = Math.max(0, (m.col || 1) - 1), to = Math.max(from + 1, Math.min(text.length, (m.end || m.col + 1) - 1));
    marks.push(cm.markText({ line: ln, ch: from }, { line: ln, ch: to }, { className: m.severity === 'error' ? 'cm-lint-error' : 'cm-lint-warning', title: m.message, attributes: { title: m.message } }));
    const prev = byLine.get(ln); byLine.set(ln, prev ? prev + '\n' + m.message : m.message);
    cm.setGutterMarker(ln, 'lint', el('div', { class: 'lint-gutter' + (m.severity === 'error' || /err/.test(cm.lineInfo(ln)?.gutterMarkers?.lint?.className || '') ? ' err' : ''), text: m.severity === 'error' ? '●' : '▲', title: byLine.get(ln) }));
    list.append(el('div', { class: 'lint-item', title: `${m.message}\n(${m.source === 'matlab' ? "MATLAB's Code Analyzer" : 'Studio check'}; click to go to line ${m.line})`, onclick: () => { cm.setCursor({ line: ln, ch: from }); cm.scrollIntoView({ line: ln, ch: 0 }, 120); cm.focus(); } },
      el('span', { class: `sev ${m.severity}` }), el('span', { class: 'ln', text: `L${m.line}` }), m.message, el('span', { class: 'src', text: m.source === 'matlab' ? 'MATLAB' : 'Studio' })));
  }
}

// ---------------- hover help ----------------
function symbolAt(e) {
  const pos = cm.coordsChar({ left: e.clientX, top: e.clientY }); const line = cm.getLine(pos.line) || '';
  const re = /[a-z]\w*\.[A-Za-z]\w*/g; let m;
  while ((m = re.exec(line))) if (pos.ch >= m.index && pos.ch <= m.index + m[0].length) return funcInfo(m[0]);
  return null;
}
function hover(e) {
  const f = symbolAt(e);
  if (!f) { tip.hidden = true; return; }
  tip.hidden = false; tip.innerHTML = `<b>${esc(f.sig || f.text)}</b>\n${esc((f.help || '').split('\n').slice(0, 18).join('\n'))}\n<span class="muted">Ctrl+Click To Open</span>`;
  tip.style.left = Math.min(e.clientX + 14, innerWidth - 540) + 'px'; tip.style.top = Math.min(e.clientY + 16, innerHeight - 300) + 'px';
}
