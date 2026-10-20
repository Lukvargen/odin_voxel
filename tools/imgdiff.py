# imgdiff.py dirA dirB: compare the bench shots (BMP) two builds wrote, e.g.
# `<exe> bench quick hd hour=12 <dir>` for each. Per shot: mean absolute
# difference, the share of pixels off by more than 8/255 in any channel and
# their bounding box; where that share passes 0.1%, a white-on-black mask
# <shot>_diff.png goes next to dirB's shot.
#
# Judge against noise, not zero: two runs of the SAME build differ by ~1-5%
# of pixels in views with water (ripples), animals, or cumulus and their
# shadows (they drift with the clock). Render both builds in the same round
# and look at any mask whose shapes aren't water, creatures or clouds.
import os, sys
import numpy as np
from PIL import Image

a, b = sys.argv[1], sys.argv[2]
for f in sorted(os.listdir(a)):
    if not f.endswith('.bmp') or not os.path.exists(os.path.join(b, f)):
        continue
    x = np.asarray(Image.open(os.path.join(a, f)).convert('RGB')).astype(int)
    y = np.asarray(Image.open(os.path.join(b, f)).convert('RGB')).astype(int)
    d = np.abs(x - y)
    big = d.max(axis=2) > 8
    ys, xs = np.nonzero(big)
    where = f" bbox x{xs.min()}-{xs.max()} y{ys.min()}-{ys.max()}" if len(xs) else ""
    print(f"{f:22s} mean {d.mean():6.3f}  >8: {100 * big.mean():6.3f}%{where}")
    if big.mean() > 0.001:
        Image.fromarray((big * 255).astype(np.uint8)).save(os.path.join(b, f[:-4] + '_diff.png'))
