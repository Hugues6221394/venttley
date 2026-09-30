# Venttly avatar art spec

For the illustrator. Everything here exists to make one thing true: **any
hair can sit on any head, and any top can sit on any body, without being
redrawn.** That is the whole difference between a set of pictures and an
avatar system.

The test sheet already sent — bald base, hair with the hairline cut, garments
as separate pieces — is exactly right in concept. What follows is the detail
that makes the pieces line up in software.

---

## 1. The one rule

**Never move, resize or re-crop the canvas.**

Draw every layer *in place*, on top of the base body, on the same canvas.
Export each layer with only that layer visible. If two files are opened on
top of each other in any image editor and they do not line up, the set is
wrong — that check takes ten seconds and should be done before sending.

This is the failure that costs a whole commission: a hairstyle drawn on a
head that is forty pixels higher than the base's head cannot be fixed in
code, only redrawn.

---

## 2. Canvas and framing

| | |
|---|---|
| Delivery size | **1024 × 1024 px**, square |
| Master size | 2048 × 2048 (keep, do not send) |
| Format | **PNG-24 with alpha**. No background, no matte, no baked shadow |
| Colour | sRGB |
| Framing | Upper body only — crown of the head to mid-chest |

Anchors, in canvas pixels. Every base body must hit these, and every other
layer is drawn to whatever the base does:

| Landmark | y |
|---|---|
| Crown of skull | 150 |
| Eye line | 430 |
| Chin | 660 |
| Shoulder line | 830 |
| Canvas bottom | mid-chest |

Head centre line: **x = 512**. Faces look straight ahead. No tilt, no
three-quarter turn — a tilted head makes every hairstyle bespoke.

---

## 3. Layers, back to front

Software stacks them in exactly this order:

1. `hair_back` — long hair falling behind the shoulders
2. `base_body` — head, neck, bare shoulders and chest. **No hair, no clothes**
3. `top` — the garment
4. `facial_hair`
5. `hair_front` — the crown and fringe, drawn over the forehead and, where the
   style calls for it, over the garment's shoulders
6. `headwear` — cap, scarf, headwrap
7. `earrings`
8. `glasses`

A short hairstyle needs only `hair_front`. A long one is split into
`hair_front` and `hair_back` so the shoulders of any garment sit between them.

Where a garment has a collar that would sit over long hair, that is fine —
`top` is above `hair_back` on purpose.

---

## 4. Skin tone

Skin tone multiplies **only the base body**, because hair, garments, glasses
and earrings do not change with it. Six tones, light to deep, evenly spaced:

```
base_fem_01_skin01.png … base_fem_01_skin06.png
base_masc_01_skin01.png … base_masc_01_skin06.png
```

Ears belong to the base body, so earrings register against it automatically.

---

## 5. A first set

This is the smallest set that feels like a real choice rather than a demo.
Forty-three files.

| Layer | Count | Notes |
|---|---|---|
| Base bodies | 2 shapes × 6 skin tones = **12** | one feminine, one masculine |
| Hair | **10** | 5 feminine, 5 masculine; split front/back where long |
| Tops | **10** | hoodie, tee, shirt, jacket, knit — the app's own palette |
| Facial hair | **4** | including one light stubble |
| Glasses | **3** | |
| Earrings | **2** | |
| Headwear | **2** | one cap, one headwrap |

One colour per hairstyle for now — no colour picker in the first version. The
config keeps a field for it, so adding colours later costs no rework.

---

## 6. File names

Lowercase, underscores, no spaces, no version suffixes:

```
base_fem_01_skin03.png
hair_fem_04_front.png
hair_fem_04_back.png
top_masc_02.png
facial_hair_01.png
glasses_02.png
earrings_01.png
headwear_01.png
```

Send them as **individual files** — a zip or a folder. Not a contact sheet,
not a presentation layout: a sheet is a picture of the layers, and software
cannot take it apart.

---

## 7. Style

Match the five characters already on the welcome screen: the rendered 3D look,
soft light from the upper left, warm and slightly glossy, friendly rather than
photoreal.

Two styles are in circulation at the moment — that 3D render, and a more
photographic illustration. **The layered set follows the 3D one.** It matches
the welcome screen, it composites more forgivingly, and it reads as an avatar
rather than as a photograph of a real person, which is the point in an app
where nobody shows their face.

No drop shadows, no glow, no background arc baked into any layer. Venttly
adds those.

---

## 8. What is checked on arrival

Three composites, as soon as the first files land:

1. base + `hair_01_front` + `top_01`
2. base + `hair_02_front` + `top_02`
3. base + `hair_01_front` + `top_02` — the cross pairing, which is the one
   that proves the pieces are interchangeable rather than three matching sets

Pass means: the hairline meets the skull with no gap and no overlap, the
garment's neckline meets the neck, and nothing shifts between pairings.

Send the five test assets as separate PNGs and this can be confirmed the same
day.
