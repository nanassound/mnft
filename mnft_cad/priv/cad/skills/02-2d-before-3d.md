# 2D before 3D

- Build complex 3D shapes from 2D sketches: draw the profile (possibly with 2D
  fillets/chamfers, which fail far less than 3D ones), then `extrude`/`revolve`.
  3D operations are slower and more failure-prone than 2D ones.
- DELAY 3D chamfers and fillets to the very end of the script, and only if
  needed — they turn simple vertices into arcs and non-planar faces that make
  the model expensive and fragile.
- Parameterize: define every critical dimension as a named variable at the top
  and derive other dimensions from those variables, so a correction is a
  one-line change instead of a rewrite.
