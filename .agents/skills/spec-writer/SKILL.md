---
name: spec-writer
description: >
  Author a precise, implementation-ready technical spec for a PaintDotMac feature, change, or bug
  fix, and later verify and file it as done. Use this whenever the user hands you a feature
  request, a PRD requirement (T-11, ADJ-4, L-3…), a milestone, a bug, or "we should add/support X"
  and wants it turned into a spec under docs/specs/todo/ — WITHOUT implementing it yet. Also use it
  to break the whole PRD (or a milestone, or a large part of it) into an ordered backlog of specs.
  And use it when a feature that already has a spec in docs/specs/todo/ is finished and needs the
  quality gate run, failures fixed, and the spec moved to docs/specs/done/. Trigger even when the
  user doesn't say the word "spec": "write this up", "plan out this feature", "turn this into a
  slice", "break the PRD into tasks", "plan milestone M2", "we need to support …", or "mark this
  feature done / it's implemented" all belong here.
---

# Spec Writer

This skill turns a feature request into an implementation-ready spec for **PaintDotMac**, the
native macOS raster image editor inspired by Paint.NET, and closes the loop once the feature is
built. It has two modes. Pick the one that matches what the user is asking.

- **Mode A: author a spec** (the default when given requirements). Research the PRD, Paint.NET's
  behavior, and the codebase, write a precise spec into `docs/specs/todo/`, and stop. **Do not
  implement the feature.**
- **Mode B: close out a spec** (when a feature is reported done). Run the quality gate, fix what's
  broken, then move the spec from `docs/specs/todo/` to `docs/specs/done/`.

If it's unclear which mode applies, ask one short question instead of guessing.

The specs this skill writes are consumed by the **spec-implementer** skill, which builds them one
at a time, in filename order, each in a fresh sub-agent that has none of your context, and then has
a second, independent sub-agent review the result. Write every spec so that a cold reader can
implement it from the spec, `AGENTS.md`, and `PRD.md` alone, and so that a reviewer can check
every acceptance criterion against a named test.

## Why this exists

`AGENTS.md` makes `PRD.md` (repo root) the source of truth and asks for requirement IDs in every
change. A good spec pins the exact PRD behavior, names the exact files and types that change,
separates the pure `Core` logic from the AppKit/SwiftUI/Metal glue, and lists the automated tests
that prove the feature works, down to the assertion. The implementer then has nothing left to
re-derive or guess.

**Quality is the point.** The user must be able to open the app after any batch and find features
that work and never crash. That only happens if every spec prescribes tests that would actually
fail when the feature is broken: exact expected pixel values, round trips, undo/redo, failure
paths, and UI tests that drive the real app. Vague specs lead to vague implementations, tests that
assert nothing, and "verified" claims that nobody checked. Those are the failures this skill
prevents.

---

## Mode A: author a spec

### Batches of 4 or more specs: one sub-agent per spec

When a single request produces **four or more** specs (for example "break the PRD into a
backlog"), don't write them all yourself one after another. Delegate each spec to its own
sub-agent and run them in parallel. With three or fewer, write them inline using the steps below.

Sub-agents running at the same time would each pick "the next free number" and collide. Their
order also matters, because the implementer builds specs in filename order. So you plan the batch
before spawning anything:

1. Split the request into specs. Each one is a vertical slice that builds, passes the quality gate,
   and runs on its own (see "Slicing" below). Give each a one-line title, its milestone, and the
   PRD requirement IDs it covers. **Every P0 requirement in scope must land in exactly one spec**:
   make a coverage table (requirement ID → spec) and check that nothing is missing or duplicated.
2. **Order them by dependency, milestone by milestone** (PRD §8, M0 → M7). Foundations first (Xcode
   project, test targets and UI test harness, document app, tiled surface, history), then the
   features that build on them. A spec must never depend on a spec with a higher number, and no M(n+1)
   spec may come before the M(n) specs that its exit criteria need.
3. List `docs/specs/todo/` and `docs/specs/done/`, find the next free ID (step 4), and assign one
   unique ID per spec, in dependency order. Fix the full filename for each one
   (`<ID>-<slug>_TODO.md`).
4. Resolve open product questions **before** spawning (step 1 below), including the PRD §10 open
   questions that any spec in the batch depends on. Sub-agents can't ask the user anything, so
   include the answers in their prompts.
5. Spawn one sub-agent per spec, all in the same turn so they run in parallel. Each sub-agent's
   prompt must contain:
   - the requirement for its one spec, its milestone, the PRD sections and requirement IDs it
     covers, and whatever the user said that applies to it, including the answers to open
     questions;
   - **its assigned spec ID and exact filename**, with the instruction to use them as given. It
     must not choose its own number, renumber, or create any other spec file;
   - the IDs, titles, and requirement IDs of every sibling spec in the batch, and which ones it
     depends on, so that it can fill in **Depends on** and point to siblings under **Out of
     scope** instead of overlapping with them. Include the types/files the earlier siblings will
     create (for example "0003 creates `TiledSurface` in `PaintDotMac/Core/Model/`"), so later
     specs build on them instead of inventing parallel types;
   - the path of this skill file and the instruction to read it and follow Mode A steps 2–7 for
     that single spec. It must not edit `PRD.md` (you do that once, in step 6, to avoid
     conflicting edits). If it finds a PRD gap you didn't resolve, it records the gap under
     **Open questions** in its spec and reports it back;
   - the instruction to report back the path, a short summary, the tests and manual checks it
     prescribed, and any open questions.
6. When all sub-agents have finished, review every spec yourself. Check that every assigned file
   exists under its assigned name, that no two specs claim the same change, that the coverage table
   holds, that the dependency order holds, that type and file names agree across specs, and that
   each spec's test plan meets the bar in step 6 below. Fix inconsistencies directly in the specs.
   Resolve any reported open questions with the user, then update the affected specs and the PRD.
   Give the user one combined report (step 7) including the coverage table.

### Slicing

Every spec has to leave the app in a state that builds, passes the full quality gate (including
the launch smoke test and UI tests), and runs without crashing. The implementer commits after each
spec. Prefer thin vertical slices over horizontal layers. For example, "Paintbrush paints on the
active layer with undo" is better than "all the tool plumbing" followed by "all the brush math".
Pure `Core` logic that later slices need (the tiled surface, the history stack, the blend math, the
selection mask) can be its own spec when it is large enough to be worth reviewing alone, and it
comes before the slices that use it. Aim for specs that a sub-agent can implement and verify in
about an hour. A spec that adds many similar items (adjustments, effects, blend modes) is split
into groups of a handful each, after the spec that builds the shared framework.

**The first spec is always the foundation** (M0): the Xcode project and how it is generated, the
app, unit test, and UI test targets in one scheme, a `.gitignore` that ignores `build/` and
generated project files, a document-based app shell that launches and opens a PNG/JPEG, and at
least one UI test that launches the app and opens a fixture image. It must prove that the
quality gate (`.agents/skills/spec-implementer/scripts/quality-gate.sh`) runs green end to end,
and record the real build and test commands in `AGENTS.md` (*Build and test*). Recommended
defaults to propose to the user for that spec:
- **XcodeGen** (`project.yml` as the source of truth, the generated `.xcodeproj` git-ignored, never
  hand-edit `project.pbxproj`). It is a build tool, not a runtime dependency, but it is still the
  user's call.
- Scheme `PaintDotMac` with targets `PaintDotMac`, `PaintDotMacTests` (unit, golden-image, and
  integration tests; Swift Testing, plus XCTest only for `measure` performance tests), and
  `PaintDotMacUITests` (XCUITest). These are the names the quality gate expects.
- Ad hoc signing for local builds. A test-only launch hook (for example a launch argument or
  environment variable read in `#if DEBUG` code) that lets UI tests open a fixture document and
  disables state restoration, so UI tests are deterministic.

### 1. Read the source of truth first, and ask instead of guessing

`PRD.md` (repo root) wins over every other document, including older specs, the current code, and
your own memory. Read the PRD sections the feature touches and cite them by section and
requirement ID, for example `PRD.md §5.3 T-11`.

Where the PRD says to mirror Paint.NET (tool behavior, option names, menu names, shortcuts, effect
parameters and their ranges and defaults), look up Paint.NET's documentation
(https://www.getpaint.net/doc/latest/) and cite the page in the spec. Record the exact parameter
names, ranges, and defaults in the spec, because the implementer can't browse.

If the PRD and Paint.NET's documentation are **silent**, **ambiguous**, or **conflict** with the
request or the code (for example: what a 0×0 selection does, how the Magic Wand tolerance maps to
color distance, which resampling the Zoom tool uses, what happens when an `.ora` file has a layer
larger than the canvas), **ask the user**. Don't invent the behavior. Batch the questions into one
round, number them, and give your recommended answer for each so the user can just say "yes". If
there are many decisions, suggest a grilling session (the `grilling` skill, if installed). The PRD
§10 open questions (Q-1 minimum macOS version, Q-2 pixel-format abstraction) must be settled before
the specs that depend on them.

Every answer that changes or adds product behavior goes into `PRD.md` **in the same change**:
update the relevant section or table, move a resolved §10 question into the matching section,
update the date and status at the top, and reference the updated section from the spec. Never
leave a decision only in the spec, because the PRD has to stay the single source of truth.

Also read `AGENTS.md` in full. Its tech stack, layout, architecture rules, testing expectations,
and code style are binding, and the spec must not prescribe anything that breaks them. For example,
it must not prescribe a third-party dependency, a UI import in `Core`, pixel mutation outside the
history system, a hand-written dialog for an effect, a change to the minimum macOS version, or a
change to the native file format. If a feature truly needs one of those, it is an open question for
the user.

### 2. Research the codebase so the spec is concrete

The whole value of a spec is its precision. Before writing, find the real code the feature will
touch and record file paths and line numbers. If the code doesn't exist yet (early specs), name
the files and types the spec will create, following the layout in `AGENTS.md`:

- `project.yml` (if XcodeGen was chosen): targets, sources, resources, Info.plist keys, document
  types and UTIs, the scheme's test targets. Any added or removed file or target means
  `xcodegen generate`.
- `PaintDotMac/App/`, `UI/`, `Canvas/`, `Document/`, and `Core/` (`Model/`, `History/`, `Tools/`,
  `Effects/`, `Rendering/` with `Rendering/Shaders/*.metal`, `IO/`).
- `PaintDotMacTests/` (with `Golden/` for reference PNGs) and `PaintDotMacUITests/`.

For every change, say which side of the **pure / platform boundary** it sits on:

- **`Core`, headless and unit-tested:** the document/layer/tile model, the history stack and tile
  diffs, tool logic (`mouseDown`/`mouseDragged`/`mouseUp` on canvas coordinates → `HistoryItem`),
  selection paths and mask rasterization, flood fill, blend math and the compositor, resampling,
  effects and their parameter schemas, codecs and OpenRaster, coordinate transforms (view ↔ canvas
  ↔ pixel at every zoom and backing scale), shortcut mapping tables, settings defaults.
- **Platform glue, covered by UI tests and manual checks:** SwiftUI panels and dialogs, the
  `MTKView` canvas and event forwarding, `NSDocument`, menus/commands, `NSPasteboard`, drag and
  drop, `NSColorSampler`, tablet and trackpad events.

Push as much logic as you can into `Core`, and say so in the spec. That is what makes the behavior
testable. Also call out the cross-cutting rules the change must respect: every pixel change goes
through history; 256×256 tiles; straight 8-bit sRGB RGBA, premultiplied only in the compositor;
effects declared through `ImageEffect` with a schema; tool options under `tool.<id>.<option>`;
`@MainActor` UI, cancellable off-main-actor heavy work with progress; selections as path + 8-bit
mask; shortcuts per PRD §5.12. If the change touches the canvas, compositing, or history, say
which PRD §6 performance targets (NF-1 to NF-4) it affects and how they are measured.

Read a couple of neighbouring specs in `docs/specs/todo/` and `docs/specs/done/` (if there are any)
to match their tone and level of detail and to reuse the types they define. Prefer grep and search
over guessing. Cite files as `path:line` so the references are clickable and can be checked.

### 3. Note the dependencies

List which specs must already be done for this one to build (`Depends on:`). The implementer works
in filename order, so a dependency must always have a lower number. If the spec you're writing
needs something that isn't specced yet, either spec that first (with a lower number) or put it in
this spec's scope.

### 4. Pick a filename

If you are a sub-agent that was given a spec ID and filename (see the batch section), use them
exactly as given and skip the rest of this step.

Specs live in `docs/specs/todo/` and are named `NNNN-<kebab-slug>_TODO.md`: a zero-padded,
four-digit, globally increasing ID followed by a short slug. Examples:
`0001-project-and-document-shell_TODO.md`, `0002-tiled-surface_TODO.md`. List both `todo/` and
`done/` and use the highest existing number + 1 (start at `0001` if both are empty). Never reuse or
renumber an ID, because commit messages and the implementer refer to specs by it. Create
`docs/specs/todo/` and `docs/specs/done/` if they don't exist yet.

### 5. Write the spec using the template

```markdown
# NNNN — <Imperative one-line summary of the change>

> Source: <PRD.md §N, requirement IDs (T-11, E-1, …) / user request / bug report; Paint.NET doc pages>
> Milestone: <M0–M7 or v1.x>
> Depends on: <NNNN-slug, … or "none">

## Context
<What is true today and what is missing or wrong. Cite real code as `path:line` (or "not yet
implemented"). Quote or cite the PRD behavior this delivers, and the Paint.NET behavior it mirrors.>

## User story
As a <PaintDotMac user>, <what they can do or see once this is done>.

## Scope & changes
- <Concrete change: the file(s)/type(s), their signatures where they matter, and the behavior. One
  bullet per coherent change.>
- <Keep Core logic and platform glue as separate bullets, and say which is which.>
- <Exact user-facing names (menu items, history step names, dialog labels, option names) as
  Paint.NET spells them.>
- <Accessibility identifiers the UI tests rely on (for example `canvas`, `historyList`,
  `layersList`, `statusBar.imageSize`), and any test-only launch hooks.>
- <project.yml changes and "run `xcodegen generate`".>
- <PRD update made in this change, if any: "PRD.md §N updated: …".>

## Acceptance criteria
- [ ] <Observable, checkable outcome, matching the PRD wording where possible. Each criterion
  names the test that proves it (`→ BrushToolTests.strokeIsClippedToSelection`), or is marked
  `→ manual` with a reason it can't be automated.>
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate
  launch smoke).

## Edge cases
- <Boundaries the implementer must handle and test: empty/0×0/1×1 images and selections, the
  largest supported dimensions and integer overflow in width×height×4, strokes and selections that
  cross tile boundaries or the canvas edge, fully transparent and semi-transparent pixels (straight
  alpha), zoom extremes (1% and 3200%) and 1×/2× backing scale, no active layer / hidden layer /
  locked state, undo and redo across the operation, cancel mid-operation, corrupt or truncated
  files, unsupported formats, permissions/IO errors, very large clipboard contents, etc.>
- <Every failure path has a defined, non-crashing behavior (an alert, a disabled menu item, a
  no-op) stated here.>

## Test plan
- **Unit tests** (`PaintDotMacTests/<Area>/<Type>Tests.swift`): <each test case and its exact
  assertion, for every piece of Core logic this spec adds or changes. Expected values come from the
  PRD, Paint.NET's documented formulas, or hand calculation, never from running the code.>
- **Round-trip and property tests:** <invariants checked over many seeded random inputs, with the
  seed printed on failure: undo then redo restores identical tiles; applying then reverting a tile
  diff is the identity; codec write → read preserves pixels (lossless formats) and layer
  properties; selection algebra (A ∪ A = A, invert twice = identity); resampling keeps
  dimensions; etc.>
- **Golden-image tests** (blend modes, effects, rendering): <fixture generated in the test, the
  independent oracle (a straightforward CPU reference implementation in the test target, or a small
  hand-computed image), and the ±1 per-channel tolerance. Goldens in `PaintDotMacTests/Golden/` are
  recorded only through an explicit opt-in (for example `RECORD_GOLDENS=1`) and only after the
  oracle has confirmed them.>
- **Integration tests** (headless): <a scripted editing session through Core: create or load a
  document, run tool events / effects / layer operations, undo/redo, save, reload, and assert on
  pixels and history names.>
- **UI tests** (`PaintDotMacUITests/<Feature>UITests.swift`): <launch the app with a fixture,
  perform the user story through menus, keyboard shortcuts, panels, and canvas drags, and assert
  through accessibility (history rows, layer rows, status bar values, enabled menu items) and,
  where pixels matter, by exporting and checking the file. Every spec that adds or changes UI adds
  at least one UI test.>
- **Performance** (when NF-1 to NF-4 apply): <`measure` test or timed integration test with the
  target from PRD §6. Gate only on gross regressions (for example 3× the target); report the
  measured number in the Verification status.>
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build
  with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (only what can't be automated): <step-by-step checks for look and feel
  (marching ants, Retina sharpness, dark mode), trackpad pinch, tablet pressure, `NSColorSampler`,
  perceived smoothness, with what to do and the expected result.>

## Open questions
- <Only if something is still unresolved. Leave this section out when everything is decided. A
  spec with open questions isn't ready for the implementer.>

## Out of scope
- <Explicitly excluded work, pointing to sibling specs or PRD non-goals (§2.2) where they apply.>
```

### 6. The test plan is the quality bar

Under `AGENTS.md`, work isn't done until it builds and its tests pass, and the user wants features
that demonstrably work and never crash. A long, thorough test suite that runs unattended for a
while is fine. So the **Test plan** must:

- **Cover every acceptance criterion and every edge case with a named test**, except for the few
  things that truly can't be automated, which go to **Manual verification** with a reason. A
  reviewer must be able to go down the acceptance criteria and find a test for each one.
- **Assert real outcomes.** Exact pixel values, tile contents, history step names, layer
  properties, file bytes or decoded pixels. "Doesn't throw" or "result is not nil" is never enough
  on its own.
- **Use independent oracles.** Expected values are computed by hand, from the PRD, from Paint.NET's
  documented formula, or by a simple reference implementation in the test target. Never by running
  the code under test and pasting its output.
- **Include failure paths.** Corrupt and truncated files, zero sizes, huge sizes, cancellation, and
  missing state each get a test that asserts the defined, non-crashing behavior.
- **Include undo/redo** for every pixel-changing or document-changing operation: apply, undo
  (identical to before), redo (identical to after).
- **Include at least one UI test** for every spec that adds or changes something the user can
  see or do, driving the real app the way the user story describes.
- If a spec is purely platform glue with no logic to extract, say so explicitly and justify it.
  Don't just leave the unit tests out. (There is usually something worth extracting: a coordinate
  transform, a state machine, a mapping from options to behavior, a menu-enablement rule.)

### 7. Stop

Write the file into `docs/specs/todo/` (plus any PRD update) and report back the path, a short
summary, the tests and manual checks you prescribed, and the dependency position. **Do not
implement the feature, write the tests, or touch application code.** That happens later, usually
through the spec-implementer skill.

---

## Mode B: close out a completed spec

Use this once the feature described by a `docs/specs/todo/…_TODO.md` spec has been built and the
user wants it checked and filed as done. (The spec-implementer skill does this automatically for
each spec it builds.)

### 1. Re-read the spec

Load the spec and check each acceptance criterion against the current code, and check that every
prescribed test exists and asserts what the spec says. If a criterion or a required test is
missing, add it before moving the file. A spec isn't done until its own test plan is satisfied.

### 2. Run the quality gate

From the repo root:

```bash
.agents/skills/spec-implementer/scripts/quality-gate.sh
```

It regenerates the project (if `project.yml` exists), checks that `Core` has no UI imports, makes
a clean Debug build with zero warnings allowed, runs every test (unit, golden, integration, UI)
and fails on any failed or skipped test, then launches the app empty, with a PNG, and with a JPEG
and fails if it crashes. Logs and result bundles are in `build/gate/`. UI tests drive the real
mouse and keyboard, so warn the user not to use the Mac while they run.

While iterating on one area, run the narrower commands from `AGENTS.md` (*Build and test*), for
example `xcodebuild … test -only-testing:PaintDotMacTests/<Suite>`, but the final word is always
a full gate run without `--incremental`.

### 3. Fix failures, with the PRD as the reference

When a test and the PRD disagree, the PRD is correct: fix the code and the test to match it. If the
PRD itself looks wrong or silent, ask the user, and update the PRD with their answer. Never make a
test pass by weakening its assertion, skipping it, or re-recording a golden without independent
confirmation. If you find an unrelated failure, fix it too (a red gate blocks everything), and say
so in the report. Re-run until the gate is green.

### 4. Move the spec to done

Once everything is green, move the spec from `docs/specs/todo/` to `docs/specs/done/`, renaming
`_TODO.md` → `_COMPLETED.md`. Use `git mv` so the history is kept:

```bash
git mv docs/specs/todo/<name>_TODO.md docs/specs/done/<name>_COMPLETED.md
```

Before moving it, add a **Verification status** section at the end of the spec that records the
date, the gate result (the summary lines it prints: test counts, UI tests, launch smoke), any
performance numbers measured, and each manual verification step as `[ ] not yet run by user` (or
`[x]` only if the user confirms they ran it). If the change affected the layout, commands, or
architecture rules, update `AGENTS.md` in the same change.

### 5. Report

Summarize what you checked, any fixes you made, and the final gate result. Say plainly whether it
is green, quote the summary output, and don't claim green if anything was skipped. List the manual
verification steps the user still needs to run, and give the new `docs/specs/done/` path.
