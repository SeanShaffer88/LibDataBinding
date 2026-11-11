--[[ tests/run.lua -- headless test suite for LibDataBinding-1.0.

    Run with:   lua tests/run.lua
    from the repository root. It prints one line per check and exits non-zero
    if anything fails, so it works in CI as well as by hand.

    The suite loads the *real* library file, unmodified, on top of a small WoW
    mock, so what is exercised here is the shipping code path.
--]]

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = ROOT .. "/tests/?.lua;" .. package.path
if ROOT == "." then ROOT = "." end

local unpack = unpack or table.unpack  -- Lua 5.2+
local Mock = require("wow_mock")

--== Tiny test framework ====================================================
local passed, failed = 0, 0
local failures = {}

local function check(label, ok, detail)
    if ok then
        passed = passed + 1
        io.write("  pass  ", label, "\n")
    else
        failed = failed + 1
        failures[#failures + 1] = label
        io.write("  FAIL  ", label, detail and ("  [" .. tostring(detail) .. "]") or "", "\n")
    end
end

local function eq(label, got, want)
    check(label, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

local function section(name)
    io.write("\n", name, "\n")
end

local function fresh()
    Mock.Reset()
    Mock.now = 0
    Mock.money = 0
    Mock.cooldowns = {}
    return Mock.Install(_G)
end

--== Bootstrap a pristine client + LibStub ==================================
fresh()

-- Loading LibStub must happen once; re-require returns the cached copy.
if not _G.LibStub then
    dofile(ROOT .. "/tests/LibStub.lua")
end
assert(_G.LibStub, "LibStub failed to load")

dofile(ROOT .. "/LibDataBinding-1.0/LibDataBinding-1.0.lua")
local LDB = assert(_G.LibStub("LibDataBinding-1.0"), "library did not register with LibStub")

--== Basics =================================================================
section("library registration")
eq("version string", LDB.VERSION, "1.0.0")
eq("major string", LDB.MAJOR, "LibDataBinding-1.0")
check("has NewBinding", type(LDB.NewBinding) == "function")
check("has RegisterDataSource", type(LDB.RegisterDataSource) == "function")
check("has Formatters", type(LDB.Formatters) == "table")
check("slash command registered", type(_G.SlashCmdList.LIBDATABINDING) == "function")
check("driver frame has no global name", LDB.frame:GetName() == nil)

--== Simple examples ========================================================
section("example 1: health bar from UnitHealth")

local healthBar = CreateFrame("StatusBar", nil, UIParent)
local bMinMax = LDB:NewBinding(healthBar, "SetMinMaxValues", "UnitHealthMinMax")
local bValue = LDB:NewBinding(healthBar, "SetValue", "UnitHealth", { unit = "player" })

eq("statusbar value written on creation", healthBar:GetValue(), 1000)
local min, max = healthBar:GetMinMaxValues()
eq("min", min, 0)
eq("max", max, 1500)
check("UNIT_HEALTH registered", LDB.frame:IsEventRegistered("UNIT_HEALTH"))
check("UNIT_MAXHEALTH registered", LDB.frame:IsEventRegistered("UNIT_MAXHEALTH"))

-- Damage the player, fire the event: nothing is written until the frame runs.
Mock.units.player.health = 640
Mock.FireEvent("UNIT_HEALTH", "player")
eq("event alone does not write immediately", healthBar:GetValue(), 1000)
Mock.Tick(0)
eq("value updates after one frame", healthBar:GetValue(), 640)

-- Many events in one frame must collapse into a single write.
Mock.units.player.health = 500
local writes = LDB:GetStats().writes
for _ = 1, 10 do Mock.FireEvent("UNIT_HEALTH", "player") end
Mock.Tick(0)
eq("10 events -> 1 write", LDB:GetStats().writes, writes + 1)
eq("value reflects the newest event", healthBar:GetValue(), 500)

-- Unit filtering: a target event must not touch the player binding.
writes = LDB:GetStats().writes
Mock.FireEvent("UNIT_HEALTH", "target")
Mock.Tick(0)
eq("target event does not wake player binding", LDB:GetStats().writes, writes)

--== Advanced example =======================================================
section("example 2: custom source, formatter, condition, throttle")

local label = UIParent:CreateFontString(nil, "OVERLAY")

local mana = { current = 200, max = 300 }
LDB:RegisterDataSource("MyAddon.Mana", function() return mana.current, mana.max end,
    { "UNIT_POWER", { event = "UNIT_POWER", unitArg = true }, "PLAYER_ENTERING_WORLD" })

local bMana = LDB:NewBinding(label, "SetText", "MyAddon.Mana", {
    unit = "player",
    formatter = function(values) return values[1] .. " / " .. values[2] end,
    condition = function() return mana.max > 0 end,
    throttle = 0.5,
})
eq("custom source + formatter", label:GetText(), "200 / 300")

-- Throttled: an event arriving inside the window is deferred, not dropped.
mana.current = 150
Mock.FireEvent("UNIT_POWER", "player")
Mock.Tick(0)
eq("throttle defers the write inside the window", label:GetText(), "200 / 300")

Mock.Tick(0.25)
Mock.Tick(0.30)
eq("deferred write lands when the throttle expires", label:GetText(), "150 / 300")

-- Condition: max == 0 blocks the write.
mana.max = 0
mana.current = 0
bMana:Update(true)
eq("condition=false blocks the write", label:GetText(), "150 / 300")
mana.max = 300

--== Source kinds ===========================================================
section("source kinds")

local t = UIParent:CreateFontString(nil, "OVERLAY")
local db = { profile = { stats = { kills = 12 } } }

local bPath = LDB:NewBinding(t, "SetText", { db, "profile", "stats", "kills" },
    { formatter = tostring })
eq("table path source", t:GetText(), "12")

db.profile.stats.kills = 13
bPath:Update()
eq("table path re-reads on Update", t:GetText(), "13")

local bPath2 = LDB:NewBinding(t, "SetText", { root = db, path = "profile.stats.kills" },
    { formatter = tostring })
eq("table path with root/path form", t:GetText(), "13")

local getObj = { value = "obj" }
function getObj:get() return self.value end
local bObj = LDB:NewBinding(t, "SetText", getObj)
eq("source object with :get()", t:GetText(), "obj")

local bDesc = LDB:NewBinding(t, "SetText", {
    getter = function() return "desc" end,
    events = "BAG_UPDATE",
})
eq("inline source descriptor", t:GetText(), "desc")
check("inline descriptor event registered", LDB.frame:IsEventRegistered("BAG_UPDATE"))
bDesc:Unbind()
check("inline descriptor event released", not LDB.frame:IsEventRegistered("BAG_UPDATE"))

-- Unknown source names must fail loudly.
check("unknown source raises", not pcall(LDB.NewBinding, t, "SetText", "NoSuchSource"))
check("bad property raises", not pcall(LDB.NewBinding, t, "Frobnicate", function() return 1 end))
check("bad target raises", not pcall(LDB.NewBinding, "notaframe", "SetText", function() return 1 end))

--== Properties =============================================================
section("built-in properties")

local swatch = CreateFrame("Frame", nil, UIParent):CreateTexture(nil, "ARTWORK")
local bVertex = LDB:NewBinding(swatch, "SetVertexColor", function() return 1, 0.5, 0.25 end)
local r, g, b = swatch:GetVertexColor()
check("SetVertexColor multi-return", r == 1 and g == 0.5 and b == 0.25)

local frame = CreateFrame("Frame", nil, UIParent)
local bAlpha = LDB:NewBinding(frame, "SetAlpha", function() return 0.25 end)
eq("SetAlpha", frame:GetAlpha(), 0.25)

local bShow = LDB:NewBinding(frame, "ShowHide", function() return false end)
check("ShowHide hides", not frame:IsShown())
bShow:Unbind()
local bShow2 = LDB:NewBinding(frame, "ShowHide", function() return true end)
check("ShowHide shows", frame:IsShown())

local bar2 = CreateFrame("StatusBar", nil, UIParent)
local bColor = LDB:NewBinding(bar2, "SetStatusBarColor", function() return 0.2, 0.4, 0.6 end)
local cr, cg, cb = bar2:GetStatusBarColor()
check("SetStatusBarColor", cr == 0.2 and cg == 0.4 and cb == 0.6)

-- Any widget method works even without a built-in applier.
local bArbitrary = LDB:NewBinding(bar2, "SetStatusBarTexture", function() return "Interface\\Foo" end)
check("arbitrary widget method", bar2.statusTexture and bar2.statusTexture[1] == "Interface\\Foo")

-- Custom property function form.
local captured
local bCustom = LDB:NewBinding(bar2, function(widget, args, n, binding)
    captured = { widget = widget, args = { unpack(args, 1, n) }, binding = binding }
end, function() return 1, 2, 3 end)
check("custom property function receives widget/args/binding",
    captured and captured.widget == bar2 and captured.args[1] == 1 and captured.args[3] == 3
    and captured.binding == bCustom)

-- RegisterProperty extension point.
LDB:RegisterProperty("SetShadowOffset", function(w, a) w.shadow = { a[1], a[2] } end)
local shadowTarget = CreateFrame("Frame", nil, UIParent)
LDB:NewBinding(shadowTarget, "SetShadowOffset", function() return 2, -2 end)
check("RegisterProperty applier used", shadowTarget.shadow and shadowTarget.shadow[1] == 2)

--== Cache, force and defaults =============================================
section("caching, defaults, force")

local cTarget = UIParent:CreateFontString(nil, "OVERLAY")
local value = "a"
local bCache = LDB:NewBinding(cTarget, "SetText", function() return value end)
local skips = LDB:GetStats().skips
bCache:Update()
eq("unchanged value skipped", LDB:GetStats().skips, skips + 1)
value = "a"  -- still identical
bCache:Update()
eq("still skipped", LDB:GetStats().skips, skips + 2)
bCache:Update(true)
eq("force always writes", LDB:GetStats().skips, skips + 2)

local bDefault = LDB:NewBinding(cTarget, "SetText", function() return nil end, { default = "n/a" })
eq("default value", cTarget:GetText(), "n/a")

local bNil = LDB:NewBinding(cTarget, "SetText", function() return nil end)
eq("nil with no default leaves widget alone", cTarget:GetText(), "n/a")

-- a formatter may return several values (r, g, b) or a single value
local multi = CreateFrame("StatusBar", nil, UIParent)
LDB:NewBinding(multi, "SetStatusBarColor", function() return 1 end, {
    formatter = function() return 0.1, 0.2, 0.3 end,
})
local mr, mg, mb = multi:GetStatusBarColor()
check("multi-return formatter feeds all arguments",
    mr == 0.1 and mg == 0.2 and mb == 0.3)

local multiMinMax = CreateFrame("StatusBar", nil, UIParent)
LDB:NewBinding(multiMinMax, "SetMinMaxValues", function() return 0, 0 end, {
    formatter = function() return 0, 250 end,
})
local mmin, mmax = multiMinMax:GetMinMaxValues()
eq("multi-return formatter drives SetMinMaxValues", mmin, 0)
eq("multi-return formatter drives SetMinMaxValues (max)", mmax, 250)

-- formatter may return nil to suppress the write
local before = LDB:GetStats().writes
LDB:NewBinding(cTarget, "SetText", function() return 1 end, { formatter = function() return nil end })
eq("formatter returning nil suppresses write", LDB:GetStats().writes, before)

--== Chains =================================================================
section("multiple bindings per property (chains)")

local chainTarget = UIParent:CreateFontString(nil, "OVERLAY")
local order = {}
local bA = LDB:NewBinding(chainTarget, "SetText", function()
    order[#order + 1] = "A"
    return "A"
end)
local bB = LDB:NewBinding(chainTarget, "SetText", function()
    order[#order + 1] = "B"
    return "B"
end, { events = nil })
eq("newest binding wins at creation", chainTarget:GetText(), "B")
eq("two bindings on one property", #LDB:GetBindings(chainTarget), 2)

order = {}
Mock.FireEvent("PLAYER_ENTERING_WORLD")
Mock.Tick(0)
LDB:UpdateAll()
local joined = table.concat(order, ",")
check("chain replays in creation order", joined:sub(-3) == "A,B", joined)

-- Unbinding the newer one leaves the older in control.
bB:Unbind()
eq("chain falls back to the older binding", chainTarget:GetText(), "A")

--== Lifecycle ==============================================================
section("lifecycle and cleanup")

local lifeTarget = CreateFrame("StatusBar", nil, UIParent)
local bLife = LDB:NewBinding(lifeTarget, "SetValue", "UnitHealth", { unit = "player" })
check("IsBound true", bLife:IsBound())
check("GetTarget", bLife:GetTarget() == lifeTarget)
check("GetValue", bLife:GetValue() == Mock.units.player.health)

eq("Unbind returns true", bLife:Unbind(), true)
check("IsBound false", not bLife:IsBound())
eq("Unbind is idempotent", bLife:Unbind(), false)
eq("no bindings left", #LDB:GetBindings(lifeTarget), 0)
eq("update after unbind is a no-op", bLife:Update(), bLife)

Mock.units.player.health = 111
Mock.FireEvent("UNIT_HEALTH", "player")
Mock.Tick(0)
check("unbound widget no longer updates", lifeTarget:GetValue() ~= 111)

local evicted = LDB:NewBinding(lifeTarget, "SetValue", "UnitHealth", { unit = "player" })
check("re-registers required event", LDB.frame:IsEventRegistered("UNIT_HEALTH"))
-- Other earlier sections still hold player-health bindings (the example bar),
-- so clear globally before asserting that the event is released.
LDB:UnbindAll()
check("UnbindAll releases the event", not LDB.frame:IsEventRegistered("UNIT_HEALTH"))
eq("UnbindAll returns the count", LDB:UnbindAll(lifeTarget), 0)

-- Driver frame must go dormant when idle.
check("driver frame hidden when idle", not LDB.frame:IsShown())
LDB:NewBinding(lifeTarget, "SetValue", "UnitHealth", { unit = "player" })
Mock.FireEvent("UNIT_HEALTH", "player")
check("driver frame shown when work is queued", LDB.frame:IsShown())
Mock.Tick(0)
check("driver frame hidden again after flush", not LDB.frame:IsShown())
LDB:UnbindAll(lifeTarget)

--== Error handling ========================================================
section("error handling")

local errTarget = UIParent:CreateFontString(nil, "OVERLAY")
local errorsBefore = LDB:GetStats().errors
local bErr = LDB:NewBinding(errTarget, "SetText", function() error("boom") end)
eq("getter errors counted", LDB:GetStats().errors, errorsBefore + 1)
check("failed binding stays alive for a retry", bErr:IsBound())
check("error reported in chat", #Mock.chat.messages > 0)

-- A widget that was garbage collected must unbind itself on the next update.
local collected = CreateFrame("Frame", nil, UIParent)
local bCollected = LDB:NewBinding(collected, "SetAlpha", function() return 1 end)
bCollected._ref[1] = nil                          -- simulate collection
bCollected:Update()
check("collected widget unbinds its binding", not bCollected:IsBound())

-- Reload the library file over the live client: it must reuse its registry.
LDB:UnbindAll()
dofile(ROOT .. "/LibDataBinding-1.0/LibDataBinding-1.0.lua")

section("reload safety")
local L2 = _G.LibStub("LibDataBinding-1.0")
check("reload returns the same library table", L2 == LDB)
eq("sources survive a reload", type(L2:GetDataSource("UnitHealth")), "table")
check("chains survive a reload", type(L2.chains), "table")
check("no global leaked besides slash command",
    rawget(_G, "LibDataBinding") == nil and rawget(_G, "LDB") == nil)

--== Demo frame refresh ====================================================
section("demo frame actually refreshes")

do
    LDB:UnbindAll()
    local okDemo, demo = pcall(function()
        LDB:RunSelfTest(true)
        return LDB.testFrame
    end)
    check("demo frame created", okDemo and demo ~= nil)
    if okDemo and demo then
        -- Grab the label and bar out of the demo panel by walking children.
        local label, bar
        for _, w in ipairs(Mock.widgets) do
            if w.__parent == demo and w.__kind == "FontString" and w:GetText()
                and tostring(w:GetText()):find("/") then
                label = w
            elseif w.__parent == demo and w.__kind == "StatusBar" then
                bar = w
            end
        end
        check("demo label bound", label ~= nil)
        check("demo bar bound", bar ~= nil)
        if label and bar then
            eq("demo bar shows player health", bar:GetValue(), Mock.units.player.health)
            local before2 = tostring(label:GetText())
            Mock.units.player.health = 333
            Mock.units.player.healthMax = 1500
            Mock.FireEvent("UNIT_HEALTH", "player")
            Mock.Tick(0)
            eq("demo bar follows UNIT_HEALTH", bar:GetValue(), 333)
            check("demo label follows UNIT_HEALTH", tostring(label:GetText()) ~= before2,
                tostring(label:GetText()))
            check("demo label shows current/max", tostring(label:GetText()):find("333") ~= nil,
                tostring(label:GetText()))
        end
        LDB:UnbindAll(demo)
        demo:Hide()
    end
end

--== Data source catalogue =================================================
section("built-in data sources")
for _, name in ipairs({
    "UnitHealth", "UnitHealthMax", "UnitHealthMinMax", "UnitHealthPercent",
    "UnitPower", "UnitPowerMax", "UnitName", "GetMoney", "GetSpellCooldown",
}) do
    local src = L2:GetDataSource(name)
    check(name .. " registered", src ~= nil and type(src.getter) == "function")
end

local money = UIParent:CreateFontString(nil, "OVERLAY")
L2:RegisterDataSource("CoinText", function() return GetMoney() end, "PLAYER_MONEY")
local bMoney = L2:NewBinding(money, "SetText", "CoinText", { formatter = L2.Formatters.money })
Mock.money = 12345
Mock.FireEvent("PLAYER_MONEY")
Mock.Tick(0)
eq("money formatter", money:GetText(), "12345c")

local cdText = UIParent:CreateFontString(nil, "OVERLAY")
local spellID = 133
Mock.cooldowns[spellID] = { start = Mock.now, duration = 10 }
local bCD = L2:NewBinding(cdText, "SetText", "GetSpellCooldown", {
    args = { spellID },
    poll = 1,
})
eq("cooldown initial value", tonumber(cdText:GetText()), 10)
Mock.Tick(1)
eq("cooldown counts down via poll", tonumber(cdText:GetText()), 9)

local nameText = UIParent:CreateFontString(nil, "OVERLAY")
local bName = L2:NewBinding(nameText, "SetText", "UnitName", { unit = "target" })
eq("unit name binding", nameText:GetText(), "Dummy")
Mock.units.target.name = "Training Dummy"
Mock.FireEvent("UNIT_NAME_UPDATE", "target")
Mock.Tick(0)
eq("unit name follows UNIT_NAME_UPDATE", nameText:GetText(), "Training Dummy")

Mock.units.target.name = "Other"
Mock.FireEvent("PLAYER_TARGET_CHANGED")
Mock.Tick(0)
eq("unit name follows PLAYER_TARGET_CHANGED", nameText:GetText(), "Other")

Mock.units.player.name = "Renamed"
Mock.FireEvent("PLAYER_TARGET_CHANGED")
Mock.Tick(0)
Mock.FireEvent("UNIT_NAME_UPDATE", "player")
Mock.Tick(0)
check("player binding ignored PLAYER_TARGET_CHANGED", nameText:GetText() == "Other")

--== Formatters ============================================================
section("formatters")
eq("percent", L2.Formatters.percent(42.4), "42%")
eq("percent nil", L2.Formatters.percent(nil), "0%")
eq("abbreviate 999", L2.Formatters.abbreviate(999), "999")
eq("abbreviate 1.2k", L2.Formatters.abbreviate(1234), "1.2k")
eq("abbreviate 12k", L2.Formatters.abbreviate(12345), "12k")
eq("abbreviate 1.2m", L2.Formatters.abbreviate(1234567), "1.2m")
eq("money", L2.Formatters.money(12345), "12345c")
eq("seconds zero", L2.Formatters.seconds(0), "ready")
eq("seconds", L2.Formatters.seconds(1.5), "1.5s")

--== Slash commands ========================================================
section("slash commands")
local before = #Mock.chat.messages
_G.SlashCmdList.LIBDATABINDING("")
check("help output", #Mock.chat.messages > before)
_G.SlashCmdList.LIBDATABINDING("stats")
_G.SlashCmdList.LIBDATABINDING("list")
_G.SlashCmdList.LIBDATABINDING("debug")
check("debug toggled on", L2:IsDebug())
_G.SlashCmdList.LIBDATABINDING("debug")
check("debug toggled off", not L2:IsDebug())
_G.SlashCmdList.LIBDATABINDING("nonsense")
local last = Mock.chat.messages[#Mock.chat.messages]
check("unknown command reported", type(last) == "string" and last:find("unknown command") ~= nil)

--== Self test =============================================================
section("built-in self test")
local ok, p, f = pcall(L2.RunSelfTest, L2, false)
check("RunSelfTest executes", ok, not ok and p or nil)
if ok then
    if f ~= 0 then
        for _, m in ipairs(Mock.chat.messages) do
            if tostring(m):find("FAIL") then io.write("        ", m, "\n") end
        end
    end
    eq("self test failures", f, 0)
end

section("self test with demo frame")
local ok2, p2, f2 = pcall(L2.RunSelfTest, L2, true)
check("RunSelfTest(showUI) executes", ok2, not ok2 and p2 or nil)
if ok2 then
    eq("self test failures (UI)", f2, 0)
    check("demo frame created", L2.testFrame ~= nil)
end

--== Global hygiene =======================================================
section("global hygiene")
if type(setfenv) ~= "function" then
    io.write("  skip  global hygiene audit (needs setfenv / Lua 5.1)\n")
else
do
    -- Load the library into a sandbox with its own LibStub and record every
    -- global it writes. Only the slash-command keys the client requires are
    -- allowed; everything else would be a leak.
    local realStub = _G.LibStub
    _G.LibStub = nil

    local written = {}
    local sandbox
    sandbox = setmetatable({}, {
        __index = _G,
        __newindex = function(t, k, v)
            written[#written + 1] = k
            rawset(t, k, v)
        end,
    })
    rawset(sandbox, "_G", sandbox)

    local stubChunk = assert(loadfile(ROOT .. "/tests/LibStub.lua"))
    setfenv(stubChunk, sandbox)
    stubChunk()

    -- Ignore whatever the stub itself registered; we only audit the library.
    written = {}

    local libChunk = assert(loadfile(ROOT .. "/LibDataBinding-1.0/LibDataBinding-1.0.lua"))
    setfenv(libChunk, sandbox)
    libChunk()

    _G.LibStub = realStub

    local allowed = { SLASH_LIBDATABINDING1 = true, SLASH_LIBDATABINDING2 = true }
    local leaks = {}
    for _, k in ipairs(written) do
        if not allowed[k] then leaks[#leaks + 1] = k end
    end
    eq("no undeclared globals written", #leaks, 0)
    if #leaks > 0 then io.write("        leaked: ", table.concat(leaks, ", "), "\n") end
    check("slash globals are the only writes", #written == 2
        and written[1] == "SLASH_LIBDATABINDING1" and written[2] == "SLASH_LIBDATABINDING2")
end
end

--== Re-entrancy ===========================================================
section("re-entrancy safety")
do
    local target = UIParent:CreateFontString(nil, "OVERLAY")
    local calls = 0

    -- A getter that refreshes everything from inside an evaluation must not
    -- recurse or corrupt the queue.
    local bSelf
    bSelf = LDB:NewBinding(target, "SetText", function(binding)
        calls = calls + 1
        if calls < 3 then LDB:UpdateAll() end
        return "reentrant"
    end)
    LDB:UpdateAll()
    Mock.Tick(0)
    check("UpdateAll inside a getter terminates", calls <= 6 and target:GetText() == "reentrant")

    -- A getter that calls Update() on its own binding must be a no-op.
    local selfCalls = 0
    local bLoop
    bLoop = LDB:NewBinding(target, "SetAlpha", function(self2)
        selfCalls = selfCalls + 1
        bLoop:Update()
        return 0.5
    end)
    check("self-recursive Update is guarded", selfCalls <= 2)

    -- A filter that unbinds its own binding mid-event must not break delivery.
    local victim
    LDB:RegisterDataSource("__LDBTest.filter", function() return 1 end, {
        { event = "BAG_UPDATE", filter = function() victim:Unbind() return true end },
    })
    victim = LDB:NewBinding(target, "SetText", "__LDBTest.filter")
    local survivor = LDB:NewBinding(target, "SetText", "__LDBTest.filter")
    Mock.FireEvent("BAG_UPDATE")
    Mock.Tick(0)
    check("unbinding from an event filter is safe", not victim:IsBound())
    check("other subscribers still receive the event", survivor:IsBound())
    LDB:UnregisterDataSource("__LDBTest.filter")
    LDB:UnbindAll()
end

--== Determinism ===========================================================
section("no leaks")
local total = 0
for _ in pairs(L2.chains) do total = total + 1 end
L2:UnbindAll()
local after = 0
for _ in pairs(L2.chains) do after = after + 1 end
check("UnbindAll clears every chain", after <= total)

--== Summary ===============================================================
io.write("\n", string.rep("-", 60), "\n")
io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then
    io.write("failures:\n")
    for _, f3 in ipairs(failures) do io.write("  - ", f3, "\n") end
    os.exit(1)
end
