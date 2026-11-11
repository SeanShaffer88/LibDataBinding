# Changelog

All notable changes to LibDataBinding-1.0 are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-11-11

First public release. Target client: World of Warcraft Classic Forever,
`## Interface: 11507`.

### Added

* `LibStub("LibDataBinding-1.0")` library object with a documented Lua API and
  LuaDoc comments on every public function and table.
* `lib:NewBinding(target, property, source, options)` where `source` may be a
  function, a registered source name, a table path, or an inline descriptor.
* Built-in properties: `SetText`, `SetValue`, `SetMinMaxValues`,
  `SetStatusBarColor`, `SetVertexColor`, `SetAlpha`, `ShowHide`. Any arbitrary
  widget method name resolves automatically, and a bare function can act as a
  custom applier.
* `lib:RegisterProperty(name, applier)` extension point.
* Built-in data sources: `UnitHealth`, `UnitHealthMax`, `UnitHealthMinMax`,
  `UnitHealthPercent`, `UnitPower`, `UnitPowerMax`, `UnitName`, `GetMoney`,
  `GetSpellCooldown` — all unit sources parameterised by `options.unit`.
* `lib:RegisterDataSource(name, getter, events)` with unit-aware, filtered event
  specs; multiple getter return values are splatted into multi-argument
  properties.
* Options: `formatter`, `throttle`, `condition`, `default`, `poll`, `unit`,
  `args`, `eventFilter`.
* Binding methods: `Update([force])`, `Unbind()`, `GetValue()`, `GetTarget()`,
  `IsBound()`.
* Library helpers: `GetBindings`, `UnbindAll`, `UpdateAll`, `Flush`,
  `GetStats`, `GetEventBindingCount`, `SetDebug`, `IsDebug`.
* `lib.Formatters`: `percent`, `abbreviate`, `money`, `seconds`.
* One-frame batching, an argument-level change cache that suppresses redundant
  widget writes, and a driver frame that hides itself when idle so an idle
  library costs nothing per frame.
* Reference-counted event registration; events are released with the last
  binding that needed them.
* Weak references throughout (widget, chain table, per-event subscriber list) so
  panels that are dropped without cleanup are collected instead of leaking.
* Chain semantics: several bindings may target one widget property; they replay
  in creation order and the newest one wins. Unbinding the winner hands the
  property back to the previous binding immediately.
* Error isolation: getters, formatters and appliers run inside `pcall`; failures
  are counted, reported once, and retried, with the binding dropped after 50
  consecutive failures.
* `/libdatabinding` (`/ldb`) slash command with `test`, `list`, `stats`,
  `flush`, `debug`, `reset`.
* `/libdatabinding test` runs a 20-check validation suite and opens a demo
  panel bound to live player health.
* Headless test suite (`tests/run.lua`, 123 checks) with a mock client,
  including an audit proving the library writes no globals beyond the two
  `SLASH_*` keys.

### Notes

* No dependencies; LibStub is required (embedded or installed).
* No `_G` writes, no Blizzard frame hooks, no protected attributes: the library
  cannot taint the default UI.
* Zero use of deprecated API (`this`, `getglobal`, `arg1..argN`); modern `_G`
  lookups and `C_` namespaces only.

[1.0.0]: https://github.com/SeanShaffer88/LibDataBinding/releases/tag/1.0.0
