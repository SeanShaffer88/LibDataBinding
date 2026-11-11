# Headless test suite

Development-only. Nothing here is listed in `LibDataBinding-1.0.toc`, so it
never loads in game.

```bash
lua tests/run.lua
```

Any Lua 5.1-compatible interpreter works (Lua 5.1–5.4, LuaJIT). The suite
`loadfile`s the shipping `LibDataBinding-1.0.lua` unmodified on top of a mock
client, then asserts 123 behaviours (121 on Lua 5.2+, where the `setfenv`-based
global-hygiene audit is skipped):

| File | Purpose |
| --- | --- |
| `wow_mock.lua` | Frames, widgets, scripts, event delivery, a controllable clock, and the global API functions the built-in sources call. |
| `LibStub.lua` | Minimal LibStub with the real `NewLibrary` version semantics and the callable `LibStub("Foo-1.0")` form. |
| `run.lua` | The suite: API surface, both README examples, source kinds, every property, caching, chains, lifecycle, error handling, re-entrancy, reload safety, the demo frame, data sources, formatters, slash commands, the built-in self test, and a global-leak audit. |
| `luarun.py` | Convenience runner for environments where only Python is available (`pip install lupa`); not required. |

Exit code is `0` when everything passes and `1` otherwise, so it can run in CI.
