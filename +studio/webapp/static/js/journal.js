// Journal page: notes you send (saved with the time) and the Studio's activity,
// grouped into summaries, as a chat-like timeline. Stored in <project>/journal.jsonl.
import { $, api, el, fail, on, toast } from './app.js';

let entries = [], atBottom = true;
const GAP = 30 * 60;     // activity entries closer than this form one summary

export async function init() {
  $('#jrnSend').onclick = send;
  $('#jrnText').onkeydown = e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } };
  $('#jrnText').oninput = grow;
  $('#jrnFilter').oninput = render; $('#jrnAuto').onchange = render;
  $('#jrnExport').onclick = async () => { try { const r = await api.post('/api/journal/export'); toast(`Written: ${r.path}`, 'ok'); } catch (e) { fail(e); } };
  $('#jrnList').addEventListener('scroll', () => { const l = $('#jrnList'); atBottom = l.scrollTop + l.clientHeight > l.scrollHeight - 40; });
  on('journal', e => {
    if (e.deleted) entries = entries.filter(x => x.id !== e.deleted);
    else if (!entries.some(x => x.id === e.id)) entries.push(e);
    render();
  });
  await load();
}
export function show() { render(true); $('#jrnText').focus(); }

async function load() { try { entries = (await api.get('/api/journal')).entries; render(true); } catch (e) { fail(e); } }
function grow() { const t = $('#jrnText'); t.style.height = 'auto'; t.style.height = Math.min(220, t.scrollHeight + 2) + 'px'; }
async function send() {
  const t = $('#jrnText'), text = t.value.trim(); if (!text) return;
  t.disabled = true;
  try { const e = await api.post('/api/journal', { text }); if (!entries.some(x => x.id === e.id)) entries.push(e); t.value = ''; grow(); atBottom = true; render(true); }
  catch (e) { fail(e); } finally { t.disabled = false; t.focus(); }
}
async function del(id) {
  if (!confirm('Delete this note?')) return;
  try { await api.post('/api/journal/delete', { id }); entries = entries.filter(x => x.id !== id); render(); } catch (e) { fail(e); }
}

const fmtT = t => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
const fmtDay = t => new Date(t * 1000).toLocaleDateString([], { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });

function render(scroll) {
  const list = $('#jrnList'), q = $('#jrnFilter').value.toLowerCase(), showAuto = $('#jrnAuto').checked;
  const items = entries.slice().sort((a, b) => a.t - b.t).filter(e => (showAuto || e.kind !== 'auto') && (!q || e.text.toLowerCase().includes(q)));
  list.innerHTML = '';
  let day = null, group = null;
  const flush = () => {
    if (!group) return;
    const a = group[0].t, b = group[group.length - 1].t, errs = group.filter(g => g.level === 'err').length;
    const ul = el('ul');
    for (const g of group) ul.append(el('li', { class: g.level === 'err' ? 'err' : '', title: `${g.source}: ${g.text}` }, el('span', { class: 't', text: fmtT(g.t) }), g.text));
    list.append(el('div', { class: 'j-msg activity', title: 'Recorded automatically by the Studio' },
      el('div', { class: 'j-head', text: `Activity · ${group.length} Event${group.length === 1 ? '' : 's'}${errs ? ` · ${errs} Failed` : ''}` }), ul,
      el('span', { class: 'j-time', text: a === b ? fmtT(a) : `${fmtT(a)} – ${fmtT(b)}` })));
    group = null;
  };
  for (const e of items) {
    const d = new Date(e.t * 1000).toDateString();
    if (d !== day) { flush(); day = d; list.append(el('div', { class: 'j-day', text: fmtDay(e.t) })); }
    if (e.kind === 'auto') {
      if (group && e.t - group[group.length - 1].t > GAP) flush();
      (group ||= []).push(e); continue;
    }
    flush();
    const box = el('div', { class: `j-msg ${e.kind === 'note' ? 'note' : 'summary'}`, title: e.kind === 'note' ? 'Your note' : 'Summary of the work (written by the Studio)' });
    if (e.kind === 'summary') box.append(el('div', { class: 'j-head', text: 'Summary' }));
    box.append(document.createTextNode(e.text), el('span', { class: 'j-time', text: fmtT(e.t), title: new Date(e.t * 1000).toLocaleString() }));
    if (e.kind === 'note') box.append(el('button', { class: 'btn btn-ghost btn-xs j-del', text: '✕', title: 'Delete this note', onclick: () => del(e.id) }));
    list.append(box);
  }
  flush();
  if (!items.length) list.append(el('div', { class: 'j-day', text: q ? 'Nothing Matches' : 'No Entries Yet' }));
  const n = entries.filter(e => e.kind === 'note').length;
  $('#jrnMeta').textContent = `${n} Note${n === 1 ? '' : 's'} · ${entries.length - n} Other Entries`;
  if (scroll || atBottom) list.scrollTop = list.scrollHeight;
}
