# Registering the avatar layers

`build_layers.py` turns the designer's loose artwork into the layer set the app
stacks. Run it after any new art lands:

```
python3 scripts/avatars/build_layers.py
```

It writes `assets/images/avatars/layers/` and a `manifest.json`, and
`test/avatar_look_test.dart` fails if the catalogue in
`lib/domain/avatar/avatar_look.dart` and that manifest disagree.

## The problem it solves

Each piece arrives drawn to fill its own 1254² frame rather than drawn over the
base body. Composited raw, a hairstyle lands across the eyes and a beard covers
the whole lower face — the hair pieces are roughly 1.9× the width of the head
they are meant to sit on. Asking for twenty redraws days before launch was the
obvious move and the wrong one, because the fix is two numbers per piece.

What makes it tractable: every piece is already **horizontally centred** on the
same axis the base is (measured centre of mass x = 626–648 against the base's
622). Only scale and vertical offset are wrong, and both are recoverable by
measuring the art.

## The base's anchors

Measured off `Asset Layer …-1.png` by walking its alpha row by row and reading
where the silhouette changes:

| anchor | y | note |
| --- | --- | --- |
| crown | 127 | first opaque row |
| brow | 430 | width jumps 468 → 513 as the ears appear |
| eye line | 480 | widest across the ears, 574 |
| nose base | 590 | width falls back off the ears |
| chin | 705 | width settles to the neck's 321 |
| shoulders | 820 | neck starts flaring |

Head centre x = 622. Skull width (above the ears) = 484.

## Fitting a piece

Two anchors give scale and offset. For a cropped hairstyle, the pair that works
is the **sideburn tips** — the two downward spikes either side of the face
opening, which must land in front of the ears — and the **hair's top edge**,
which must clear the crown by the hair's own volume. For `hair_01`: tips 882px
apart in its own frame against 551px on the base gives s = 0.625, and that scale
independently puts the top edge 68px above the crown and the sideburns ending at
y = 553, between the ear top (430) and the nose base (590). Four checks, one
scale — that is what tells you the fit is right rather than merely plausible.

Beards anchor on the jaw width at mouth level and the sideburn tops; moustaches
on mouth width and the nose base; tops on the shoulder span.

Then **look at it**. Composite every piece over the base into one contact sheet
and read it. The numbers in `TRANSFORM` are the result of three such rounds, and
the last two rounds only moved beards that sat high and one updo whose fringe
covered an eye. Do not tidy them.

## Two things that are easy to get wrong

**Headroom.** Every hairstyle rises above the skull, and `hair_06` sits 18px
above y=0 once scaled. Registering into a bare 1254² canvas silently shaved it,
which reads as a badly drawn flat-topped afro rather than as a clipped layer.
Hence `PAD`, and hence a `CROP` whose top edge is negative.

**Skin is not a tint.** The lighting is painted in. Multiplying a warm mid-brown
up to a fair tone goes orange, because the saturation scales with it; the
lighter tones need a desaturation term as well, which no colour filter can
apply on its own. So the six tones are six baked files, while hair, beards and
tops ship as normalised greyscale and are tinted at draw time through a colour
matrix.

## What the art still needs

One base body. The plan was three masculine and three feminine, and every tone
currently comes from recolouring the same one, which is why the face card is the
same under every hairstyle. New bases drop in as `base_*` files plus one entry
in `AvatarLayers.skins` — no migration, because what is stored is the id.
