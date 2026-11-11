<img src=".github/assets/banner.png" alt="LibDataBinding-1.0 — reactive data binding for WoW Classic Forever" width="100%">

<p align="center">
  <img src=".github/assets/icon.png" width="88" height="88" alt="LibDataBinding-1.0 icon">
</p>

# LibDataBinding-1.0

**Reactive data binding for World of Warcraft Classic Forever addons** — declare what a widget shows, once.

[![Interface](https://img.shields.io/badge/interface-11507-33ff99)](#compatibility)
[![Version](https://img.shields.io/badge/version-1.0.2-33ff99)](LibDataBinding-1.0/CHANGELOG.md)
[![Dependencies](https://img.shields.io/badge/dependencies-LibStub%20only-1f2937)](#install-addon-authors)
[![License](https://img.shields.io/badge/license-MIT-1f2937)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-123%20passing-33ff99)](tests/README.md)
[![Lua](https://img.shields.io/badge/lua-5.1%20%7C%205.4%20%7C%20LuaJIT-1f2937)](tests/README.md)

Stop writing event handlers for every label. Tie a `FontString`, `StatusBar` or
`Texture` to a data source, and LibDataBinding keeps it current: it re-reads the
source when the relevant events fire, batches the work into **one widget write
per frame**, and skips writes whose value did not change.

```lua
local LDB = LibStub("LibDataBinding-1.0")

LDB:NewBinding(MyAddon.healthBar, "SetMinMaxValues", "UnitHealthMinMax")
LDB:NewBinding(MyAddon.healthBar, "SetValue",        "UnitHealth")
LDB:NewBinding(MyAddon.nameText,  "SetText",         "UnitName", { unit = "target" })
```

That is the whole feature: three declarations, no `RegisterEvent`, no
`OnUpdate`, no stale-label bug when the target changes.

---

## Why

| Problem | LibDataBinding |
| --- | --- |
| Every widget needs its own event handler | One `NewBinding` call per property |
| `OnUpdate` polling burns CPU on an idle UI | Event-driven; the driver frame **hides itself** when the queue is empty, so an idle library costs zero per frame |
| Ten events in one frame → ten setter calls | Collapsed per binding: **one write per frame** |
| Rewriting the same string every event | Argument-level change cache; `/libdatabinding stats` shows suppressed writes |
| Forgetting `UnregisterEvent` | Reference-counted: events are released with the last binding that needed them |
| Damaged/copy-pasted unit-filtering logic | Unit events are compared against `options.unit` before any work happens |
| Tainting the default UI | No `_G` writes beyond its two slash keys, no Blizzard frame hooks, no protected attributes, unnamed driver frame |
| A broken getter spams chat | Getter/formatter/applier run in `pcall`; errors are counted, reported once, binding dropped after 50 failures |

## Quick start

```lua
local LDB = LibStub("LibDataBinding-1.0")

-- A bar bound to the player's health, green → red as it drops.
LDB:NewBinding(bar,   "SetMinMaxValues",   "UnitHealthMinMax")
LDB:NewBinding(bar,   "SetValue",          "UnitHealth")
LDB:NewBinding(bar,   "SetStatusBarColor", "UnitHealthPercent", {
    formatter = function(pct) local f = pct / 100
        return 1 - f * 0.85, 0.15 + f * 0.75, 0.15 end,
})

-- A label driven by your own data, with a custom event.
LDB:RegisterDataSource("MyAddon.Points", function() return MyDB.points end,
    { "MYADDON_POINTS_CHANGED", "PLAYER_ENTERING_WORLD" })
LDB:NewBinding(label, "SetText", "MyAddon.Points", {
    formatter = function(v) return LDB.Formatters.abbreviate(v) .. " pts" end,
})
```

## Install (players)

1. Copy the **`LibDataBinding-1.0`** folder (the one with the `.toc`) into
   `World of Warcraft/_classic_era_/Interface/AddOns/`.
2. Make sure `Interface/AddOns/LibStub/` exists — the library requires it.
3. `/reload`, then run `/libdatabinding test` to run the self test and open a
   demo health panel.

Grab it from [Releases](https://github.com/SeanShaffer88/LibDataBinding/releases)
— tag archives work too, but move the **inner** folder into `AddOns/` (GitHub
nests the source zip one level deep).

## Install (addon authors)

```lua
-- your .toc, after LibStub
Libs\LibStub\LibStub.lua
Libs\LibDataBinding-1.0\LibDataBinding-1.0.lua
```

```lua
local LDB = LibStub("LibDataBinding-1.0")
```

`LibStub:NewLibrary` no-ops on duplicate copies, so several addons can embed
LibDataBinding at once. Do **not** also add `## Dependencies: LibDataBinding-1.0`
if you embed it; `## OptionalDeps` is enough to honour a standalone install.

## Documentation

| Document | Contents |
| --- | --- |
| [`LibDataBinding-1.0/README.md`](LibDataBinding-1.0/README.md) | Full API reference, built-in sources, options, two complete examples, testing guide, architecture, performance notes, taint model, 12 known limitations, versioning |
| [`LibDataBinding-1.0/CHANGELOG.md`](LibDataBinding-1.0/CHANGELOG.md) | Release notes from 1.0.0 → 1.0.2 |
| [`tests/README.md`](tests/README.md) | Headless suite: 123 checks that run the shipping Lua file against a mock client |

**API at a glance**

```
LDB:NewBinding(target, property, source, options) -> binding
LDB:RegisterDataSource(name, getter, events)      LDB:UnregisterDataSource(name)
LDB:GetBindings(target)  LDB:UnbindAll([target])  LDB:UpdateAll()  LDB:Flush()
LDB:RegisterProperty(name, applier)               LDB:GetStats()   LDB:SetDebug(on)
LDB.Formatters.percent / .abbreviate / .money / .seconds
binding:Update([force])  binding:Unbind()  binding:GetValue()  binding:IsBound()
```

Properties: `SetText`, `SetValue`, `SetMinMaxValues`, `SetStatusBarColor`,
`SetVertexColor`, `SetAlpha`, `ShowHide`, any widget method name, a custom
function, or `RegisterProperty`.
Sources: `UnitHealth`, `UnitHealthMax`, `UnitHealthMinMax`, `UnitHealthPercent`,
`UnitPower`, `UnitPowerMax`, `UnitName`, `GetMoney`, `GetSpellCooldown` — or your
own function / table path / inline descriptor.
Options: `formatter`, `throttle`, `condition`, `default`, `poll`, `unit`, `args`,
`eventFilter`.

## Compatibility

- **Client:** WoW Classic Forever, `## Interface: 11507`. No deprecated API
  (`this`, `getglobal`, `arg1..argN`).
- **Library:** LibStub only. Optional `Ace3`/`AceGUI` addons can use it freely;
  nothing is monkey-patched and no frame names are claimed.
- **Taint:** none — verified by a test that loads the file in a sandbox and
  asserts the only globals written are the two `SLASH_LIBDATABINDING` keys.
- **Limits:** table-path sources have no events (call `Update()`/`UpdateAll()`);
  one write per binding per frame; chains are last-writer-wins; visual widgets
  only (no secure/protected attributes). Full list in the
  [addon README](LibDataBinding-1.0/README.md#10-compatibility-notes-limitations-and-taint).

## Development

```bash
lua tests/run.lua        # 123 checks; Lua 5.1-5.4 and LuaJIT
```

The suite loads the shipping `LibDataBinding-1.0.lua` unmodified on top of a
mock client (frames, widgets, events, controllable clock) and exits non-zero on
failure. Pushing a version tag runs the same suite in CI
(`.github/workflows/release.yml`), verifies the TOC version matches the tag, and
attaches `LibDataBinding-1.0-<version>.zip` to the release.

## Repository layout

```
LibDataBinding-1.0/           the addon / embeddable library
├── LibDataBinding-1.0.toc    ## Interface: 11507, ## IconTexture, no deps
├── LibDataBinding-1.0.lua    engine + built-in sources + self test
├── README.md  CHANGELOG.md  LICENSE
└── media/                    icon.png (64), icon@2x.png (128)
.github/
├── assets/                   icon, social preview, README banner
└── workflows/release.yml     test → package → attach zip
tests/                        development only, never loaded in game
├── run.lua  wow_mock.lua  LibStub.lua  luarun.py
└── README.md
```

## Version

**1.0.2** — see [versioning](LibDataBinding-1.0/README.md#11-versioning).
Major = breaking API change, minor = new sources/properties/options, patch =
fixes and packaging/docs.

## License

MIT © Sean Shaffer. See [`LICENSE`](LICENSE).
