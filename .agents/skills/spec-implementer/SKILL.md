---
name: spec-implementer
description: >
  Work through the backlog of specs in docs/specs/todo/ and implement them one at a time, each in
  its own sub-agent, end to end: Swift code, unit/golden/integration/UI tests, the full quality
  gate (clean build with zero warnings, every test, launch smoke test) with fixes, an independent
  review sub-agent that hunts for untested behavior and crashes, PRD/AGENTS.md updates, a
  manual-verification checklist, then commit on main and move the spec into docs/specs/done/.
  After the batch, run the gate with sanitizers and a Release build. Use this whenever the user
  wants the PaintDotMac todo specs actually BUILT (not just planned): "implement the specs in
  docs/specs/todo", "work through the backlog", "build out the todo folder", "implement 0003
  through 0007", "build milestone M1", "clear the spec queue". Trigger even when the user names
  specific spec files or a range instead of the whole folder. Do NOT trigger for authoring a new
  spec (that is the spec-writer skill). This skill assumes the specs already exist and implements
  them.
---

# Spec Implementer

This skill drives the **PaintDotMac** implementation backlog. Each file in `docs/specs/todo/` is a
ready-to-build spec written by the spec-writer skill. Your job is to turn those specs into built,
tested, reviewed, committed work, **one spec at a time, in order, each inside its own sub-agent.**

Running this skill counts as the user asking for commits. `AGENTS.md` says to commit only when
asked, and here the user has asked, once per spec.

## The quality bar

The user must be able to open the app after a batch and find that every shipped feature works and
nothing crashes. Green is defined by one command, the **quality gate**:

```bash
.agents/skills/spec-implementer/scripts/quality-gate.sh
```

It regenerates the project, checks that `Core` has no UI imports, makes a **clean** Debug build
that fails on any compiler warning, runs **every** test in the scheme (unit, golden-image,
integration, and XCUITest UI tests) and fails on any failed or skipped test or a missing UI test
run, then launches the built app empty, with a PNG, and with a JPEG, and fails if it exits or
leaves a crash report. `--sanitizers` adds Address/Undefined Behavior Sanitizer and Thread
Sanitizer runs, and `--release` adds a clean Release build with its own smoke test. A long gate is
fine; the user prefers a slow, thorough suite that runs unattended over a fast one that misses
things.

On top of the gate, every spec gets an **independent review**: a second sub-agent with fresh eyes
checks that each acceptance criterion has a test that would fail if the feature broke, runs
mutation spot-checks, hunts for crash paths, and fixes what it finds. The implementer marking its
own homework is not enough.

## Why one at a time, in order

Every spec ends with a full gate run and a commit on `main`. Specs are numbered in dependency
order: later ones build on the types, files, and targets that earlier ones create. Built in
parallel, they would race on `project.yml`, the generated project, `build/`, the UI test runner
(which drives the real mouse and keyboard), and the same branch, and you couldn't tell which change
broke what. Running them strictly in order means each sub-agent starts from a clean, green `main`
that already contains the previous spec's work, so every failure can be traced to one spec and the
history stays bisectable. **Never parallelize.** Finish, review, and check one spec before starting
the next.

## Implementations take a long time, so be patient

One spec can keep a sub-agent busy for well over an hour: Swift and Metal code, many tests, clean
`xcodebuild` builds, UI test runs, and fixing whatever turns up. The review takes a while too. That
is normal, not a hang. **Don't abandon, interrupt, or declare a sub-agent failed before at least 45
minutes of real work.** A quiet sub-agent that is building or testing is working, not stuck.

## What can't be verified here

UI tests and the launch smoke test cover a lot, but some things still need a person: how the
canvas looks (Retina sharpness, marching ants, dark mode), trackpad pinch and two-finger pan feel,
tablet pressure, `NSColorSampler`, and perceived smoothness. A spec is "done" for this skill when
the gate is green, the review passed, and its remaining manual steps are written down for the
user. Those steps never count as verified until the user says so. Keep that distinction in every
report.

---

## Workflow

### 1. Preflight

Before building anything, check the environment once. Ask the user about anything that's missing;
these are their decisions, not yours:

- **Git:** the repo must be a git repository on `main` with a clean working tree. If it isn't a
  repo yet (`AGENTS.md` notes that it may not be), ask whether to run `git init -b main` and make
  an initial commit of the existing files. If the tree is dirty, ask what to do with the changes.
  Never stash or discard them yourself.
- **Remote:** check for an upstream (`git rev-parse --abbrev-ref @{u}`). If there is one, each spec
  is pushed after it's committed. If there isn't, commits stay local, and you say so in the reports.
- **Tooling:** `xcodebuild` (Xcode with the macOS SDK), `jq`, and, if the project uses or the
  foundation spec chooses XcodeGen, `xcodegen` must be on `PATH`. If something is missing, ask the
  user to install it (for example `brew install xcodegen`). Don't install tools on your own.
- **UI tests:** XCUITest on macOS needs Developer Mode (`DevToolsSecurity -status` must say
  enabled; the user enables it once with `sudo DevToolsSecurity -enable`) and, on the first run,
  the user approving the test runner's Accessibility/automation prompt. If Developer Mode is off,
  ask the user to enable it before starting. Also tell them that UI tests take over the mouse and
  keyboard and the gate opens app windows, so they shouldn't use the Mac while the batch runs.
  Only if the user says UI tests can't run on this Mac, run the gate with `--skip-ui` for the whole
  batch and state that loudly in every report.

### 2. Determine the queue

List `docs/specs/todo/` and decide which specs to implement:

- If the user named specific specs, a range (for example "0003 through 0007"), or a milestone, do
  exactly those.
- Otherwise, do **every** `*_TODO.md` in the folder, in ascending filename order. The numbering is
  the dependency order.

For each spec, check its `Depends on:` line. If a dependency is neither in `docs/specs/done/` nor
earlier in this queue, flag it. A spec with a non-empty **Open questions** section isn't ready:
list those questions and get answers (update the spec and the PRD) before it runs, or leave it out
of the queue.

Show the user the ordered list and the count, then start. Once they've approved the queue, you
don't need approval for each spec. The point of this skill is to run the whole batch on its own.

### 3. For each spec: implement, then review

Work through the queue top to bottom. For each spec:

1. Launch a **single** `general-purpose` sub-agent with the **implementer brief** below (with the
   current spec's path filled in) and wait until it has finished.
2. Then launch a **single, fresh** `general-purpose` sub-agent with the **reviewer brief** below
   for the same spec and wait until it has finished. Don't reuse the implementer: the review is
   only worth something with fresh eyes.

Never have two sub-agents running at once. Waiting for each one is what keeps the work in order.

### 4. Check, repair, and continue

When the reviewer returns, confirm the spec is really finished before you start the next one:

- The spec file has moved out of `docs/specs/todo/` into `docs/specs/done/` as `_COMPLETED.md`,
  with a **Verification status** section that includes the gate summary and the review result.
- There are new commits on `main` and `git status` is clean. If there's an upstream, they have been
  pushed (`git status -sb`).
- The gate is green. **Re-run it yourself** (`quality-gate.sh`, no `--incremental`) and read the
  summary. This is the run that counts; don't rely on the sub-agents' word for it.

If anything is missing or red, fix it yourself before starting the next spec. Don't ask the user:

1. Re-run the failed or incomplete command cleanly.
2. Diagnose and fix every failure, including failures that existed before this spec.
3. Re-run the affected tests, then the full gate.
4. Commit the fixes on `main` (and push them if there's an upstream).
5. Continue only when the spec has been moved, the tree is clean, and the gate is green.

For build-environment problems (a hung `xcodebuild`, a stale generated project, a locked build
database, a UI test runner stuck from a previous run): kill leftover `xcodebuild` and app
processes, re-run `xcodegen generate` if the project uses it, delete `build/DerivedData*` if
necessary, then run again. A UI test that fails because the Accessibility prompt is waiting for
approval is a blocker for the user, not a code bug.

**Stop and ask the user** only when the work can't continue without them:
- a product decision that `PRD.md`, Paint.NET's documentation, and the spec don't settle
  (`AGENTS.md`: ask, don't guess);
- a new dependency, a minimum macOS change, a native file format change, a signing or entitlement
  change, or another change `AGENTS.md` says to ask about;
- missing tools, credentials, or permissions (including Developer Mode and the Accessibility
  prompt for UI tests).

When you halt, leave the blocked spec in `todo/` and stop the batch, because later specs probably
depend on it. Once the user answers, update the PRD and the spec, then resume the same spec (send
the answer to the same sub-agent if it's still there, or start a fresh one with the brief plus the
answer).

### 5. Report progress as you go

After each spec closes, post a one-line status, for example
`✅ 0007-paintbrush: gate green (214 tests, 9 UI), review fixed 2 gaps, committed a1b2c3d (local), 3 manual checks pending`.

### 6. Close the batch: deep gate and a Release build

Once the queue is finished and at least one spec shipped without stopping the batch, run the full
gate one last time with everything on:

```bash
.agents/skills/spec-implementer/scripts/quality-gate.sh --sanitizers --release
```

This adds the unit tests under Address + Undefined Behavior Sanitizer and under Thread Sanitizer,
plus a clean Release build that is smoke-tested and copied to `build/PaintDotMac.app`. Fix every
finding the same way as step 4 (sanitizer reports are real bugs, not noise) and commit the fixes.
If the batch halted on a blocker, still run this on what shipped, and say so.

The gate first checks that each sanitizer can run a trivial program on this Mac. Some macOS and
Xcode combinations ship a sanitizer runtime that hangs or crashes at startup; this happened with
macOS 26.6 and Xcode 26.3. In that case the gate prints `UNAVAILABLE … NOT RUN` for that
sanitizer and still finishes. Never present that as a sanitizer pass. Tell the user in the final
summary that the memory and race checks did not run, and that they will run again once an Xcode
update fixes the toolchain.

PaintDotMac is for personal use (PRD §2.2, §4): there is no GitHub release, version bump, or
distribution step. The deliverable is the green `main` and `build/PaintDotMac.app`.

Then give the user the final summary: which specs shipped (with requirement IDs), any that were
skipped or that stopped the batch, the final state of the queue, the deep gate's summary lines, the
path to the Release app, which milestone exit criteria (PRD §8) are now met, and **one combined
manual verification checklist** covering every spec in the batch, grouped by spec, so the user can
work through it in one session.

---

## The implementer brief

Give each implementer sub-agent this brief, with `<SPEC_PATH>` replaced by the current spec. Keep
all the guardrails: sub-agents start with none of your context, so everything they need has to be
in the prompt.

```
You are implementing ONE spec for PaintDotMac, a native macOS raster image editor inspired by
Paint.NET (Swift 6, SwiftUI shell + AppKit canvas, Metal, Core Image, ImageIO), end to end, on the
`main` branch. Work in the repository root.

Spec to implement: <SPEC_PATH>

Read these first. They are binding:
- The spec itself, in full (Context, Scope & changes, Acceptance criteria, Edge cases, Test plan,
  Out of scope).
- AGENTS.md: tech stack, layout, architecture rules, build and test commands, testing
  expectations, code style, commit style. Follow it exactly.
- PRD.md (repo root): the SOURCE OF TRUTH for behavior. When the code, the spec, or your own
  assumptions disagree with the PRD, the PRD wins. If the PRD and the spec are both silent or
  ambiguous on a product decision you need, DO NOT GUESS: stop and report it as a blocker.
- The specs in docs/specs/done/ that this spec depends on, so you reuse their types instead of
  creating parallel ones.

THE BAR: the user will open the app after this batch. Every feature in this spec must work as the
spec says, and nothing may crash. The tests you write are how that is proven, so they must be able
to fail when the feature is broken.

Key project rules (from AGENTS.md, repeated because they're easy to get wrong):
- Core (PaintDotMac/Core) never imports AppKit or SwiftUI (Cocoa/UIKit neither). The gate checks.
- Every pixel change goes through history (a HistoryItem with tile diffs). Never mutate layer
  pixels outside it. 256×256 tiles for storage, dirty regions, undo, and GPU uploads.
- Pixels are 8-bit sRGB RGBA, straight alpha; premultiply only inside the compositor; keep the
  pixel format behind its abstraction.
- Effects conform to ImageEffect with a parameter schema and are registered; dialogs and previews
  are generated from the schema, never hand-written per effect.
- Tools conform to the Tool protocol; options persist in UserDefaults under tool.<id>.<option>.
- UI and document state on @MainActor; heavy pixel work off the main actor, checks
  Task.isCancelled, reports progress. Swift 6 strict concurrency: fix diagnostics properly, don't
  silence them with @unchecked Sendable or nonisolated(unsafe) without a justified comment.
- Selections are a vector path plus a cached 8-bit antialiased mask; painting and effects clip to it.
- Shortcuts follow PRD §5.12. User-facing names match Paint.NET's.
- If project.yml exists, it is the source of truth: never edit project.pbxproj, run
  `xcodegen generate` after adding or removing files or targets.
- No third-party dependencies, no minimum macOS change, no native format change.
- No force unwraps, try!, fatalError, or precondition on any path a user or a file can reach.
  Untrusted input (files, clipboard, sizes, parameters) is validated and fails gracefully with a
  defined behavior (alert, disabled item, no-op). Watch integer overflow in width × height × 4 and
  division by zero in scale math. A crash is a defect, never an acceptable outcome.
- Reuse and extend existing code before adding new code. Avoid duplication and magic numbers.

Do the work in this order:

1. WRITE THE TESTS FROM THE SPEC FIRST for the Core logic: every test the Test plan lists, with
   expected values from the spec, the PRD, Paint.NET's documented formulas, or hand calculation.
   Never compute an expected value by running the code under test. Golden images need an
   independent oracle (a simple CPU reference implementation in the test target, or a small
   hand-computed image); record goldens only through the explicit opt-in the project defines,
   and only after the oracle agrees. Use seeded randomized round-trip/property tests where the
   Test plan asks for them, printing the seed on failure. Test fixtures are generated in code;
   don't commit binaries over 1 MB.

2. IMPLEMENT the spec's Scope & changes so every Acceptance criterion is met and every listed Edge
   case behaves as specified.

3. WRITE THE UI TESTS (PaintDotMacUITests) the Test plan lists: launch the app with a fixture
   through the project's test launch hook, perform the user story through menus, shortcuts,
   panels, and canvas drags, and assert through accessibility identifiers/values (history rows,
   layer rows, status bar) and, where pixels matter, by exporting and checking the file. Use
   waitForExistence instead of sleeps. A UI test that passes when the feature is missing is
   worthless: check that each one fails if you comment out the feature's entry point, then
   restore it.

4. MAKE EVERYTHING PASS. Iterate with narrow runs (see AGENTS.md, e.g.
   -only-testing:PaintDotMacTests/<Suite>), then run the full quality gate from the repo root:
     .agents/skills/spec-implementer/scripts/quality-gate.sh
   It does a clean build that fails on warnings, runs every test (unit, golden, integration, UI)
   and fails on any failed or skipped test, and launch-smoke-tests the app with a PNG and a JPEG.
   Logs are in build/gate/. Fix every failure, whether this spec caused it or it was already
   there. NEVER make a test pass by weakening its assertion, deleting it, skipping or disabling it,
   widening a tolerance beyond ±1, or re-recording a golden without the oracle. Don't call it green
   unless the gate printed GREEN. If a run hangs or collides, kill leftover xcodebuild and app
   processes, regenerate the project, delete build/DerivedData* if needed, and run again. If UI
   tests can't run because of a system permission prompt or Developer Mode, that's a blocker.
   (Only if this brief says the batch runs with --skip-ui, pass --skip-ui.)

5. PERFORMANCE: if the spec touches the canvas, compositing, or history, run the performance tests
   the spec prescribes and record the numbers against PRD §6 (NF-1 to NF-4).

6. MANUAL STEPS: finalize the spec's Manual verification steps so they match what you actually
   built, and keep them to what truly can't be automated. Never claim them as verified.

7. UPDATE DOCS in the same change. If you settled a behavior detail that the PRD should record (only
   within what the spec already decided), update PRD.md. If the project layout, commands, or
   architecture rules changed, update AGENTS.md (keep *Build and test* accurate). If a tool, effect,
   or shortcut differs from a PRD table, update that table. Edit existing sections; don't add new
   docs.

8. MOVE THE SPEC to done, keeping its history and following the naming convention:
     git mv docs/specs/todo/<name>_TODO.md docs/specs/done/<name>_COMPLETED.md
   Then append a "## Verification status" section to it: the date, the gate's summary lines (test
   counts, UI tests, launch smoke), performance numbers if any, and each manual verification step
   as "- [ ] not yet run by user". Leave a "Review:" line for the reviewer to fill in.

9. COMMIT on main. Don't create a branch or open a PR. Use the conventional commit style from
   AGENTS.md with the requirement IDs and the spec ID, for example
   "feat(tools): add Paintbrush with width and hardness (T-11) [spec 0007]". Include the spec move.
   Follow your harness's commit attribution instructions (co-author trailer). If
   `git rev-parse --abbrev-ref @{u}` shows an upstream, push. If not, leave the commit local and
   say so.

Report back: what you implemented, the files you created or changed, the tests you added (by
kind: unit, property, golden, integration, UI, performance), the final gate summary lines (say
plainly whether it printed GREEN), any PRD/AGENTS.md edits, the commit hash and whether it was
pushed, confirmation that the spec now lives in docs/specs/done/, anything you were unsure about,
and the manual verification checklist the user still needs to run.

Don't stop for ordinary build or test failures: diagnose, fix, and re-run until green. Report a
BLOCKER and stop (without committing half-finished work, and without moving the spec) only for
things you mustn't decide alone: a product decision the PRD, Paint.NET's docs, and the spec don't
settle, a new dependency, a minimum macOS or file format change, a signing/entitlement change, or
missing tools or permissions. Explain exactly what needs deciding, give your recommended answer,
and say what state you left the working tree in.
```

---

## The reviewer brief

Give each reviewer sub-agent this brief, with `<SPEC_PATH>` replaced by the spec's new path in
`docs/specs/done/` and `<COMMITS>` by the implementer's commit range (for example
`a1b2c3d^..HEAD`).

```
You are the independent reviewer for ONE just-implemented spec of PaintDotMac, a native macOS
raster image editor (Swift 6, SwiftUI + AppKit, Metal, Core Image, ImageIO). Another agent
implemented it; your job is to make sure it really works, is really tested, and can't crash, and
to fix what isn't. Work in the repository root, on `main`.

Spec: <SPEC_PATH>     Changes: git show / git diff <COMMITS>

Read the spec, AGENTS.md, and PRD.md (the source of truth) first. Then:

1. TRACE EVERY ACCEPTANCE CRITERION AND EDGE CASE to a test that would fail if it were broken.
   Read the tests: they must assert real outcomes (pixel values, tile contents, history names,
   layer properties, decoded file contents, accessibility values), with expected values from an
   independent source, not copied from the code's output. Write any missing test.

2. MUTATION SPOT-CHECKS: pick at least three important lines of the new behavior (a blend formula,
   a clamp, a history registration, a selection clip, a menu action), break each one on purpose,
   run the relevant tests, and confirm at least one fails. Restore the code each time (verify with
   git diff). Every mutation that survives means a missing test: write it.

3. HUNT FOR CRASHES AND RULE BREAKS in the diff: force unwraps, try!, fatalError/precondition on
   reachable paths, unchecked array or buffer indexing, integer overflow in size math, division by
   zero, unbounded allocations from file headers, main-actor violations, races, retain cycles,
   pixel changes that bypass history, UI imports in Core, hand-written effect dialogs, hardcoded
   values that belong in a schema or settings, missing undo. Fix them and add a test for each.

4. CHECK THE UI TESTS drive the real user story, and that the launch hook and accessibility
   identifiers they rely on are in place. Add a UI test if a user-visible behavior has none.

5. RUN THE FULL QUALITY GATE from the repo root and get it to GREEN:
     .agents/skills/spec-implementer/scripts/quality-gate.sh
   (Only pass --skip-ui if this brief says the batch runs that way.) Never weaken, skip, or delete
   a test, widen a tolerance, or re-record a golden without an independent oracle to get there.

6. RECORD AND COMMIT. Fill in the "Review:" line in the spec's Verification status (mutations
   tried and caught, tests added, issues fixed, final gate summary lines). If you changed anything,
   commit on main as "test(...)/fix(...): review fixes for <requirement IDs> [spec NNNN]" with
   your harness's co-author trailer, and push if there's an upstream. If you changed nothing but
   the spec file, still commit that.

Report back: the criteria you traced (and any that had no test), the mutations you tried and
whether each was caught, the issues you found and fixed, the tests you added, the final gate
summary (say plainly whether it printed GREEN), and the commit hash. Stop and report a BLOCKER
only for product decisions the PRD and the spec don't settle, or the other things AGENTS.md says
to ask about.
```

---

## Notes and edge cases

- **Nothing to do.** If `docs/specs/todo/` has no `*_TODO.md` files, say so and stop.
- **A spec turns out to be already done.** If the implementer finds the acceptance criteria already
  met, it still writes any missing tests, runs the full gate, moves the spec with its Verification
  status, and commits. The reviewer still runs. Filing it correctly is part of the job.
- **The first spec creates the project.** Before the Xcode project exists, the gate can't run. The
  foundation spec creates the project, the three targets, and the UI test launch hook, and its own
  gate run is the first real one. If the first spec in the queue *isn't* the foundation and there's
  no project, stop and tell the user: the backlog is missing its foundation spec (the spec-writer
  skill can add one).
- **Gate names.** The gate expects scheme `PaintDotMac`, targets `PaintDotMacTests` and
  `PaintDotMacUITests`, and `PaintDotMac/Core`. If the foundation spec chose other names, set the
  `SCHEME`, `UNIT_TARGET`, `UI_TARGET`, and `CORE_DIR` environment variables, and record that in
  `AGENTS.md`.
- **Don't squash the batch into one commit.** Each spec gets its own implementer commit(s) and
  review commit, so each spec maps to one reviewable, bisectable change in the history.
- **Recover on your own.** A failed, incomplete, or colliding build is not a reason to pause the
  batch. Clean up, re-run, fix every failure (including ones that were already there), commit the
  repair, and continue in order. Ask the user only about the blockers listed in step 4.
