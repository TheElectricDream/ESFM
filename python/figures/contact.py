import sys
from PIL import Image
d = sys.argv[1]; names = sys.argv[3:]; out = sys.argv[2]
ims = [Image.open(f'{d}/{n}.png').convert('RGBA') for n in names]
W = max(i.width for i in ims); H = max(i.height for i in ims)
cols = 3; rows = (len(ims) + cols - 1) // cols
g = Image.new('RGBA', (W * cols, H * rows), 'white')
for k, i in enumerate(ims):
    bg = Image.new('RGBA', i.size, 'white'); bg.alpha_composite(i); g.paste(bg, ((k % cols) * W, (k // cols) * H))
g.convert('RGB').resize((W * cols // 2, H * rows // 2)).save(out)
