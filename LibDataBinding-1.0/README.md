# LibDataBinding-1.0

Reactive data binding for **World of Warcraft Classic Forever** (Interface `11507`).

Declare *"this FontString shows the target's name"* once and stop writing
event handlers. LibDataBinding re-reads the source when the relevant events
fire, batches the work into one widget write per frame, and skips writes whose
value did not change.

```lua
local LDB = LibStub("LibDataBinding-1.0")

LDB:NewBinding(MyAddon.healthBar, "SetMinMaxValues", "UnitHealthMinMax")
LDB:NewBinding(MyAddon.healthBar, "SetValue",        "UnitHealth")
LDB:NewBinding(MyAddon.nameText,  "SetText",         "UnitName", { unit = "target" })
```

No `OnUpdate` polling, no `RegisterEvent` boilerplate, no globals, no taint.

---

## Contents

1. [Installation](#1-installation)
2. [Quick start](#2-quick-start)
3. [API reference](#3-api-reference)
4. [Data sources](#4-data-sources)
5. [Options](#5-options)
6. [Examples](#6-examples)
7. [Testing guide](#7-testing-guide)
8. [How it works](#8-how-it-works)
9. [Performance](#9-performance)
10. [Compatibility notes, limitations, taint](#10-compatibility-notes-limitations-and-taint)
11. [Versioning](#11-versioning)
12. [File layout and embedded copies](#12-file-layout-and-embedded-copies)

---

## 1. Installation

### Standalone addon install

1. Copy the `LibDataBinding-1.0` folder (the one containing
   `LibDataBinding-1.0.toc`) into:

   ```
   World of Warcraft/_classic_era_/Interface/AddOns/
   ```

   The result must be
   `Interface/AddOns/LibDataBinding-1.0/LibDataBinding-1.0.toc`.

2. **LibStub is required.** Either
   * drop a `LibStub/` folder into `Interface/AddOns/`, or
   * embed LibStub in your own addon **before** this file (see
     [section 12](#12-file-layout-and-embedded-copies)).

   Without LibStub the library stops immediately with a clear error message
   instead of half-loading.

3. Restart the client (or `/reload`) and confirm **LibDataBinding-1.0** is
   listed in the AddOns menu at the character screen.

4. Nothing is loaded into the default UI: the addon creates one hidden driver
   frame and nothing else until you call `NewBinding`.

> **TOC metadata note.** The TOC ships `## X-Dependencies: none` rather than
> `## Dependencies: none`. The client parses `## Dependencies` as a list of
> *addon folder names*, so a literal `none` entry makes the AddOns menu report a
> missing dependency called "none". `X-Dependencies` is an unknown (and
> therefore ignored) metadata key, which documents "no dependencies" without
> asking the client to load anything. Every other requested key
> (`Interface`, `Title`, `Notes`, `Author`, `Version`) is present.

### Embedding in your addon

Copy the whole `LibDataBinding-1.0` folder into `MyAddon/Libs/` and list the
file in your TOC:

```
## Interface: 11507
## Title: MyAddon
## OptionalDeps: LibDataBinding-1.0

Libs\LibStub\LibStub.lua
Libs\LibDataBinding-1.0\LibDataBinding-1.0.lua
MyAddon.lua
```

`LibStub:NewLibrary` returns `nil` for duplicate copies, so several addons can
each embed LibDataBinding without conflict — the first copy loaded wins and all
others become a no-op.

Two practical rules for libraries:

* **List `Libs\LibStub\LibStub.lua` before** `LibDataBinding-1.0.lua`. Each
  embedded copy that is not first is skipped before it touches LibStub, so a
  second copy never needs it.
* **Do not add `## Dependencies: LibDataBinding-1.0`** to a TOC that already
  embeds the file — that would make the client look for a *standalone*
  installation as well, and `OptionalDeps: LibDataBinding-1.0` is enough for
  load ordering when you do want to honour an existing install.
* The standalone addon is safe to leave enabled alongside embedders: the extra
  copy is a no-op and the slash command simply gets registered once.

---

## 2. Quick start

```lua
local LDB = LibStub("LibDataBinding-1.0")

-- 1. A widget of your own (never a Blizzard frame if you plan to /reload in combat)
local f = CreateFrame("Frame", "MyAddonHealth", UIParent)
f:SetSize(160, 14)
f:SetPoint("CENTER")
local bar = CreateFrame("StatusBar", nil, f)
bar:SetAllPoints(f)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
text:SetAllPoints(bar)

-- 2. Bind properties to sources
LDB:NewBinding(bar,  "SetMinMaxValues", "UnitHealthMinMax")
LDB:NewBinding(bar,  "SetValue",        "UnitHealth")
LDB:NewBinding(text, "SetText",         function()
    return UnitHealth("player") .. " / " .. UnitHealthMax("player")
end)

-- 3. Later
-- LDB:UnbindAll(f)        -- remove everything on this frame
```

---

## 3. API reference

All functions are methods on the library object returned by
`LibStub("LibDataBinding-1.0")`. Nothing else is global.

### lib.VERSION

`"1.0.0"` — also available as `lib.MAJOR` (`"LibDataBinding-1.0"`) and
`lib.MINOR` (`1`, the LibStub minor revision).

### `binding = lib:NewBinding(target, property, source, [options])`

Creates a binding. The target property is evaluated **once immediately**, then
whenever one of the source's events fires.

| Argument | Type | Description |
| --- | --- | --- |
| `target` | widget | Any frame, FontString, Texture, StatusBar … |
| `property` | string \| function | See [properties](#properties). |
| `source` | function \| string \| table | See [data sources](#4-data-sources). |
| `options` | table? | See [options](#5-options). |

Returns a **binding object** (see below). Raises a Lua error — caught by the
caller's `pcall`, or shown in chat by the debug command — if the property,
source or target is invalid. Errors thrown *later* by your getter never break
the frame loop: they are caught, counted, reported once, and the binding is
dropped after 50 consecutive failures.

#### Properties

| Property | Calls | Value shape |
| --- | --- | --- |
| `"SetText"` | `w:SetText(v)` | string/number |
| `"SetValue"` | `w:SetValue(v)` | number |
| `"SetMinMaxValues"` | `w:SetMinMaxValues(min, max)` | 2 returns or `{min, max}` |
| `"SetStatusBarColor"` | `w:SetStatusBarColor(r, g, b[, a])` | 3–4 returns or array |
| `"SetVertexColor"` | `w:SetVertexColor(r, g, b[, a])` | 3–4 returns or array |
| `"SetAlpha"` | `w:SetAlpha(v)` | number |
| `"ShowHide"` | `w:Show()` / `w:Hide()` | truthy → show |
| any method name | `w:<name>(...)` | any arity |
| a function | `fn(widget, args, argCount, binding)` | you do the writing |

Values with more than one return (or a table) are splatted as multiple
arguments — that is how `SetMinMaxValues` and colours are fed.

Register additional named properties with
`lib:RegisterProperty(name, applier)` where the applier is
`function(widget, args, argCount, binding)`.

#### Binding object

| Member | Description |
| --- | --- |
| `binding:Update([force])` | Evaluate and write now. `force = true` bypasses the throttle and the change cache. Returns the binding. |
| `binding:Unbind()` | Remove from its chain, release its events, stop updating. Returns `true` the first time, `false` afterwards. |
| `binding:GetValue()` | The argument(s) last written (multiple returns). |
| `binding:GetTarget()` | The widget, or `nil` if it was garbage collected. |
| `binding:IsBound()` | `false` after `Unbind()`. |
| `binding.active` | Same as `IsBound()`. |
| `binding.property` | The property argument you passed. |
| `binding.sourceName` | Registered source name, or `nil` for functions/paths. |

### `lib:RegisterDataSource(name, getter, [events])`

Registers or replaces a named source.

* `getter(binding)` → one or more values. Returning several values is how you
  drive multi-argument properties; the `formatter` then receives an array.
* `events` → `nil`, `"EVENT_NAME"`, `{ event = "EVENT_NAME", unitArg = true,
  unit = "player", filter = fn }`, or an array of those.

```lua
LDB:RegisterDataSource("MyAddon.ComboPoints", function()
    return UnitPower("player", Enum.PowerType.ComboPoints or 3)
end, { { event = "UNIT_POWER", unitArg = true },
       { event = "UNIT_POWER_FREQUENT", unitArg = true } })
```

Event spec fields:

| Field | Meaning |
| --- | --- |
| `event` | Event name (required). |
| `unitArg` | First event argument is a unit token; only bindings whose `unit` matches are woken. Bindings without `unit` default to `"player"`. |
| `unit` | Only wake bindings bound to this exact unit (for events without a unit argument, e.g. `PLAYER_TARGET_CHANGED`). |
| `filter` | `function(binding, event, ...) -> boolean`; `false` skips the wake-up. |

### `lib:UnregisterDataSource(name)` → `boolean`

Forgets the source. Bindings created earlier keep their captured getter and
keep working until unbound.

### `lib:GetDataSource(name)` → `table|nil`

Returns `{ name, getter, events }`.

### `lib:RegisterProperty(name, applier)`

Adds a named property (see [properties](#properties)).

### `lib:GetBindings(target)` → `table`

Array of bindings currently attached to a widget (all properties).

### `lib:UnbindAll([target])` → `number`

Unbinds everything on one widget, or with no argument everything in the
library. Returns how many bindings were removed. Call this in your addon's
`PLAYER_LOGOUT` / `/reload` path or when you destroy a panel.

### `lib:UpdateAll()` → `number`

Queues every active binding and flushes immediately — handy right after an
options change or a `/reload`.

### `lib:Flush()`

Drains the pending queue now instead of waiting for the next frame. Rarely
needed; `UpdateAll` and `binding:Update()` cover most cases.

### `lib:SetDebug(on)` / `lib:IsDebug()`

Toggles chat diagnostics (every write, every new binding, every repeat error).
Default off.

### `lib:GetStats()` → `table`

Live counters: `evaluations`, `writes` (actual widget writes), `skips`
(redundant writes suppressed), `errors`. Read-only; the library owns the table.

### `lib:GetEventBindingCount(event)` → `number`

How many active bindings listen to an event, i.e. whether the library is
registered for it. Useful in tests.

### `lib.Formatters`

`percent(v)` → `"42%"` · `abbreviate(v)` → `"1.2k"`, `"12k"`, `"1.2m"` ·
`money(copper)` → coin string · `seconds(v)` → `"1.5s"` / `"ready"`.

### `lib:RunSelfTest([showUI])` → `passed, failed`

The engine behind `/libdatabinding test` (see [section 7](#7-testing-guide)).
With `showUI` it also creates the demo panel and stores it in `lib.testFrame`;
call `lib:UnbindAll(lib.testFrame)` when you are done with it (clicking the
panel does that for you).

---

## 4. Data sources

### Built in

| Name | Returns | Events |
| --- | --- | --- |
| `UnitHealth` | `UnitHealth(unit)` | `UNIT_HEALTH`, `UNIT_HEALTH_FREQUENT`, unit switches |
| `UnitHealthMax` | `UnitHealthMax(unit)` | `UNIT_MAXHEALTH`, `UNIT_HEALTH`, unit switches |
| `UnitHealthMinMax` | `0, UnitHealthMax(unit)` | `UNIT_MAXHEALTH`, `UNIT_HEALTH`, unit switches |
| `UnitHealthPercent` | `0`–`100` | health events |
| `UnitPower` | `UnitPower(unit, options.args[1])` | `UNIT_POWER`, `UNIT_POWER_UPDATE`, `UNIT_POWER_FREQUENT`, `UNIT_DISPLAYPOWER` |
| `UnitPowerMax` | `UnitPowerMax(unit, options.args[1])` | `UNIT_MAXPOWER`, `UNIT_DISPLAYPOWER` |
| `UnitName` | `UnitName(unit)` | `UNIT_NAME_UPDATE` |
| `GetMoney` | `GetMoney()` | `PLAYER_MONEY`, `PLAYER_ENTERING_WORLD` |
| `GetSpellCooldown` | remaining seconds | `SPELL_UPDATE_COOLDOWN`, `SPELLS_CHANGED` |

`GetSpellCooldown` also listens to `PLAYER_ENTERING_WORLD`. `GetMoney` returns
raw copper — pair it with `lib.Formatters.money`.

Every unit source accepts `options.unit` (default `"player"`) and also listens
to the events that change *which unit a token points at*:
`PLAYER_TARGET_CHANGED` (target), `PLAYER_FOCUS_CHANGED` (focus),
`UPDATE_MOUSEOVER_UNIT` (mouseover), `UNIT_PET` (pet), and
`PLAYER_ENTERING_WORLD` for all of them.

### Four kinds of source

```lua
-- 1. named source
LDB:NewBinding(fs, "SetText", "UnitName", { unit = "target" })

-- 2. plain function
LDB:NewBinding(fs, "SetText", function(binding) return MyAddon:GetTitle() end)

-- 3. table path (re-read on demand; no events)
LDB:NewBinding(fs, "SetText", { MyAddonDB.profile, "stats", "kills" })
LDB:NewBinding(fs, "SetText", { root = MyAddonDB, path = "profile.stats.kills" })

-- 4. inline descriptor with its own events
LDB:NewBinding(fs, "SetText", {
    getter = function() return MyAddon:GetTitle() end,
    events = { "MYADDON_TITLE_CHANGED" },
})
```

A table source may also be an object with a `:get()` method — useful for
`AceConfig`-style value objects or `LibDualSpec` lookups.

Function and path sources have **no events**: they refresh when something calls
`binding:Update()`, `lib:UpdateAll()`, or when you give them `poll`.

---

## 5. Options

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `formatter` | `function(value, binding) -> value, ...` | `nil` | Transform before writing. Multi-value sources pass an array; returning several values feeds several property arguments (e.g. `r, g, b`). Return `nil` to skip the write. |
| `throttle` | number (s) | `nil` | Minimum seconds between evaluations. A request inside the window is **deferred**, not dropped. |
| `condition` | `function(value, binding) -> boolean` | `nil` | Return `false` to skip this write (e.g. "only while the target exists"). |
| `default` | any | `nil` | Value used when the getter returns `nil`. Without it a `nil` result leaves the widget untouched. |
| `poll` | number (s) | `nil` | Re-read on a timer. Use for data that has no event (cooldowns, custom accumulators). |
| `unit` | string | see source | Unit token for unit sources. |
| `args` | table | `nil` | Extra arguments for sources that take parameters (power type, spell ID). |
| `eventFilter` | `function(binding, event, ...) -> boolean` | `nil` | Extra per-binding event filter, applied after the source's own. |

Order of operations:
`getter → default → formatter → condition → change cache → widget`.

---

## 6. Examples

### Example 1 — simple: a health bar on `UnitHealth("player")`

```lua
local LDB = LibStub("LibDataBinding-1.0")

local function CreateHealthBar()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(180, 26)
    f:SetPoint("CENTER", 0, -120)

    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetAllPoints(f)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.1, 0.9, 0.1)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")

    -- Range, then value. Two bindings, two properties, one bar.
    LDB:NewBinding(bar, "SetMinMaxValues", "UnitHealthMinMax")
    LDB:NewBinding(bar, "SetValue", "UnitHealth")

    -- Colour follows the percentage: green -> red.
    LDB:NewBinding(bar, "SetStatusBarColor", "UnitHealthPercent", {
        formatter = function(pct)
            local f2 = pct / 100
            return 1 - f2 * 0.85, 0.15 + f2 * 0.75, 0.15
        end,
    })

    -- Text needs both numbers, so ask for both returns. A bare function source
    -- has no events, so give it an inline descriptor that carries them.
    LDB:NewBinding(label, "SetText", {
        getter = function()
            return UnitHealth("player"), UnitHealthMax("player")
        end,
        events = {
            { event = "UNIT_HEALTH", unitArg = true },
            { event = "UNIT_MAXHEALTH", unitArg = true },
            { event = "PLAYER_ENTERING_WORLD" },
        },
    }, {
        formatter = function(v)
            return string.format("%d / %d", v[1], v[2])
        end,
    })

    return f
end

local barFrame = CreateHealthBar()
-- /reload or logout: let go of everything this frame owns.
local cleanup = CreateFrame("Frame")
cleanup:RegisterEvent("PLAYER_LOGOUT")
cleanup:SetScript("OnEvent", function() LDB:UnbindAll(barFrame) end)
```

What happens: `UNIT_HEALTH` fires → the binding is marked → one frame later the
value is written. Ten `UNIT_HEALTH` events in the same frame produce **one**
write. A `UNIT_HEALTH` for a *different* unit is ignored because the binding is
bound to `player`.

### Example 2 — advanced: custom source, formatter, condition and throttle

A reputation tracker that only shows the bar while a target is selected, never
rewrites identical text, and repaints at most twice per second.

```lua
local LDB = LibStub("LibDataBinding-1.0")
local ADDON = "MyRepTracker"
MyRepTrackerDB = MyRepTrackerDB or { watchedFaction = nil }

-- 1. A custom data source: getter + the events that invalidate it.
--    It always returns two numbers, so every formatter below can rely on the
--    shape and the bar never receives a nil.
LDB:RegisterDataSource(ADDON .. ".Faction", function(binding)
    local name = MyRepTrackerDB.watchedFaction
    if not name then return 0, 0 end
    local current, max = GetWatchedFactionInfo()
    return current or 0, max or 0     -- two returns -> formatter gets { current, max }
end, {
    { event = "UPDATE_FACTION" },
    { event = "PLAYER_ENTERING_WORLD" },
})

-- 2. The widgets.
local panel = CreateFrame("Frame", nil, UIParent)
panel:SetSize(220, 40)
panel:SetPoint("TOP", 0, -200)
local bar = CreateFrame("StatusBar", nil, panel)
bar:SetPoint("TOPLEFT", 0, -14)
bar:SetSize(220, 16)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
text:SetPoint("TOPLEFT", bar, "TOPLEFT", 2, -1)

-- 3. Show the panel only while a faction is being tracked. The source's events
--    drive this, so no OnUpdate and no manual refresh.
LDB:NewBinding(panel, "ShowHide", ADDON .. ".Faction", {
    formatter = function(v) return v[2] > 0 end,
})

-- 4. Bar range and value. Both read the same source, which is registered once
--    and therefore hooked to the client only once.
LDB:NewBinding(bar, "SetMinMaxValues", ADDON .. ".Faction", {
    formatter = function(v) return 0, v[2] > 0 and v[2] or 1 end,
})

LDB:NewBinding(bar, "SetValue", ADDON .. ".Faction", {
    throttle = 0.5,                     -- at most two repaints per second
    condition = function(v) return v[2] > 0 end,
})   -- no formatter: extra returns become extra arguments, and SetValue takes
     -- the first one, so `current` lands in the bar.

-- 5. The label: abbreviate large numbers, and let the change cache skip
--    identical text (LibDataBinding compares arguments before writing).
LDB:NewBinding(text, "SetText", ADDON .. ".Faction", {
    throttle = 0.5,
    formatter = function(v)
        local current, max = v[1], v[2]
        if max == 0 then return "No faction watched" end
        return string.format("%s / %s  (%s)", LDB.Formatters.abbreviate(current),
            LDB.Formatters.abbreviate(max),
            LDB.Formatters.percent(current / max * 100))
    end,
})

-- 6. Force a repaint after the user changes the watched faction.
local function SetWatchedFaction(name)
    MyRepTrackerDB.watchedFaction = name
    LDB:UpdateAll()        -- function sources have no events of their own
end
```

Notes on this example:

* Three bindings read the same source but format differently — that is the point
  of `formatter`. All three share a single event registration.
* Returning a *fixed shape* (`current, max`, never `nil`) keeps every formatter
  simple and lets `condition` decide what to do with "no faction".
* `condition` runs *after* `formatter`, so it sees the transformed value: the
  `SetValue` binding has no formatter and therefore receives the raw
  `{ current, max }` array, while the label receives a string.
* `throttle = 0.5` defers (does not drop) a request that arrives inside the
  window, so the final value always lands.
* `ShowHide` calls `Show()`/`Hide()` on the truthy value of the formatter.
* `UpdateAll()` (step 6) is the escape hatch for sources that cannot raise
  events — such as a plain table path.

---

## 7. Testing guide

### In game — the built-in self test

```
/libdatabinding test      (or /ldb test)
```

This does two things:

1. Runs a validation suite and prints `pass` / `FAIL` for each check:
   creation-time write, manual `Update()`, change caching, `default`,
   `condition`, table paths, multi-return properties, `ShowHide`, throttling
   and forced updates, chain order, event register/unregister, event
   coalescing (5 events → 1 write), unit filtering, and `UnbindAll` cleanup.
2. Creates a small draggable panel in the middle of the screen that binds a
   `StatusBar` to your live health (value, range, colour) and a label to
   `current / max (percent)`.

**Click the panel to close it** — that unbinds its bindings.

| Slash command | Effect |
| --- | --- |
| `/libdatabinding test` | Self test + demo panel |
| `/libdatabinding list` | Every live binding with its property, source and unit |
| `/libdatabinding stats` | Evaluations, writes, skipped writes, errors, live events |
| `/libdatabinding flush` | Drain the queue immediately |
| `/libdatabinding debug` | Toggle per-write chat logging |
| `/libdatabinding reset` | `UnbindAll()` everything (panic button) |

### By hand

1. Log in on a **fresh character in a major city**, run `/libdatabinding test`.
   Expect all green and a bar at your current health.
2. Take fall damage: bar and label move on the *next* frame, not a second later.
3. `/console scriptErrors 1`, then repeat. No Lua errors should appear.
4. Enter combat and `#showtooltip`-style spam abilities: `/libdatabinding stats`
   before and after — `writes` should grow far more slowly than `evaluations`,
   and `skips` should be non-zero (proof the change cache is working).
5. `#reload` mid-fight: no "Interface action failed because of an AddOn" popup
   should appear from this library (see [taint](#taint-model)).

### Headless (CI / offline)

The repository ships a mock-client test suite that loads the real
`LibDataBinding-1.0.lua` unmodified:

```bash
lua tests/run.lua      # 123 checks (121 on Lua 5.2+), exits non-zero on failure
```

It needs nothing but a Lua 5.1-compatible interpreter. The suite is verified on
Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT 2.1 (123 checks; 121 on 5.2+, where the
`setfenv`-based global audit is skipped because `setfenv` no longer exists).
`tests/wow_mock.lua` fakes frames, widgets, events and the clock;
`tests/LibStub.lua` is a minimal stand-in for LibStub; `tests/run.lua` is the
suite, including a strict "no globals leaked" audit.

### Verifying it does not taint

```
/console taintLog 2
/reload
/libdatabinding test
-- take damage, target a mob, open the character sheet, click the panel closed
```

Then inspect `Logs/taint.log`. No entry should reference
`LibDataBinding-1.0.lua`. The library never touches a Blizzard frame, never
sets a protected attribute, and never writes to `_G`.

---

## 8. How it works

```
event ──▶ OnEvent ──▶ Schedule(binding) ──▶ [pending]
                                              │  (one driver frame)
                                              ▼
                                          Flush()  ──▶ ApplyBinding
                                              │            │
                                              │            ├─ throttle check
                                              │            ├─ getter (pcall)
                                              │            ├─ default → formatter → condition
                                              │            ├─ change cache (skip if unchanged)
                                              │            └─ applier → widget:SetXxx(...)
                                              ▼
                                    driver frame hides when the queue is empty
```

* **One driver frame.** Created once, unnamed, empty (no region, no size), set
  to `Show()` only while work is queued. A hidden frame receives no
  `OnUpdate` in WoW, so an idle library costs **zero** per frame.
* **Batching.** `Schedule` stores one entry per binding in a hash table, so any
  number of events in a frame collapses to a single evaluation, and a single
  widget write.
* **Reference-counted events.** `RegisterEvent` is called the first time a
  binding needs an event and `UnregisterEvent` when the last one lets go. The
  library is not subscribed to anything you are not using.
* **Weak references.** The widget is held in a weak-value slot, the chain table
  is weak-keyed, and per-event subscriber lists are weak-keyed too. A panel
  you forget to clean up is collected instead of leaking; the event is dropped
  the first time it fires with no subscribers.
* **Ordering.** Chains replay in creation order (`seq`), so the newest binding
  on a property is the one you see.

---

## 9. Performance

Measured design targets, not marketing:

| Property | Behaviour |
| --- | --- |
| Idle cost | One hidden frame; no `OnUpdate`, no polling, no timers. |
| Event cost | One table lookup + one table insert per interesting binding. |
| Frame cost | One pass over the dirty set, sorted only when more than one item is queued. |
| Redundant writes | Suppressed by an argument-level cache (`stats.skips`). |
| Multi-value properties | Cached per argument, so `SetMinMaxValues(0, 3000)` on every event writes once. |
| Strings | `SetText` with an identical string is skipped entirely. |
| Event fan-out | Unit events compare a single string (`b.unit == arg1`) before doing any work. |
| Errors | A throwing getter is caught; it cannot stall the flush loop or spam chat. |

Practical rules for consumers:

* Prefer named sources over `poll`. `poll` uses the same batched clock, but it
  still wakes the frame every interval.
* Use `throttle` for sources that fire in bursts (`UNIT_POWER_FREQUENT`).
* Use `condition` to skip work while a panel is hidden, instead of unbinding.
* Bind at most one property to one source unless you need different formatting;
  each binding has its own getter call.

---

## 10. Compatibility notes, limitations, and taint

### Client

* Written for **Classic Forever / Interface 11507** (`C_` namespaces only).
  Built-in sources deliberately use the stable, unhinted *global* unit API
  (`UnitHealth`, `UnitPower`, `UnitName`) rather than newer mirrors: that is the
  most portable surface across Classic builds, and it is what the client's own
  unit frames are driven by. The library calls no `C_` namespace itself, so
  future `C_` migrations cannot break it; consumers may call any `C_` API from
  their own getters and those values flow through unchanged.
* No deprecated API: no `this`, no `getglobal`, no `arg1..argN`, no
  `GetSpellInfo` string lookups, no `UIFrameFadeIn`-style legacy helpers.
* Every event is registered through a `pcall`, so an event that a particular
  build does not have degrades to "manual `Update()` only" instead of erroring.
* Built-in sources use only long-stable API (`UnitHealth`, `UnitPower`,
  `UnitName`, `GetMoney`, `GetSpellCooldown`, `GetWatchedFactionInfo` in the
  docs example). Nothing private, nothing hinted.

### Taint model

The library cannot taint the default UI because it never interacts with it:

* no `_G` writes (asserted by the test suite — only the two `SLASH_*` keys the
  client requires for `/libdatabinding`),
* no hooks on Blizzard frames, no `SecureActionButtonTemplate`, no attribute
  writes,
* no changes to `UIParent`, the action bars or the unit frames,
* the driver frame is **unnamed**, so it cannot be found by name, saved in a
  layout, or referenced by Blizzard code,
* your getter runs *inside* the library's `pcall`, in the library's execution
  path. If your getter reads protected state while `InCombatLockdown()` is
  true, that is your addon's taint, not the library's -- read protected data on
  `PLAYER_REGEN_ENABLED` and call `binding:Update()`.

### Known limitations

1. **No automatic change detection for plain tables.** A table-path source has
   no events; call `binding:Update()` or `lib:UpdateAll()` after mutating the
   table. (Proxying `__newindex` on user tables is out of scope and would break
   SavedVariables.)
2. **One write per binding per frame.** A binding can never write twice in a
   frame. If you need an animation curve inside one frame, use `OnUpdate`
   directly.
3. **Non-atomic chains.** Chains give you "last writer wins", not merge
   semantics. Two bindings on `SetText` are independent; the newest one wins.
4. **`throttle` is wall-clock based** (`GetTime`), so it follows client time and
   is not tied to the frame rate.
5. **`formatter` returning a table** is treated as an argument list (`#t`
   decides the arity). Return a scalar for a single argument.
6. **`ShowHide` does not understand `ALWAYS`/`NEVER` alpha fades** — it calls
   `Show()`/`Hide()`.
7. **No secure/protected writes.** The library cannot set action-bar attributes
   or anything else that must happen in a secure context. Bind visual widgets
   only.
8. **`GetSpellCooldown` smoothness needs `poll`.** Event-driven cooldown
   updates fire on start/stop only; set `poll = 0.2` if you want a countdown.
9. **Unit sources default to `player`.** `UNIT_HEALTH` for `target` will not
   wake a binding that never declared `unit = "target"`. That is deliberate —
   it is the main filter against irrelevant work.
10. **Not thread-safe across reload boundaries.** Bindings do not survive
    `/reload`; recreate them when your addon loads (the normal WoW lifecycle).
11. **The driver frame's `OnUpdate` is shared.** If you call `lib:Flush()`
    yourself, you may occasionally do the work a frame earlier than needed —
    harmless, just redundant.
12. **Ace3 is not required and not used.** The `AceAddon`/`AceEvent` ecosystem
    can call into this library, but there is no dependency in either direction.

### Compatibility with other binding libraries

Nothing is monkey-patched, no widget metatables are touched, and the library
does not claim any frame names, so it coexists with `AceGUI`, `LibSharedMedia`,
`LibDDL`, and hand-rolled `OnUpdate` code.

---

## 11. Versioning

Semantic versioning, starting at **1.0.0** (this release):

| Bump | When |
| --- | --- |
| **major** | Removing/renaming a public method, changing the meaning of an existing option, or dropping a client interface. |
| **minor** | New data sources, new properties, new options, new formatters. |
| **patch** | Bug fixes, documentation, internal changes with no API change. |

The minor revision passed to `LibStub:NewLibrary` (`1` in
`local MAJOR, MINOR = "LibDataBinding-1.0", 1`) is bumped when older embedded
copies must be replaced by a newer one. Embedders who never want surprises
should pin to a specific minor.

Suggested roadmap (not implemented yet, to stay within the size budget):
`SetFormattedText` property, batched `LibDataBinding:AddCallback(name, fn)`
subscriptions for non-widget consumers, and an `AceConfig`-style schema helper.

---

## 12. File layout and embedded copies

```
LibDataBinding-1.0/
├── LibDataBinding-1.0.toc   -- Interface 11507, metadata
├── LibDataBinding-1.0.lua   -- engine (~500 lines) + built-in sources,
│                              demo frame, self test and slash command
├── README.md                -- this file
├── CHANGELOG.md
├── LICENSE                  -- MIT
└── tests/                   -- not shipped; mock client + suite
    ├── wow_mock.lua
    ├── LibStub.lua
    └── run.lua
```

* **Engine size** (non-blank, non-comment lines, measured):
  * 517 lines from the top of the file through the binding engine, the
    library-wide helpers and the built-in data sources — that is the core;
  * 586 lines including the `OnEvent`/`OnUpdate` driver and the driver setup;
  * 779 lines in total, the remainder being `lib.Formatters`, the
    `/libdatabinding` command, the demo frame and the self test.
  Everything after the "Built-in data sources" banner can be deleted without
  touching the engine if you want the absolute minimum in your TOC.
* **Embedding:** copy the folder, list `LibDataBinding-1.0.lua` after LibStub
  in your TOC. Duplicate copies no-op through `LibStub:NewLibrary`.
* **Standalone:** the same folder is a valid addon on its own (it needs LibStub
  present).

## Releases

Releases are published at
<https://github.com/SeanShaffer88/LibDataBinding/releases>:

| Release | Tag | Notes |
| --- | --- | --- |
| 1.0.0 | `1.0.0` | First public release. Source tag only; see "Installing from a tag" below. |

The packaging workflow (`.github/workflows/release.yml`) runs the headless suite
and attaches `LibDataBinding-1.0-<version>.zip` to every release created from
tag `1.0.1` onward; the asset unpacks straight into `Interface/AddOns/`.

### Installing from a tag (1.0.0)

GitHub's auto-generated source archive nests the folder one level deep, so
extract and move it rather than dropping the zip in:

1. Download `Source code (zip)` for tag `1.0.0`.
2. Extract it; you get `LibDataBinding-1.0-1.0.0/LibDataBinding-1.0/`.
3. Move **that inner `LibDataBinding-1.0` folder** into `Interface/AddOns/`,
   so the path is `Interface/AddOns/LibDataBinding-1.0/LibDataBinding-1.0.toc`.
4. Discard `tests/` — it is development-only and is not loaded by the TOC.

## License

MIT — see `LICENSE`. Attribute Sean Shaffer.
