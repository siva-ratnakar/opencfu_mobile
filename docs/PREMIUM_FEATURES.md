# Premium features — design notes (not yet implemented)

Captured from a planning conversation on 2026-07-10. These are **not implemented
yet** — this document is the spec to build from later. Basic mode stays exactly
as it is today; everything here is Advanced-mode-only or a new top-level mode.

Three distinct features, with three distinct entry points:

1. **Manual Counting Mode** — a whole new mode, selectable from the home
   screen alongside Basic/Advanced. For confluent or otherwise
   too-numerous/too-hard-to-auto-count plates.
2. **Colony Type Classification** — an Advanced-mode-only button at the top
   of the capture screen. Classifies detected colonies into named
   color/size-based types (e.g. "Type A: red, 20-30px").
3. **Segmented Counting** — a separate Advanced-mode-only button at the top
   of the capture screen. Restricts automatic counting to one chosen grid
   cell of the plate.

Implementation risk/effort, cheapest first: **Segmented Counting** (mostly
reuses the mask infrastructure already built) → **Colony Type
Classification** (new UI + a Dart-side color-sampling step, no native
changes needed) → **Manual Counting Mode** (the most new UI surface: ROI →
grid → zoom → tap-count screens).

---

## 1. Manual Counting Mode

### Why

For plates too dense/confluent to auto-count reliably (lawns, overlapping
colonies), the standard lab technique is: count a representative fraction of
the plate, then extrapolate. This mode implements that workflow directly
instead of asking the operator to do the arithmetic by hand.

### Flow

1. **Home screen**: a third entry point next to Basic/Advanced — a single
   icon (pointing-finger / tap glyph) labeled "Manual Count".
2. **Capture**: same camera/import screen as today, but skips native
   analysis entirely (no point running the algorithm — the whole reason
   they're here is that it doesn't work well on this plate).
3. **ROI masking**: reuse the *existing* `_MaskDrawScreen`/`MaskTool` UI
   verbatim (3-tap circle or N-tap polygon) to mark the plate boundary. No
   new code needed here beyond wiring it into this new flow.
4. **Grid size picker**: a simple chooser (2×2 / 3×3 / 4×4, maybe a custom
   N×N) for how many cells to divide the masked region into.
5. **Grid overview**: the plate photo with the grid drawn over it (grid
   lines clipped to the mask boundary), each cell tappable. Tapping a cell
   selects it and moves to step 6.
6. **Zoomed manual count**: the view zooms into just the selected cell
   (`InteractiveViewer`, already used elsewhere in the app — don't hand-roll
   pan/zoom). Tapping a point drops a colony marker; tapping an existing
   marker again removes it (the "mistouch → tap again to delete" behavior
   the operator asked for). This is the *same* interaction model as
   Advanced mode's existing manual-add markers
   (`_handleImageTap`/`ColonyMarker(manual: true)`) — reuse that, scoped to
   the cropped cell region instead of the whole photo.
7. **Finish**: the tally in that one cell × total cell count = the
   whole-plate estimate. Show all three numbers (cell count, multiplier,
   estimate) — never just the extrapolated total on its own, so the
   operator can sanity-check it and the number stays auditable in exports.

### Design notes / open questions to resolve before building

- **Grid-over-a-circle problem**: a circular plate's bounding-box grid has
  edge cells that cover much less actual plate area than center cells (a
  corner cell of a 3×3 grid over a circle is mostly outside the circle).
  Either (a) visually shade/disable cells with too little plate area inside
  them so the operator picks a fair one, or (b) compute each cell's actual
  in-mask area and show it, or (c) simplest for a first cut: restrict cell
  choice to a subset that's guaranteed mostly-interior (e.g. only the
  center cells of odd-sized grids). Needs a decision before implementation.
- **One cell vs. several**: the operator specified counting exactly one
  cell and multiplying. A natural accuracy improvement for later — not
  required now — would be letting them count 2-3 cells and averaging, but
  build the one-cell version first since that's the explicit spec.
- **Data model**: needs a new result type, roughly:
  ```dart
  class ManualGridCount {
    final int gridSize;       // e.g. 3 for 3x3
    final int selectedCellIndex;
    final List<Offset> tappedPoints; // in cell-crop-local coordinates
    int get cellCount => tappedPoints.length;
    int get estimatedTotal => cellCount * gridSize * gridSize;
  }
  ```
  `PlateRecord` would need an optional field to carry this instead of (or
  alongside) the normal `colonies`/`markers` fields, and exports need to
  show it's an *estimate* (label it distinctly from an auto/manual exact
  count).

---

## 2. Colony Type Classification

### Why

Some platings deliberately contain multiple colony morphologies (different
species/strains) that need separate counts — e.g. "12 red colonies, 8 white
colonies" rather than one combined number.

### Flow

1. In Advanced mode, once the camera/photo screen is open, a top button:
   **"Count colony types"**.
2. Opens a **colony type list** — starts empty, "+" button to add a type.
3. Adding a type: operator taps an already-detected colony marker on the
   photo (reuse existing `ColonyMarker` positions — don't build a separate
   free-form color picker). That sample seeds:
   - **Color**: sampled from the source image at that marker's location
     (see Implementation notes below — this needs a small new Dart-side
     step, not a native change).
   - **Size**: the marker's existing radius, expanded into an editable
     range (e.g. sampled radius ± 25% as the initial range).
   - **Name**: free text field, defaults to "Type A" / "Type B" / etc.
4. Each type is a **collapsible card** in the list:
   - Collapsed: color swatch, name, size range, live count.
   - Expanded: editable size-range slider (and later, color tolerance),
     name field, and — per the operator's explicit ask — **a live-updated
     highlight on the plate photo showing exactly which detected colonies
     currently match this type's criteria** as the range is dragged. This
     is the single most important UX detail here: adjusting the slider
     must visibly repaint the overlay in real time, otherwise the operator
     can't tell if their range is capturing the right colonies.
5. Additional types (B, C, ...) are added the same way via the "+" button.
   Per the operator's explicit note, edit **one type at a time** — don't
   try to show all types' editable controls simultaneously; that's exactly
   the "cluttered" outcome to avoid. Only one card is expanded at a time
   (accordion behavior), the rest stay collapsed summaries.
6. A synthetic **"All"** type always exists implicitly (the undifferentiated
   total, i.e. what Basic/Advanced mode already reports) — it doesn't need
   its own card, just its own export row (see Data below).

### Implementation notes

- **Color sampling requires new Dart-side work, not a native change.** The
  current bridge (`OpenCfuColony`) has position and radius but **no color
  information at all**. Rather than extending the ABI-sensitive native
  bridge again, sample average RGB/HSV directly in Dart from the already-
  captured photo (decode via the `image` pub package, or `dart:ui`'s
  `Image.toByteData` + manual pixel indexing, averaged over a small disc
  around each marker's center/radius). This keeps the native core
  untouched and is fully testable on the Dart side alone.
- **Matching is cheap**: classifying N colonies against M type criteria
  (radius range + color distance threshold) is an O(N×M) check with tiny
  constants — trivial even for thousands of colonies, not a performance
  concern. Safe to recompute on every slider drag frame.
- **Collapsible-card list**: standard `ExpansionPanelList` or a hand-rolled
  `AnimatedSize`-based card list (the app already uses similar patterns for
  the collapsible comment field) — no new package needed.

### Data / export format

Long-form, not wide columns — the operator was explicit about this. One row
per (plate, type) pair, not one column per type:

```
Plate,ColonyType,Count
Plate 1,All,45
Plate 1,Type A (red),12
Plate 1,Type B (white),8
Plate 2,All,30
Plate 2,Type A (red),19
```

This is the standard "tidy data" shape and stays pivot-table-friendly
however many types a given session ends up with — a wide format would need
a variable number of columns depending on how many types were defined,
which is awkward for CSV consumers.

---

## 3. Segmented Counting

### Why

For very dense/large plates, or when only part of a plate is usable,
restrict the *automatic* algorithm to one grid region instead of the whole
photo — both a UX convenience and, done right, a genuine speed win (a
smaller cropped image means less work for every stage of the native
pipeline: threshold, contour-finding, classification).

### Flow

1. In Advanced mode's capture screen, a second top button: **"Segment
   plate"**.
2. Same grid-size picker as Manual Mode (2×2, 3×3, ...).
3. Operator picks one cell.
4. The native analysis re-runs on **just that cropped region** (or the
   whole image with a mask restricted to that cell — either works; cropping
   first is likely faster since it also shrinks the image the native
   pipeline has to touch, not just what counts).

### Implementation notes

- **This is the cheapest of the three to build.** A grid cell boundary is
  just another polygon — it can most likely reuse the *exact* mask
  pipeline already shipped (`MaskMode.draw`/`MaskTool.polygon`,
  `apply_mask` in the native bridge) by constructing the cell's four
  corners as the polygon points programmatically, with no new native code
  at all. The main net-new work is the grid UI (compute/draw an N×N grid
  clipped to the already-drawn plate mask, handle cell selection) —
  everything downstream of "here are 4 polygon points" already exists.
- If cropping the image before sending it to the native engine (rather than
  masking the full image), reuse the same `image_picker`-style resize
  approach already used for gallery imports, applied as a crop instead of a
  uniform resize.

---

## Performance

The operator flagged wait times as a real concern for all of this. Notes
per feature, plus what's already been done:

- Gallery imports are already capped to 2048px on the long edge before
  analysis (native processing scales with pixel count).
- Colony-type matching (§2) is O(N×M) with small constants — not a
  bottleneck even live on every slider frame.
- Manual mode's zoom (§1) should use `InteractiveViewer` (GPU-accelerated
  pan/zoom), not a hand-rolled crop-and-redraw loop.
- Segmented counting (§3) should be a net *speed win* over full-plate
  analysis if the image is cropped before being handed to the native
  engine, not just masked.
- The biggest lever remains build type: make sure whatever the operator is
  actually testing is a `--release` build, not `--debug` (see the earlier
  fix in this session) — that dwarfs any of the above for raw native
  processing time.

## Suggested build order

1. Segmented Counting (§3) — smallest new surface, reuses existing mask
   pipeline almost entirely.
2. Colony Type Classification (§2) — new UI + one new Dart-side color-
   sampling utility, no native/ABI changes.
3. Manual Counting Mode (§1) — the most new screens (grid picker, grid
   overview, zoomed tap-count), but every individual piece (mask draw,
   manual tap-to-add markers, `InteractiveViewer` zoom) already exists
   elsewhere in the app and just needs to be composed into this new flow.
