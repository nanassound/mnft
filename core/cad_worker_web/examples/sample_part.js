// Port of cad_worker/examples/sample_part.py to the mnft replicad dialect:
// the same deterministic 40 mm hexagonal pen holder, 3 mm wall, 90 mm tall.
export const SAMPLE_PART = `// 40 mm hexagonal pen holder, 3 mm wall, 90 mm tall
// (port of cad_worker/examples/sample_part.py)

const acrossFlats = 40.0;
const wall = 3.0;
const height = 90.0;

// hexagon specified by its across-flats (apothem), matching build123d's
// RegularPolygon(..., major_radius=False): convert apothem -> circumradius
const circumRadius = (across) => across / 2 / Math.cos(pi / 6);

const outer = sketchPolysides(circumRadius(acrossFlats), 6).extrude(height);
const inner = sketchPolysides(circumRadius(acrossFlats - 2 * wall), 6).extrude(height);
const part = outer.cut(inner.translate(0, 0, wall));
`;
