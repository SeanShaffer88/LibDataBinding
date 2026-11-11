# Release 1.0.0 — LibDataBinding-1.0

First public release of **LibDataBinding-1.0**, a reactive data-binding library
for **World of Warcraft Classic Forever** (`## Interface: 11507`).

Tie a widget property to a data source once and let the library keep it
current: it re-evaluates on the right client events, batches the work into one
widget write per frame, and skips writes whose value did not change.

```lua
local LDB = LibStub("LibDataBinding-1.0")

LDB:NewBinding(MyAddon.healthBar, "SetMinMaxValues", "UnitHealthMinMax")
LDB:NewBinding(MyAddon.healthBar, "SetValue",        "UnitHealth")
LDB:NewBinding(MyAddon.nameText,  "SetText",         "UnitName", { unit = "target" })
```

---

## Installation

This release is source-only (no packaged zip attached). Install from the tag:

1. Download **Source code (zip)** below and extract it. You get
   `LibDataBinding-1.0.0/LibDataBinding-1.0/`.
2. Move the **inner `LibDataBinding-1.0` folder** into
   `Interface/AddOns/`, so the final path is
   `Interface/AddOns/LibDataBinding-1.0/LibDataBinding-1.0.toc`.
3. `LibStub` is required — install it standalone or embed it in your own addon
   **before** `LibDataBinding-1.0.lua`.
4. `/reload`, then run `/libdatabinding test` to run the self test and open a
   demo health panel.

The `tests/` folder in the archive is development-only; the TOC does not load
it, so you can delete it. From tag `1.0.1` onward,
`.github/workflows/release.yml` attaches a ready-to-install
`LibDataBinding-1.0-<version>.zip` (addon folder at the archive root) to every
release.

Addon authors embedding the library should copy the folder into `Libs/` and
list `Libs\LibDataBinding-1.0\LibDataBinding-1.0.lua` after LibStub in their
TOC. Duplicate copies no-op through `LibStub:NewLibrary`, so several addons can
embed it at once.

**Requires:** LibStub only. No other dependencies.

---

## Highlights

- **`NewBinding(target, property, source, options)`** — `source` may be a
  function, a registered data-source name, a table path, or an inline
  getter/events descriptor.
- **Properties** — `SetText`, `SetValue`, `SetMinMaxValues`,
  `SetStatusBarColor`, `SetVertexColor`, `SetAlpha`, `ShowHide`, any widget
  method name, a custom function applier, and `RegisterProperty` for named
  extensions.
- **Built-in sources** — `UnitHealth`, `UnitHealthMax`, `UnitHealthMinMax`,
  `UnitHealthPercent`, `UnitPower`, `UnitPowerMax`, `UnitName`, `GetMoney`,
  `GetSpellCooldown`; unit sources take `options.unit` and follow target,
  focus, mouseover and pet switches automatically.
- **Options** — `formatter` (multi-return aware), `throttle` (defers, never
  drops), `condition`, `default`, `poll`, `unit`, `args`, `eventFilter`.
- **Cheap when idle** — a single unnamed driver frame that hides itself when the
  queue is empty, so no `OnUpdate` runs at all. Redundant widget writes are
  suppressed by an argument-level change cache (`/libdatabinding stats` shows
  the ratio).
- **Automatic event lifecycle** — reference-counted `RegisterEvent`/
  `UnregisterEvent`, unit-filtered before any work happens, and guarded with
  `pcall` so an event a build does not have degrades to manual updates.
- **No taint** — no `_G` writes beyond the two `SLASH_LIBDATABINDING` keys, no
  Blizzard frame hooks, no protected attributes, no named driver frame.
- **Chains** — several bindings may share one property; they replay in creation
  order, the newest wins, and unbinding hands the property back immediately.
- **Robust** — getters, formatters and appliers run inside `pcall`; failures are
  counted, reported once, and the binding is dropped after 50 failures.
  Re-entrant `Flush`/`Update`/event filters are guarded.
- **`/libdatabinding`** (`/ldb`) with `test`, `list`, `stats`, `flush`, `debug`
  and `reset`; `test` runs a 20-check validation suite plus a demo panel.

---

## Verification

- Headless suite: **123 checks passing** on Lua 5.1, 5.2, 5.3, 5.4 and
  LuaJIT 2.1 (121 on 5.2+, where the `setfenv`-based global-leak audit is
  skipped). Run it with `lua tests/run.lua` from the repository root.
- Packaged build: the addon folder was extracted from tag `1.0.0`, loaded
  through its TOC file list alone, and passed a player-health binding, an
  event-driven target-name binding and the 20-check in-game self test.
- In-game self test: **20/20** checks pass from the packaged build, and the
  package was loaded through its TOC file list in a simulated clean install.
- Size: **517 non-comment lines of engine** (including the built-in data
  sources), 779 lines in total for the file.

---

## Known limitations

See [the README](https://github.com/SeanShaffer88/LibDataBinding/blob/1.0.0/LibDataBinding-1.0/README.md#10-compatibility-notes-limitations-and-taint)
for the full list. The important ones:

1. Table-path sources have no events — call `binding:Update()` or
   `lib:UpdateAll()` after mutating the table (or use `poll`).
2. One write per binding per frame, by design.
3. Chains are "last writer wins", not merge semantics.
4. `GetSpellCooldown` needs `poll` for a smooth countdown; its events only fire
   on start/stop.
5. Unit sources default to `player`; declare `unit = "target"` (etc.) or unit
   events for other tokens will be ignored.
6. Visual widgets only — no secure/protected attribute writes.
7. Bindings do not survive `/reload`; recreate them when your addon loads.

---

## Metadata note

The TOC ships `## X-Dependencies: none` rather than `## Dependencies: none`,
because the client parses `## Dependencies` as a list of **addon folder names**
and a literal `none` would be reported as a missing addon. `X-Dependencies` is
an ignored metadata key that documents the same thing safely.

---

## Full changelog

See [`LibDataBinding-1.0/CHANGELOG.md`](https://github.com/SeanShaffer88/LibDataBinding/blob/1.0.0/LibDataBinding-1.0/CHANGELOG.md).

**Semantic versioning:** this is `1.0.0`. Major = breaking API change, minor =
new sources/properties/options, patch = fixes only.
