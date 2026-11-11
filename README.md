# LibDataBinding-1.0

Reactive data binding for **World of Warcraft Classic Forever** (Interface `11507`).

Declare *"this FontString shows the target's name"* once and stop writing event
handlers. LibDataBinding re-reads the source when the relevant events fire,
batches the work into one widget write per frame, and skips writes whose value
did not change.

```lua
local LDB = LibStub("LibDataBinding-1.0")

LDB:NewBinding(MyAddon.healthBar, "SetMinMaxValues", "UnitHealthMinMax")
LDB:NewBinding(MyAddon.healthBar, "SetValue",        "UnitHealth")
LDB:NewBinding(MyAddon.nameText,  "SetText",         "UnitName", { unit = "target" })
```

* No `OnUpdate` polling for event-driven data — an idle library costs nothing.
* No `RegisterEvent`/`UnregisterEvent` bookkeeping — events are ref-counted.
* No globals beyond the two `/libdatabinding` slash keys, no Blizzard frame
  hooks, no protected attributes: it cannot taint the default UI.
* No dependencies; embeds via `LibStub` or runs as a standalone addon.

---

## Install (players)

1. Copy the **`LibDataBinding-1.0`** folder (the one with the `.toc`) into
   `World of Warcraft/_classic_era_/Interface/AddOns/`.
2. Make sure `Interface/AddOns/LibStub/` exists — the library requires it.
3. `/reload`, then run `/libdatabinding test` to see the self test and a demo
   health bar.

## Install (addon authors)

Copy `LibDataBinding-1.0/` into `MyAddon/Libs/` and list the file in your TOC
after LibStub:

```
## Interface: 11507
Libs\LibStub\LibStub.lua
Libs\LibDataBinding-1.0\LibDataBinding-1.0.lua
MyAddon.lua
```

```lua
local LDB = LibStub("LibDataBinding-1.0")
```

## Documentation

| Document | Contents |
| --- | --- |
| [`LibDataBinding-1.0/README.md`](LibDataBinding-1.0/README.md) | Full API reference, built-in sources, options, two complete examples, testing guide, how it works, performance notes, compatibility and known limitations, versioning. |
| [`LibDataBinding-1.0/CHANGELOG.md`](LibDataBinding-1.0/CHANGELOG.md) | Release notes (starts at 1.0.0). |
| [`tests/README.md`](tests/README.md) | Headless test suite (123 checks) that runs the shipping Lua file against a mock client. |

## Repository layout

```
LibDataBinding-1.0/           the addon / embeddable library
├── LibDataBinding-1.0.toc    ## Interface: 11507, no dependencies
├── LibDataBinding-1.0.lua    engine + built-in sources + self test
├── README.md
├── CHANGELOG.md
└── LICENSE                   MIT
tests/                        development only, never loaded in game
├── run.lua  wow_mock.lua  LibStub.lua  luarun.py
└── README.md
```

## Tests

```bash
lua tests/run.lua
```

Runs 120 assertions against the real `LibDataBinding-1.0.lua` on top of a fake
client (frames, widgets, events, a controllable clock), including a strict audit
that the library leaks no globals. Works on Lua 5.1–5.4 and LuaJIT; exits
non-zero on failure.

## Version

**1.0.0** — see [versioning](LibDataBinding-1.0/README.md#11-versioning) for
what bumps which digit.

## License

MIT © Sean Shaffer. See [`LICENSE`](LICENSE).
