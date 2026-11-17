## Verification status

Implemented 2026-11-17 (spec 0018). Quality gate, full run
(`.agents/skills/spec-implementer/scripts/quality-gate.sh`):

```
==> Debug build (clean build)
No compiler warnings.

==> Headless tests (Debug, PaintDotMacTests only; no UI tests, no app launch)
tests: 1393 passed, 0 failed, 0 skipped (of 1393)

==> GREEN
tests: 1393 passed, 0 failed, 0 skipped (of 1393)
tests: no crash reports during the run
```

Review: pending.

Performance (Debug test build medians on 4000×3000, each including `makeHistoryItem`
with the `TileDiff` and `HistoryStack.perform`; gate 3× the target): Erase Selection
with Select All **0.38 ms** (target 10, gate 30); Fill Selection with no selection
**13.8 ms** (target 20, gate 60); Erase Selection with the full-canvas antialiased
ellipse **25.2 ms** and Fill Selection **30.3 ms** (target 100, gate 300 each) — all
four meet the plain targets, not just the 3× gates. Two enabling fixes, both
semantics-preserving (all pre-existing model/history suites pass): `TileDiff.between`
now compares/classifies each shared tile *buffer* once (fill/erase repeat one buffer
across the interior), and the DEBUG `setTile` invariant scan `Tile.paddingIsZero` walks
each padding run 8 bytes at a time with `loadUnaligned` like `isFullyTransparent`
(0002) — the per-byte loop had been costing more than the fill itself.

Manual verification (not automated):

- [ ] Rectangular selection on an opaque layer, ⌫: the selection turns transparent
      (checkerboard shows through) and the ants disappear; one ⌘Z restores both the
      pixels and the ants; ⌘⇧Z erases and deselects again.
- [ ] ⌥⌫ fills the selection with the primary color exactly (black primary on white
      gives pure (0,0,0,255)); the ants stay; Edit > Undo reads "Undo Fill Selection".
- [ ] ⌦ erases like ⌫. With no selection, ⌫ clears the whole active layer and ⌥⌫
      fills it; both Edit items are enabled for any open document, disabled with none.
- [ ] Antialiased ellipse, then Fill: the edge pixels take coverage-weighted alpha
      (soft edge over the checkerboard); Erase on the same edge fades alpha instead of
      clearing colors below full coverage.
- [ ] Focus the Colors panel hex box: ⌫ edits the text, both Edit items are greyed;
      click the canvas and they work again.
- [ ] Hold the mouse mid-lasso (gesture in progress) and press ⌫: nothing happens.
