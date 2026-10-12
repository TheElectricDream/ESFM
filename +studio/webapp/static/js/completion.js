// Completion and help data for both editors: the pipeline's functions, cfg fields,
// workspace variables and MATLAB's keywords/common functions.
import { api } from './app.js';

const BUILTINS = ('abs accumarray all any arrayfun assert atan2 bsxfun cat ceil cell cell2mat cellfun char class clc clear clearvars close cos cosd ' +
  'cross cumsum deal deg2rad diag diff disp double eig end error eval evalin exist exp eye false fieldnames figure find fix floor fprintf ' +
  'fullfile func2str hist histcounts hold ifelse imagesc inv isempty isequal isfield isfinite ismember isnan isnumeric isrow isscalar isstruct ' +
  'isvector jsondecode jsonencode keys length linspace load log log10 log1p logical max mean median min mod nan nnz norm numel num2str ones ' +
  'permute plot plot3 prctile rad2deg rand randn rangesearch knnsearch repmat reshape rmfield round save scatter scatter3 setfield sign sin sind ' +
  'single size sort sortrows sprintf sqrt squeeze std strcat strcmp strjoin strsplit struct sum svd tan tic toc true uint8 uint16 unique ' +
  'vecnorm vertcat warning whos xlabel ylabel zeros pagemtimes pageinv sparse full spdiags interp1 findgroups splitapply').split(' ');
const KEYWORDS = 'break case catch continue else elseif end for function global if otherwise parfor persistent return switch try while'.split(' ');

let symbols = null;
let workspace = [];
export function setWorkspace(names) { workspace = names; }
export async function loadSymbols(force = false) {
  if (!symbols || force) symbols = await api.get('/api/code/symbols').catch(() => ({ functions: [], cfg: [] }));
  return symbols;
}
export function funcInfo(name) { return symbols?.functions.find(f => f.text === name); }
export function cfgInfo(name) { return symbols?.cfg.find(f => f.text === name); }

export function hint(cm) {
  const cur = cm.getCursor(), line = cm.getLine(cur.line).slice(0, cur.ch);
  const m = line.match(/[A-Za-z_][\w.]*$/); const word = m ? m[0] : '';
  const from = CodeMirror.Pos(cur.line, cur.ch - word.length);
  const lw = word.toLowerCase(); const list = [];
  const add = (text, kind, doc, render) => { if (text.toLowerCase().startsWith(lw) && text !== word) list.push({ text, displayText: text, kind, doc, render }); };
  const R = (text, k, doc) => (elt) => { elt.innerHTML = ''; elt.append(text); const s = document.createElement('span'); s.className = 'hk'; s.textContent = k + (doc ? ' · ' + doc.slice(0, 70) : ''); elt.append(s); };
  if (symbols) {
    for (const f of symbols.functions) add(f.text, 'fn', f.h1, R(f.text, 'function', f.h1));
    for (const c of symbols.cfg) add(c.text, 'cfg', c.doc, R(c.text, c.kind, c.doc));
    if (!word.includes('.')) {
      const pk = [...new Set(symbols.functions.map(f => f.text.split('.')[0]))];
      for (const p of pk) add(p + '.', 'pkg', '', R(p + '.', 'package', ''));
    }
  }
  if (!word.includes('.')) {
    for (const w of workspace) add(w, 'var', '', R(w, 'variable', ''));
    for (const k of KEYWORDS) add(k, 'kw', '', R(k, 'keyword', ''));
    for (const b of BUILTINS) add(b, 'builtin', '', R(b, 'MATLAB', ''));
  }
  const order = { var: 0, fn: 1, cfg: 1, pkg: 2, kw: 3, builtin: 4 };
  list.sort((a, b) => (order[a.kind] - order[b.kind]) || a.text.localeCompare(b.text));
  const seen = new Set(); const uniq = list.filter(x => !seen.has(x.text) && seen.add(x.text)).slice(0, 80);
  return { list: uniq.map(x => ({ text: x.text, render: x.render })), from, to: cur };
}

// Package and cfg references get their own colours on top of the octave mode
export function overlay() {
  return {
    token(stream) {
      if (stream.sol() && stream.match(/^%%\s*\[step\].*/)) return 'step';
      if (stream.match(/^cfg(\.[A-Za-z]\w*)+/)) return 'cfg';
      if (symbols && stream.match(/^[a-z]\w*\.[A-Za-z]\w*/, false)) {
        const m = stream.match(/^[a-z]\w*\.[A-Za-z]\w*/, false)[0];
        if (symbols.functions.some(f => f.text === m)) { stream.match(m); return 'pkg'; }
      }
      while (stream.next() != null && !stream.match(/^(cfg\.|[a-z]\w*\.)/, false)) { if (stream.peek() === '%') break; }
      return null;
    },
  };
}
