"""LaTeX equation -> vector SVG (dvisvgm, glyphs as paths) + transparent PNG fallback (dvipng).
Natural size is kept so every equation sits at the same point size on the slides."""
import os
import re
import subprocess
import tempfile
import hashlib

OUT = os.environ.get('ESFM_EQOUT', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'eq'))
os.makedirs(OUT, exist_ok=True)

PRE = r"""\documentclass[preview,border=1pt]{standalone}
\usepackage{amsmath,amssymb,bm,xcolor,mathtools}
\definecolor{srlred}{HTML}{E91C24}
\definecolor{srlgrey}{HTML}{414141}
\definecolor{srlblue}{HTML}{1166AA}
\definecolor{srlgreen}{HTML}{038044}
\newcommand{\R}[1]{\textcolor{srlred}{#1}}
\newcommand{\G}[1]{\textcolor{srlgrey}{#1}}
\newcommand{\B}[1]{\textcolor{srlblue}{#1}}
\newcommand{\vect}[1]{\mathbf{#1}}
\begin{document}
"""


def render(name, body, pt=17):
    """body: LaTeX (math mode content of an align*-like block or plain text). Returns (w_in, h_in)."""
    tex = PRE + r'\fontsize{%g}{%g}\selectfont' % (pt, pt * 1.25) + '\n' + body + '\n\\end{document}\n'
    svg = os.path.join(OUT, name + '.svg')
    png = os.path.join(OUT, name + '.png')
    stamp = os.path.join(OUT, name + '.hash')
    h = hashlib.md5(tex.encode()).hexdigest()
    if not (os.path.exists(svg) and os.path.exists(stamp) and open(stamp).read() == h):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, 'e.tex'), 'w').write(tex)
            r = subprocess.run(['latex', '-interaction=nonstopmode', 'e.tex'], cwd=d, capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(name + '\n' + r.stdout[-2500:])
            subprocess.run(['dvisvgm', '--no-fonts', '--exact-bbox', '-o', svg, 'e.dvi'], cwd=d, check=True, capture_output=True)
            subprocess.run(['dvipng', '-D', '600', '-bg', 'Transparent', '-T', 'tight', '-o', png, 'e.dvi'], cwd=d, check=True, capture_output=True)
        open(stamp, 'w').write(h)
    s = open(svg).read(3000)
    w = float(re.search(r'width=["\']([\d.]+)pt', s).group(1))
    hh = float(re.search(r'height=["\']([\d.]+)pt', s).group(1))
    return w / 72.0, hh / 72.0


if __name__ == '__main__':
    print(render('test', r'$\displaystyle \theta_d = \theta\,(1 + \R{k_1}\theta^2 + k_2\theta^4)$'))
