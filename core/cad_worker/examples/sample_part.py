"""Deterministic landing-page sample: a 40 mm hexagonal pen holder, 3 mm wall.

Run through the worker CLI during implementation; the exported model.stl is
committed at mnft_cad_web/priv/static/samples/sample-part.stl so the
landing hero renders a real generated part offline.
"""
from build123d import *

import math

across_flats = 40.0
wall = 3.0
height = 90.0

outer = extrude(RegularPolygon(across_flats / 2, 6, major_radius=False), height)
inner = extrude(RegularPolygon((across_flats - 2 * wall) / 2, 6, major_radius=False), height)
part = outer - Pos(0, 0, wall) * inner
