<!-- Upstream text: MIT, © AWV Informatik AG (https://github.com/awv-informatik/smlibpy). -->
<!-- Adapted for mnft; runnable blocks test-executed by cad_worker/tests/test_quickref_skill.py -->

# smlibpy quick reference

Each block is a complete, runnable program that defines `part`. The base sits on
Z=0, so a cutting tool centred at the origin only reaches the LOWER half of the
part: move hole tools to mid-height (`.moved(Pos(x, y, thickness / 2))`) and make
them taller than the part, or the hole is blind and leaves a skin on top.

---

## 1. Plate with rounded corners and a centre hole

```python
from smlibpy import *
import math
plate = Box(80, 60, 10, align=(Align.CENTER, Align.CENTER, Align.MIN))
plate = plate.fillet(plate.edges().parallel_to(Z), 5)
# 16 mm diameter -> 8 mm radius. Tool is 14 tall, centred at z=5 => spans -2..12,
# so it passes through the 10 mm plate (a centred, unmoved tool would be blind).
plate -= Cylinder(8, 14).moved(Pos(0, 0, 5))
part = plate
```

---

## 2. Bolt-pattern: four through-holes on a cylinder flange

```python
from smlibpy import *
import math
flange = Cylinder(30, 12, align=(Align.CENTER, Align.CENTER, Align.MIN))
# Ø6 holes -> 3 mm radius; tool 16 tall centred at z=6 => spans -2..14 (through)
flange -= GridLocations(20, 20, 2, 2) * Cylinder(3, 16).moved(Pos(0, 0, 6))
part = flange
```

---

## 3. Revolved part — bushing / flanged sleeve

```python
from smlibpy import *
import math
# Half-section on XY: profile from (0,0) around origin, revolve about Y axis
section = (
    Profile((0, 0))
    .line_to(8, 0)
    .line_to(y=4)
    .fillet(1.5)
    .line_to(x=4)
    .line_to(y=20)
    .line_to(x=0)
    .close()
)
part = section.revolve(Axis((0, 0, 0), (0, 1, 0)))
```

---

## 4. Sweep — circular profile along a helical path (spring coil)

```python
from smlibpy import *
import math
path = Helix(pitch=20, height=60, radius=15)   # coil radius lives in the PATH
profile = Circle(3)                            # sweep centres the profile on the path start
part = sweep(profile, path=path)
```

---

## 5. Threaded fastener — Helix + swept ridge on shank (M2.4 minor, M3 major)

`sweep` centres the profile on the START of the path; you cannot offset a profile
from its path. Put the offset in the PATH radius instead. The tube must overlap the
shank (a merely tangent tube is refused by the kernel).

```python
from smlibpy import *
import math
pitch, length, r_minor, t, r_mid = 0.5, 8.0, 1.2, 0.2, 1.3   # crest r_mid + t = 1.5 => 3.0 mm major
helix = Helix(pitch=pitch, height=length, radius=r_mid)      # the PATH carries the offset
ridge = sweep(Circle(t), path=helix)                         # tube spans 1.10..1.50, overlaps the shank
part = Cylinder(r_minor, length, align=(Align.CENTER, Align.CENTER, Align.MIN)) + ridge
```

---

## 6. Boss pattern — four bosses on a disc (PolarLocations)

```python
from smlibpy import *
import math
base = Cylinder(25, 10, align=(Align.CENTER, Align.CENTER, Align.MIN))
bosses = PolarLocations(16, 4) * Cylinder(3, 6, align=(Align.CENTER, Align.CENTER, Align.MIN))
part = base + [b.moved(Pos(0, 0, 10)) for b in bosses]
```

---

## 7. Text engraving

```python
from smlibpy import *
import math
plate = Box(80, 30, 6, align=(Align.CENTER, Align.CENTER, Align.MIN))
plate = plate.fillet(plate.edges().parallel_to(Z), 4)
top = plate.faces().top()
part = plate - Text("PART 01", 8).on(top).extrude(-0.6)   # 8 mm capitals, 0.6 mm deep
```

---

## 8. Shell — hollow box open at the top

```python
from smlibpy import *
import math
box = Box(60, 40, 30, align=(Align.CENTER, Align.CENTER, Align.MIN))
part = box.shell(2, openings=[box.faces().top()])   # 2 mm wall, open top
```
