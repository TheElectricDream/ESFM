"""python-pptx helpers on top of the SRL template: SVG pictures with PNG fallback,
text boxes, movies, speaker notes, and slide cleanup."""
import copy
import os
from lxml import etree
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.opc.package import Part
from pptx.opc.packuri import PackURI
from pptx.opc.constants import RELATIONSHIP_TYPE as RT

SVG_EXT_URI = '{96DAC541-7B7A-43D3-8B79-37D633B846F1}'
NS_ASVG = 'http://schemas.microsoft.com/office/drawing/2016/SVG/main'
NS_A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
NS_R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
NS_P = 'http://schemas.openxmlformats.org/presentationml/2006/main'

RED = RGBColor(0xE9, 0x1C, 0x24)
DARK = RGBColor(0x41, 0x41, 0x41)
BLACK = RGBColor(0, 0, 0)
GREY = RGBColor(0xA0, 0xA0, 0xA0)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

_svg_count = [0]


def open_template(path):
    prs = Presentation(path)
    layouts = {}
    for s in prs.slides:
        layouts.setdefault('title', None)
    sl = list(prs.slides)
    L = dict(title=sl[0].slide_layout, content=sl[1].slide_layout, section=sl[2].slide_layout, end=sl[3].slide_layout)
    # remove the four sample slides
    sldIdLst = prs.slides._sldIdLst
    for sldId in list(sldIdLst):
        prs.part.drop_rel(sldId.rId)
        sldIdLst.remove(sldId)
    return prs, L


def strip_empty_placeholders(slide, keep=('title', 'ctrTitle', 'subTitle')):
    for ph in list(slide.placeholders):
        t = ph.placeholder_format.type
        name = str(t).split('.')[-1].split(' ')[0].lower()
        if ph.has_text_frame and ph.text_frame.text.strip():
            continue
        ph._element.getparent().remove(ph._element)


def add_svg(slide, svg_path, png_path, x, y, w=None, h=None, name=None):
    """Insert PNG (fallback) and attach the SVG via the Office 2016 svgBlip extension."""
    kw = {}
    if w is not None:
        kw['width'] = Inches(w)
    if h is not None:
        kw['height'] = Inches(h)
    pic = slide.shapes.add_picture(png_path, Inches(x), Inches(y), **kw)
    if name:
        pic.name = name
    _svg_count[0] += 1
    pkg = slide.part.package
    partname = PackURI(f'/ppt/media/vec{_svg_count[0]:04d}.svg')
    svg_part = Part(partname, 'image/svg+xml', pkg, open(svg_path, 'rb').read())
    rId = slide.part.relate_to(svg_part, RT.IMAGE)
    blip = pic._element.find('.//{%s}blip' % NS_A)
    extLst = etree.SubElement(blip, '{%s}extLst' % NS_A)
    ext = etree.SubElement(extLst, '{%s}ext' % NS_A, uri=SVG_EXT_URI)
    sb = etree.SubElement(ext, '{%s}svgBlip' % NS_ASVG, nsmap={'asvg': NS_ASVG})
    sb.set('{%s}embed' % NS_R, rId)
    return pic


def add_text(slide, x, y, w, h, runs, size=14, color=DARK, bold=False, align='l', anchor='t',
             italic=False, line_spacing=None, name=None, font='Arial', space_after=0):
    """runs: str, or list of paragraphs; each paragraph a str or list of (text, dict(style)) tuples."""
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    if name:
        tb.name = name
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = {'t': MSO_ANCHOR.TOP, 'm': MSO_ANCHOR.MIDDLE, 'b': MSO_ANCHOR.BOTTOM}[anchor]
    paras = [runs] if isinstance(runs, str) else runs
    for i, para in enumerate(paras):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = {'l': PP_ALIGN.LEFT, 'c': PP_ALIGN.CENTER, 'r': PP_ALIGN.RIGHT}[align]
        if line_spacing:
            p.line_spacing = line_spacing
        if space_after:
            p.space_after = Pt(space_after)
        segs = [(para, {})] if isinstance(para, str) else para
        for text, st in segs:
            r = p.add_run()
            r.text = text
            f = r.font
            f.name = st.get('font', font)
            f.size = Pt(st.get('size', size))
            f.bold = st.get('bold', bold)
            f.italic = st.get('italic', italic)
            f.color.rgb = st.get('color', color)
    return tb


def set_title(slide, text, size=None):
    t = slide.shapes.title
    t.text_frame.text = text
    if size:
        for r in t.text_frame.paragraphs[0].runs:
            r.font.size = Pt(size)
    return t


def add_movie(slide, mp4, poster_png, x, y, w, h, name=None):
    mv = slide.shapes.add_movie(mp4, Inches(x), Inches(y), Inches(w), Inches(h),
                                poster_frame_image=poster_png, mime_type='video/mp4')
    if name:
        mv.name = name
    return mv


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text
