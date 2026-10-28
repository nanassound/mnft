# Subtracted features: holes, cutouts, pockets, slots

Every subtraction in the code must be a named, commented feature, and the reply
must list each one (e.g. "sound port: 1.0 mm cylinder through the top face").

- A "hole" in the user's words means ANY removed volume they can see in the
  render: a drilled cylinder, a cutout, a pocket, a slot. Never assume it maps
  to a feature the conversation named earlier — check the annotated image; the
  feature the user marks is the feature to remove.
- Cut clean: to cut through, oversize the tool beyond both faces (e.g. a box or
  cylinder `height + 0.2` centred on the body) so no zero-thickness slivers
  remain.
- A pocket (partial depth) uses a tool SHORTER than the body, positioned from
  the face it opens on — state its depth in the reply.
- When the user says "no hole" / "solid": remove ALL interior subtractions from
  the previous code, not just the one you think they mean, unless they named a
  specific feature to keep.
