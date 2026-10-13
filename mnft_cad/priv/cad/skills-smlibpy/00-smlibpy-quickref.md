<!-- Upstream text: MIT, © AWV Informatik AG (https://github.com/awv-informatik/smlibpy). -->
<!-- Adapted for mnft; runnable blocks test-executed by cad_worker/tests/test_quickref_skill.py -->

# smlibpy quick reference

Each block is a complete, runnable program that defines `part`.

---

## 1. Plate with rounded corners and a centre hole

```python
from smlibpy import *
import math
plate = Box(80, 60, 10, align=(Align.CENTER, Align.CENTER, Align.MIN))
plate = plate.fillet(plate.edges().parallel_to(Z), 5)
plate -= Cylinder(8, 12)          # 8 mm radius through-hole (diameter 16 mm → halved to 8)
part = plate
```

---

## 2. Bolt-pattern: four through-holes on a cylinder flange

```python
from smlibpy import *
import math
flange = Cylinder(30, 12, align=(Align.CENTER, Align.CENTER, Align.MIN))
flange -= GridLocations(20, 20, 2, 2) * Cylinder(3, 14)   # 2×2 grid, 3 mm radius holes
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
path = Helix(pitch=20, height=60, radius=15)
profile = Circle(3).moved(Pos(15, 0, 0))   # wire cross-section, offset to coil radius
part = sweep(profile, path=path)
```

---

## 5. Threaded fastener — Helix + swept ridge on shank (M2.4 minor, M3 major)

```python
from smlibpy import *
import math
pitch, length, r_minor = 0.5, 8.0, 1.2
helix = Helix(pitch=pitch, height=length, radius=r_minor)
profile = Circle(0.15).moved(Pos(r_minor + 0.15, 0, 0))
ridge = sweep(profile, path=helix)
part = Cylinder(r_minor, length, align=(Align.CENTER, Align.CENTER, Align.MIN)) + ridge.moved(Pos(0, 0, 0))
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
