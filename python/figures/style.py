"""Shared figure style: SRL template palette (theme2.xml), Arial-metric sans, vector output."""
import os
import sys
import pickle
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
CACHE = os.environ.get('ESFM_CACHE', os.path.join(os.path.dirname(HERE), 'cache'))
OUT = os.environ.get('ESFM_FIGOUT', os.path.join(HERE, 'out'))
os.makedirs(OUT, exist_ok=True)

# template theme colours
RED = '#E91C24'
BLACK = '#000000'
DARK = '#414141'
GREY = '#A0A0A0'
LIGHT = '#D5D5D5'
PALE = '#E7E6E6'
PINK = '#FBD2D3'
GREEN = '#038044'
BLUE = '#1166AA'
POS, NEG = RED, BLUE          # event polarity

CMAP_RED = LinearSegmentedColormap.from_list('srl_red', ['#FFFFFF', PINK, RED, '#7A0D12'])
CMAP_TIME = LinearSegmentedColormap.from_list('srl_time', ['#1166AA', '#6FA8D6', '#D5D5D5', '#F08A8E', '#E91C24'])
CMAP_GREYRED = LinearSegmentedColormap.from_list('srl_gr', [LIGHT, GREY, DARK, RED])

plt.rcParams.update({
    'font.family': 'sans-serif',
    'font.sans-serif': ['Liberation Sans', 'Arimo', 'Arial', 'DejaVu Sans'],
    'mathtext.fontset': 'cm',
    'font.size': 10,
    'axes.titlesize': 10.5,
    'axes.titleweight': 'bold',
    'axes.labelsize': 10,
    'axes.labelcolor': DARK,
    'axes.edgecolor': DARK,
    'axes.linewidth': 0.7,
    'axes.spines.top': False,
    'axes.spines.right': False,
    'axes.grid': False,
    'grid.color': PALE,
    'grid.linewidth': 0.6,
    'xtick.color': DARK,
    'ytick.color': DARK,
    'xtick.labelsize': 8.5,
    'ytick.labelsize': 8.5,
    'xtick.major.width': 0.6,
    'ytick.major.width': 0.6,
    'xtick.major.size': 3,
    'ytick.major.size': 3,
    'legend.fontsize': 8.5,
    'legend.frameon': False,
    'figure.dpi': 100,
    'savefig.transparent': True,
    'svg.fonttype': 'path',
    'lines.linewidth': 1.4,
    'lines.solid_capstyle': 'round',
})


def save(fig, name, dpi=220):
    fig.savefig(os.path.join(OUT, name + '.svg'), bbox_inches=None)
    fig.savefig(os.path.join(OUT, name + '.png'), dpi=dpi, bbox_inches=None)
    plt.close(fig)
    print('wrote', name)


def load(name):
    with open(os.path.join(CACHE, name + '.pkl'), 'rb') as fh:
        return pickle.load(fh)


def npz(name):
    return np.load(os.path.join(CACHE, name + '.npz'))


def label(ax, text, loc='left'):
    ax.set_title(text, loc=loc, color=BLACK, pad=4)


def event_image(x, y, p=None, shape=(480, 640), signed=True):
    """Accumulate events into an image (signed by polarity, or counts)."""
    img = np.zeros(shape)
    xi = np.clip(np.round(x).astype(int), 0, shape[1] - 1)
    yi = np.clip(np.round(y).astype(int), 0, shape[0] - 1)
    np.add.at(img, (yi, xi), p if (signed and p is not None) else 1)
    return img
