"""
Create a styled reference.docx template for pandoc.
Background-agnostic: no coloured fills, visible borders, clean typography.
"""
from docx import Document
from docx.shared import Pt, Inches, Cm, RGBColor
from docx.enum.style import WD_STYLE_TYPE
from docx.oxml.ns import qn, nsdecls
from docx.oxml import parse_xml

doc = Document()

# -- Page setup (A4) --
for section in doc.sections:
    section.page_width = Inches(8.27)
    section.page_height = Inches(11.69)
    section.top_margin = Cm(2)
    section.bottom_margin = Cm(2)
    section.left_margin = Cm(2.5)
    section.right_margin = Cm(2.5)

# -- Colours (background-agnostic — no fills, just text colours) --
DARK = RGBColor(0x1A, 0x1A, 0x1A)
MID = RGBColor(0x33, 0x33, 0x33)
ACCENT = RGBColor(0xCC, 0x00, 0x00)
BORDER = "666666"

# -- Normal --
style = doc.styles['Normal']
style.font.name = 'Calibri'
style.font.size = Pt(10.5)
style.font.color.rgb = MID
style.paragraph_format.space_after = Pt(6)
style.paragraph_format.line_spacing = 1.15

# -- Headings --
configs = [
    ('Heading 1', Pt(22), DARK, True, Pt(24), Pt(6)),
    ('Heading 2', Pt(16), DARK, True, Pt(18), Pt(4)),
    ('Heading 3', Pt(13), DARK, True, Pt(12), Pt(3)),
    ('Heading 4', Pt(11), DARK, True, Pt(10), Pt(2)),
    ('Heading 5', Pt(10.5), DARK, True, Pt(8), Pt(2)),
    ('Heading 6', Pt(10.5), MID, True, Pt(6), Pt(2)),
]
for name, size, color, bold, sb, sa in configs:
    s = doc.styles[name]
    s.font.name = 'Calibri'
    s.font.size = size
    s.font.color.rgb = color
    s.font.bold = bold
    s.paragraph_format.space_before = sb
    s.paragraph_format.space_after = sa
    s.paragraph_format.keep_with_next = True

# Underline on H1 and H2
for hname in ['Heading 1', 'Heading 2']:
    pPr = doc.styles[hname].element.get_or_add_pPr()
    pPr.append(parse_xml(
        f'<w:pBdr {nsdecls("w")}>'
        f'  <w:bottom w:val="single" w:sz="6" w:space="4" w:color="{BORDER}"/>'
        f'</w:pBdr>'
    ))

# -- Code --
for code_name in ['Source Code', 'Verbatim Char']:
    try:
        s = doc.styles[code_name]
    except KeyError:
        stype = WD_STYLE_TYPE.PARAGRAPH if code_name == 'Source Code' else WD_STYLE_TYPE.CHARACTER
        s = doc.styles.add_style(code_name, stype)
    s.font.name = 'Consolas'
    s.font.size = Pt(9)
    s.font.color.rgb = MID
    if hasattr(s, 'paragraph_format'):
        s.paragraph_format.space_before = Pt(4)
        s.paragraph_format.space_after = Pt(4)

# -- Title / Subtitle --
doc.styles['Title'].font.name = 'Calibri'
doc.styles['Title'].font.size = Pt(28)
doc.styles['Title'].font.color.rgb = DARK
doc.styles['Title'].font.bold = True

doc.styles['Subtitle'].font.name = 'Calibri'
doc.styles['Subtitle'].font.size = Pt(16)
doc.styles['Subtitle'].font.color.rgb = ACCENT
doc.styles['Subtitle'].font.bold = False

# -- Table style: visible borders, bold header row, NO background fills --
styles_el = doc.styles.element

# Remove any existing TableGrid
for existing in styles_el.findall(qn('w:style')):
    if existing.get(qn('w:styleId')) == 'TableGrid':
        styles_el.remove(existing)
    if existing.get(qn('w:styleId')) == 'Table':
        styles_el.remove(existing)

# Create Table style (pandoc uses "Table" not "TableGrid")
for style_id in ['Table', 'TableGrid']:
    tbl_style = parse_xml(
        f'<w:style w:type="table" w:styleId="{style_id}" {nsdecls("w")}>'
        f'  <w:name w:val="{style_id}"/>'
        f'  <w:basedOn w:val="TableNormal"/>'
        f'  <w:pPr>'
        f'    <w:spacing w:after="0" w:line="240" w:lineRule="auto"/>'
        f'  </w:pPr>'
        f'  <w:rPr>'
        f'    <w:sz w:val="20"/>'
        f'  </w:rPr>'
        f'  <w:tblPr>'
        f'    <w:tblStyleRowBandSize w:val="1"/>'
        f'    <w:tblBorders>'
        f'      <w:top w:val="single" w:sz="6" w:space="0" w:color="{BORDER}"/>'
        f'      <w:left w:val="single" w:sz="6" w:space="0" w:color="{BORDER}"/>'
        f'      <w:bottom w:val="single" w:sz="6" w:space="0" w:color="{BORDER}"/>'
        f'      <w:right w:val="single" w:sz="6" w:space="0" w:color="{BORDER}"/>'
        f'      <w:insideH w:val="single" w:sz="6" w:space="0" w:color="{BORDER}"/>'
        f'      <w:insideV w:val="single" w:sz="6" w:space="0" w:color="{BORDER}"/>'
        f'    </w:tblBorders>'
        f'    <w:tblCellMar>'
        f'      <w:top w:w="60" w:type="dxa"/>'
        f'      <w:left w:w="100" w:type="dxa"/>'
        f'      <w:bottom w:w="60" w:type="dxa"/>'
        f'      <w:right w:w="100" w:type="dxa"/>'
        f'    </w:tblCellMar>'
        f'  </w:tblPr>'
        f'  <w:tblStylePr w:type="firstRow">'
        f'    <w:rPr>'
        f'      <w:b/>'
        f'    </w:rPr>'
        f'  </w:tblStylePr>'
        f'</w:style>'
    )
    styles_el.append(tbl_style)

# Save
output = '/Users/darsh/vmo2/argocd-automation/reference.docx'
doc.save(output)
print(f"Template saved: {output}")
