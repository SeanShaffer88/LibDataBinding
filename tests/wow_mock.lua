--[[ tests/wow_mock.lua

    A deliberately small stand-in for the parts of the WoW Classic client that
    LibDataBinding-1.0 touches: frames, widgets, events, a controllable clock
    and the handful of global API functions used by the built-in sources.

    It is NOT a full emulator -- just enough to run the library headlessly and
    catch logic errors before loading the addon in game.
--]]

local M = {}

-- Lua 5.2+ moved unpack into table.unpack.
local unpack = unpack or table.unpack

-- Every widget ever created, in creation order (used to tick OnUpdate and to
-- deliver events).
M.widgets = {}

--== Clock ==================================================================
M.now = 0
function M.Advance(seconds) M.now = M.now + (seconds or 0) end

--== Widget objects =========================================================
local Widget = {}
Widget.__index = Widget

local function newWidget(kind, name, parent)
    local w = setmetatable({
        __kind = kind,
        __name = name,
        __parent = parent,
        __shown = true,
        __events = {},
        __scripts = {},
        __points = {},
        text = nil,
        alpha = 1,
        value = 0,
        min = 0,
        max = 0,
        barColor = { 1, 1, 1, 1 },
        vertexColor = { 1, 1, 1, 1 },
    }, Widget)
    M.widgets[#M.widgets + 1] = w
    return w
end

function Widget:GetName() return self.__name end
function Widget:GetObjectType() return self.__kind end
function Widget:SetSize(w, h) self.__w, self.__h = w, h end
function Widget:GetSize() return self.__w, self.__h end
function Widget:SetPoint(...) self.__points[#self.__points + 1] = { ... } end
function Widget:SetAllPoints() return true end
function Widget:ClearAllPoints() self.__points = {} end
function Widget:SetMovable(v) self.__movable = v end
function Widget:EnableMouse(v) self.__mouse = v end
function Widget:RegisterForDrag(...) self.__drag = { ... } end
function Widget:StartMoving() self.__moving = true end
function Widget:StopMovingOrSizing() self.__moving = false end
function Widget:SetFrameStrata(s) self.__strata = s end
function Widget:SetParent(p) self.__parent = p end
function Widget:GetParent() return self.__parent end

function Widget:SetScript(name, fn) self.__scripts[name] = fn end
function Widget:GetScript(name) return self.__scripts[name] end
function Widget:HookScript(name, fn)
    local old = self.__scripts[name]
    self.__scripts[name] = function(...)
        if old then old(...) end
        return fn(...)
    end
end

function Widget:Show() self.__shown = true end
function Widget:Hide() self.__shown = false end
function Widget:IsShown() return self.__shown == true end
function Widget:IsVisible() return self.__shown == true end

function Widget:CreateTexture(name) return newWidget("Texture", name, self) end
function Widget:CreateFontString(name, layer, template)
    return newWidget("FontString", name, self)
end

-- FontString / Texture surface
function Widget:SetText(text) self.text = text end
function Widget:GetText() return self.text end
function Widget:SetAlpha(a) self.alpha = a end
function Widget:GetAlpha() return self.alpha end
function Widget:SetFont(...) self.font = { ... } end
function Widget:SetTexture(...) self.texture = { ... } end
function Widget:SetVertexColor(r, g, b, a) self.vertexColor = { r, g, b, a or 1 } end
function Widget:GetVertexColor() return unpack(self.vertexColor) end
function Widget:SetJustifyH() end
function Widget:SetShadowColor() end
function Widget:SetDrawLayer() end

-- StatusBar surface
function Widget:SetStatusBarTexture(...) self.statusTexture = { ... } end
function Widget:SetStatusBarColor(r, g, b, a) self.barColor = { r, g, b, a or 1 } end
function Widget:GetStatusBarColor() return unpack(self.barColor) end
function Widget:SetValue(v) self.value = v end
function Widget:GetValue() return self.value end
function Widget:SetMinMaxValues(min, max) self.min, self.max = min, max end
function Widget:GetMinMaxValues() return self.min, self.max end

-- Events
function Widget:RegisterEvent(event)
    if type(event) ~= "string" or event == "" then
        error("RegisterEvent: invalid event name", 2)
    end
    if not M.knownEvents[event] then
        error("Attempt to register unknown event " .. tostring(event), 2)
    end
    self.__events[event] = true
end
function Widget:UnregisterEvent(event) self.__events[event] = nil end
function Widget:UnregisterAllEvents() self.__events = {} end
function Widget:IsEventRegistered(event) return self.__events[event] == true end
function Widget:GetRegisteredEvents()
    local out = {}
    for e in pairs(self.__events) do out[#out + 1] = e end
    return out
end

--== Events the mock client knows about =====================================
-- Registering anything else raises, which is how we exercise the library's
-- pcall-guarded registration path.
M.knownEvents = {}
for _, e in ipairs({
    "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "PLAYER_TARGET_CHANGED",
    "PLAYER_FOCUS_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_PET",
    "UNIT_HEALTH", "UNIT_HEALTH_FREQUENT", "UNIT_MAXHEALTH",
    "UNIT_POWER", "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT",
    "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER", "UNIT_NAME_UPDATE",
    "SPELL_UPDATE_COOLDOWN", "SPELLS_CHANGED", "BAG_UPDATE",
    "PLAYER_LOGOUT", "UPDATE_FACTION", "UNIT_DISPLAYPOWER",
}) do M.knownEvents[e] = true end

M.log = {}
M.units = {}
M.cooldowns = {}
M.money = 0

--- Builds the fake client globals on `env`.
function M.Install(env)
    env = env or _G
    M.env = env

    env.GetTime = function() return M.now end
    env.UIParent = newWidget("Frame", "UIParent")

    local chat = newWidget("Frame", "ChatFrame1")
    chat.messages = {}
    function chat:AddMessage(msg) self.messages[#self.messages + 1] = msg end
    env.DEFAULT_CHAT_FRAME = chat
    M.chat = chat

    env.SlashCmdList = {}

    function env.CreateFrame(ctype, name, parent)
        return newWidget(ctype or "Frame", name, parent)
    end

    M.units = {
        player = { health = 1000, healthMax = 1500, power = 200, powerMax = 300, name = "Tester" },
        target = { health = 500, healthMax = 800, power = 0, powerMax = 100, name = "Dummy" },
    }
    local function unit(token) return M.units[token] end

    env.UnitHealth = function(token)
        local u = unit(token)
        return u and u.health or 0
    end
    env.UnitHealthMax = function(token)
        local u = unit(token)
        return u and u.healthMax or 0
    end
    env.UnitPower = function(token)
        local u = unit(token)
        return u and u.power or 0
    end
    env.UnitPowerMax = function(token)
        local u = unit(token)
        return u and u.powerMax or 0
    end
    env.UnitName = function(token)
        local u = unit(token)
        return u and u.name or nil
    end
    env.GetMoney = function() return M.money end
    env.GetSpellCooldown = function(id)
        local cd = M.cooldowns[id]
        if not cd then return 0, 0 end
        return cd.start, cd.duration
    end
    env.GetCoinTextureString = function(copper) return copper .. "c" end

    return env
end

--- Fires an event the way the client would: every frame registered for it
--- receives OnEvent(event, ...).
function M.FireEvent(event, ...)
    local delivered = 0
    M.log[#M.log + 1] = { event = event, args = { ... } }
    -- Copy first: handlers may unregister events while we iterate.
    local targets = {}
    for i = 1, #M.widgets do
        local w = M.widgets[i]
        if w.__events[event] then targets[#targets + 1] = w end
    end
    for i = 1, #targets do
        local w = targets[i]
        local handler = w.__scripts.OnEvent
        if handler then
            delivered = delivered + 1
            handler(w, event, ...)
        end
    end
    return delivered
end

--- Resets the widget registry (used between test phases).
function M.Reset()
    M.widgets = {}
    M.log = {}
end

--- Runs OnUpdate on every shown frame, as a render frame would.
function M.Tick(dt)
    M.Advance(dt or 0)
    for i = 1, #M.widgets do
        local w = M.widgets[i]
        local update = w.__scripts.OnUpdate
        if update and w.__shown then update(w, dt or 0) end
    end
end

return M
