<!-- Upstream text: MIT, © AWV Informatik AG (https://github.com/awv-informatik/smlibpy). -->
<!-- Adapted for mnft; derived from SKILL.md in the smlibpy skill package -->

# smlibpy gotchas

## Method-style vs free functions

`fillet`, `chamfer`, `shell`, `mirror`, `split`, `section` are **methods** on the shape object:

- `part.fillet(edges, r)` ✓
- `fillet(part, edges, r)` ✗ — raises `NameError: name 'fillet' is not defined`

## No module-level fuse()

There is no `fuse(a, b)` free function. Use `a + b` or `a.fuse(b)`.

## Face/edge selection — never by index

Always select by geometry:

- `part.faces().top()` / `.bottom()` / `.largest()`
- `part.edges().parallel_to(Z)` / `.concave()` / `.convex()`
- `part.vertices().top()`

Indices change whenever the model changes. Index selection is always wrong.

## ModelingError vs KernelError

- `ModelingError` — the input cannot work (radius too large, crossing profile, zero-thickness wall). Read the hint; fix the input.
- `KernelError` — the kernel failed on otherwise valid input. Simplify and retry; if it persists, report the geometry.

## Fillet-too-large error

When `.fillet(edges, r)` raises `ModelingError`, the radius exceeds the shortest adjacent edge. Reduce `r`, or select fewer edges.

## Threaded parts — never fillet the ridge

After `sweep(profile, path=helix)`, the ridge has many tiny faces. Calling `.fillet()` or `.chamfer()` on the resulting solid is expensive and will crash. Cut chamfers with a revolved triangular profile instead.

## Volume sanity check

After each step: `print(round(part.volume, 3), part.is_valid())`. Volume 0 or absurdly large means the boolean or align is wrong.
