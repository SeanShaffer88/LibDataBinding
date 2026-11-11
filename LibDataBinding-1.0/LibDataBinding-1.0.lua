--[[--------------------------------------------------------------------------
    LibDataBinding-1.0 -- a small reactive data-binding library for World of
    Warcraft Classic (Interface 11507).

    Addon authors bind a widget property (SetText, SetValue, ...) to a data
    source (a function, a table path, or a named source with events).  The
    library re-evaluates the source when its events fire, batches the results
    once per frame, and skips writes that would not change the widget.

    Usage:  local LDB = LibStub("LibDataBinding-1.0")
            LDB:NewBinding(fontString, "SetText", "UnitName", { unit = "target" })

    Licensed under the MIT License.  See LICENSE.
--------------------------------------------------------------------------]]

local MAJOR, MINOR = "LibDataBinding-1.0", 1
local LibStub = _G.LibStub

if not LibStub then
    error(MAJOR .. ": LibStub is missing. Embed LibStub or install it standalone.", 0)
end

-- Returning nil on a duplicate load is what keeps embedded copies cheap.
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

--== Upvalues ===============================================================
-- Everything is resolved once; no hot path touches a global table.
local type, pairs, next, select, pcall, error, tostring, tonumber
    = type, pairs, next, select, pcall, error, tostring, tonumber
local tremove, tsort = table.remove, table.sort
local unpack = unpack or table.unpack
local format, gmatch = string.format, string.gmatch
local CreateFrame, GetTime = CreateFrame, GetTime
local ChatFrame = _G.DEFAULT_CHAT_FRAME or _G.ChatFrame1
local EMPTY = {}

lib.VERSION, lib.MAJOR, lib.MINOR = "1.0.2", MAJOR, MINOR

--== Module state ===========================================================
-- Stored on `lib` so a minor upgrade can reuse the live registry instead of
-- orphaning bindings created by an older copy of the file.
lib.sources    = lib.sources or {}                                 -- [name] = source
lib.chains     = lib.chains or setmetatable({}, { __mode = "k" })  -- [widget][property] = { binding, ... }
lib.eventIndex = lib.eventIndex or {}                              -- [event] = { [binding] = spec }
lib.stats      = lib.stats or { evaluations = 0, writes = 0, skips = 0, errors = 0 }
lib.debug      = lib.debug or false
lib.seq        = lib.seq or 0

local sources, chains, eventIndex, stats = lib.sources, lib.chains, lib.eventIndex, lib.stats

lib.frame = lib.frame or CreateFrame("Frame")
local frame = lib.frame

-- Pending work, collapsed per binding: [binding] = false (ready) or deadline.
local pending = lib.pending or {}
lib.pending = pending
local nextDeadline      -- earliest deadline in `pending`, nil when only "ready" items exist
local ticker            -- true while the driver frame is shown for OnUpdate
local flushing          -- true inside Flush(); guards against re-entrancy
local scratch = {}      -- reused ordering buffer for the flush pass

--== Small helpers ==========================================================
local function pack(...) return { n = select("#", ...), ... } end

--- Prints a library message to the default chat frame.
-- @param msg string Pre-formatted text.
local function Print(msg)
    if ChatFrame then ChatFrame:AddMessage("|cff33ff99LibDataBinding|r " .. tostring(msg)) end
end

--- Debug-only logger; no-op unless ``lib:SetDebug(true)`` was called.
-- The format is applied lazily so an idle debug path costs one boolean test.
-- @param fmt string A ``string.format`` pattern.
-- @param ... any Format arguments.
function lib:Debug(fmt, ...)
    if not self.debug then return end
    if select("#", ...) == 0 then
        Print(tostring(fmt))
    else
        Print(format(tostring(fmt), ...))
    end
end

--- Enables or disables chat diagnostics for the library.
-- @param on boolean Truthy to enable.
function lib:SetDebug(on) self.debug = on and true or false end

--- @return boolean debug True when diagnostics are enabled.
function lib:IsDebug() return self.debug == true end

--- Returns live update counters. The table is owned by the library: read it,
-- do not mutate it. ``evaluations`` counts getter calls, ``writes`` counts
-- actual widget writes, ``skips`` counts redundant writes suppressed by the
-- change cache and ``errors`` counts reported binding failures.
-- @return table stats
function lib:GetStats() return stats end

--== Property appliers ======================================================
-- A property is either a known key below, an arbitrary widget method name, or
-- a custom function supplied by the caller. Every applier takes
-- (widget, args, argCount, binding).
local APPLIERS = {
    SetText           = function(w, a) w:SetText(a[1]) end,
    SetValue          = function(w, a) w:SetValue(a[1]) end,
    SetMinMaxValues   = function(w, a) w:SetMinMaxValues(a[1], a[2]) end,
    SetStatusBarColor = function(w, a) w:SetStatusBarColor(a[1], a[2], a[3], a[4] or 1) end,
    SetVertexColor    = function(w, a) w:SetVertexColor(a[1], a[2], a[3], a[4] or 1) end,
    SetAlpha          = function(w, a) w:SetAlpha(a[1]) end,
    -- Truthy -> Show, falsy -> Hide. A nil value never reaches an applier.
    ShowHide          = function(w, a) if a[1] then w:Show() else w:Hide() end end,
}

--- Registers an extra named property so it can be used like the built-ins.
-- @param name string Property name, e.g. ``"SetRotation"``.
-- @param applier function ``function(widget, args, argCount, binding)``.
function lib:RegisterProperty(name, applier)
    if type(name) ~= "string" or name == "" then
        error("RegisterProperty: name must be a non-empty string", 2)
    end
    if type(applier) ~= "function" then
        error("RegisterProperty: applier must be a function", 2)
    end
    APPLIERS[name] = applier
end

--- Resolves a property argument into an applier plus a stable chain key.
-- @param target table Widget the binding will write to.
-- @param property string|function A known property, a widget method, or a function(widget, args, count, binding).
-- @return function applier
-- @return string|function key
-- @return string label
local function resolveProperty(target, property)
    if type(property) == "function" then
        return function(w, a, n, b) property(w, a, n, b) end, property, "custom"
    end
    if type(property) ~= "string" or property == "" then
        error("NewBinding: property must be a non-empty string or a function", 3)
    end

    local applier = APPLIERS[property]
    if applier then return applier, property, property end

    local method = target[property]
    if type(method) ~= "function" then
        error(format("NewBinding: %q is not a built-in property and target has no such method", property), 3)
    end
    return function(w, a, n) method(w, unpack(a, 1, n)) end, property, property
end

--== Data sources ===========================================================
-- Event spec fields: ``event`` (name), ``unitArg`` ("argument 1 is a unit
-- token"), ``unit`` ("only wake bindings bound to this unit") and ``filter``
-- ("function(binding, event, ...) -> boolean").

--- Coerces one event declaration ("NAME" or a spec table) into a spec table.
-- @param e string|table Event declaration.
-- @return table|nil spec
local function normalizeEvent(e)
    if type(e) == "string" then return { event = e } end
    if type(e) == "table" then
        return { event = e.event or e.name, unitArg = e.unitArg, unit = e.unit, filter = e.filter }
    end
end

--- Normalizes the ``events`` argument of ``RegisterDataSource``.
-- @param events string|table|nil One event name, a single spec, or an array of specs.
-- @return table array of event specs (possibly empty)
local function normalizeEvents(events)
    local out = {}
    if type(events) == "string" then
        out[1] = { event = events }
    elseif type(events) == "table" then
        if events.event or events.name then
            out[1] = normalizeEvent(events)
        else
            for i = 1, #events do
                local spec = normalizeEvent(events[i])
                if spec and spec.event then out[#out + 1] = spec end
            end
        end
    end
    return out
end

--- Registers (or replaces) a named data source.
-- @param name string Unique source name, e.g. ``"UnitHealth"``.
-- @param getter function ``function(binding) -> value, ...``. Extra return values become extra property arguments.
-- @param events string|table|nil Event name(s) that invalidate the binding.
-- @return table source The stored descriptor (name, getter, events).
function lib:RegisterDataSource(name, getter, events)
    if type(name) ~= "string" or name == "" then
        error("RegisterDataSource: name must be a non-empty string", 2)
    end
    if type(getter) ~= "function" then
        error("RegisterDataSource: getter must be a function", 2)
    end
    local source = { name = name, getter = getter, events = normalizeEvents(events) }
    sources[name] = source
    return source
end

--- Removes a named data source. Existing bindings keep working until unbound.
-- @param name string Source name.
-- @return boolean removed
function lib:UnregisterDataSource(name)
    if not sources[name] then return false end
    sources[name] = nil
    return true
end

--- @param name string Source name.
-- @return table|nil source
function lib:GetDataSource(name) return sources[name] end

-- Checks a binding's unit against the unit reported by an event.
local function unitMatches(unit, eventUnit)
    return unit == nil or unit == eventUnit
end

--== Event wiring ===========================================================
-- Event registrations are reference counted: an event is registered on the
-- driver frame only while at least one binding cares about it. The per-event
-- binding list is weak-keyed so a garbage-collected widget cannot pin its
-- bindings (and therefore its event) alive forever.
local function newEventEntry()
    return setmetatable({}, { __mode = "k" })
end

--- Counts the live bindings in one event entry.
-- @param entry table Weak-keyed binding map.
-- @return number count
local function countBindings(entry)
    local n = 0
    for _ in pairs(entry) do n = n + 1 end
    return n
end

--- Adds one event spec to a binding, registering the event if needed.
-- @param b table Binding.
-- @param spec table Normalized event spec.
local function addBindingEvent(b, spec)
    local name = spec.event
    if not name then return end

    local entry = eventIndex[name]
    if not entry then
        -- Some events do not exist on every client build; probe with pcall so
        -- a missing event degrades to "manual Update only" instead of an error.
        local ok = pcall(frame.RegisterEvent, frame, name)
        if not ok then
            lib:Debug("event unavailable on this client: %s", name)
            return
        end
        entry = newEventEntry()
        eventIndex[name] = entry
    end

    if entry[b] then return end                -- one wake-up per event per binding
    entry[b] = spec
    b.eventNames[#b.eventNames + 1] = name
    if spec.unitArg and not b.unit then b.unit = "player" end
end

--- Removes one event spec from a binding and unregisters the event when idle.
-- @param b table Binding.
-- @param name string Event name.
local function removeBindingEvent(b, name)
    local entry = eventIndex[name]
    if not entry or not entry[b] then return end
    entry[b] = nil
    if next(entry) == nil then
        eventIndex[name] = nil
        pcall(frame.UnregisterEvent, frame, name)
    end
end

--- Returns how many active bindings currently listen to an event.
-- @param event string Event name.
-- @return number count Zero means the library is not registered for it.
function lib:GetEventBindingCount(event)
    local entry = eventIndex[event]
    return entry and countBindings(entry) or 0
end

--== Scheduling and the per-frame driver ====================================
-- OnUpdate is used *only* as a coalescing clock: no data is polled from it
-- unless a binding explicitly asked for `poll`. The frame hides itself when
-- the queue is empty, so an idle library costs exactly zero per frame.
local ApplyBinding   -- forward declaration (Schedule -> Flush -> ApplyBinding)

--- Queues a binding for evaluation, optionally after a delay in seconds.
-- @param b table Binding.
-- @param delay number|nil Delay before the evaluation becomes due.
local function Schedule(b, delay)
    if not b.active then return end
    local current = pending[b]

    if delay and delay > 0 then
        if current == false then return end                  -- an immediate pass is already queued
        local due = GetTime() + delay
        if current and current <= due then return end         -- keep the earlier deadline
        pending[b] = due
        if not nextDeadline or due < nextDeadline then nextDeadline = due end
    else
        if current ~= nil then return end                     -- already queued
        pending[b] = false
        nextDeadline = nil                                    -- force the driver to flush next frame
    end

    if not ticker then
        ticker = true
        frame:Show()                                          -- OnUpdate only runs while shown
    end
end

-- Reused buffers: the subscriber list is snapshotted before user filter code
-- runs, because a filter is allowed to unbind bindings (which mutates the list
-- we would otherwise be iterating).
local eventBindings, eventSpecs = {}, {}

-- Delivers an event to every binding that subscribed to it.
local function OnEvent(_, event, ...)
    local entry = eventIndex[event]
    if not entry then return end
    local eventUnit = ...

    local n = 0
    for b, spec in pairs(entry) do
        n = n + 1
        eventBindings[n] = b
        eventSpecs[n] = spec
    end

    -- Self-heal: bindings that were collected with their widget never get to
    -- call Unbind(), so the event is dropped the first time it fires empty.
    if n == 0 then
        if eventIndex[event] == entry then
            eventIndex[event] = nil
            pcall(frame.UnregisterEvent, frame, event)
        end
        return
    end

    for i = 1, n do
        local b, spec = eventBindings[i], eventSpecs[i]
        eventBindings[i], eventSpecs[i] = nil, nil

        local match
        if spec.unitArg then
            match = unitMatches(b.unit, eventUnit)
        elseif spec.unit then
            match = b.unit == spec.unit
        else
            match = true
        end
        if match and spec.filter then match = spec.filter(b, event, ...) ~= false end
        if match and b.filter then match = b.filter(b, event, ...) ~= false end
        if match and b.active then Schedule(b, nil) end
    end
end

--- Reports a binding failure once per binding so a bad getter cannot spam chat.
-- @param b table Binding.
-- @param err any Error value thrown by the getter, formatter or applier.
local function ReportError(b, err)
    stats.errors = stats.errors + 1
    b.errors = (b.errors or 0) + 1
    if b.errors > 50 then
        Print(format("binding %q failed 50 times, unbinding it (last error: %s)",
            tostring(b.label), tostring(err)))
        b:Unbind()
        return
    end
    if b.errors == 1 or lib.debug then
        Print(format("error in %q binding: %s", tostring(b.label), tostring(err)))
    end
end

local function seqLess(a, b) return a.seq < b.seq end

--- Hides the driver frame when there is no work left, which stops OnUpdate
-- from running at all. An idle library costs nothing per frame.
local function Sleep()
    if next(pending) == nil then
        nextDeadline = nil
        ticker = false
        frame:Hide()
    elseif not ticker then
        ticker = true
        frame:Show()
    end
end

--- Processes every due binding: at most one widget write per binding per frame.
-- ``binding:Update()`` writes immediately; ``lib:Flush()`` drains the queue now.
-- Re-entrant calls (a getter or formatter that calls ``UpdateAll``) are ignored:
-- the outer pass picks the queued work up on its next frame.
function lib:Flush()
    if flushing then return end

    local now = GetTime()
    local n = 0

    for b, due in pairs(pending) do
        if due and now < due then
            pending[b] = due                              -- not due yet
        else
            pending[b] = nil
            n = n + 1
            scratch[n] = b
        end
    end

    -- Chains made of several bindings must replay in creation order so the
    -- newest binding wins on the same frame. `scratch` holds exactly `n` items.
    if n > 1 then tsort(scratch, seqLess) end

    flushing = true
    for i = 1, n do
        local b = scratch[i]
        scratch[i] = nil
        if b.active then
            local ok, err = pcall(ApplyBinding, b, false)
            if not ok then ReportError(b, err) end
        end
    end
    flushing = false

    local earliest
    for _, due in pairs(pending) do
        if due and (not earliest or due < earliest) then earliest = due end
    end
    nextDeadline = earliest
    Sleep()
end

--== Binding ================================================================
-- Methods live on `lib.proto` so a minor upgrade of the file also upgrades
-- bindings created by the older copy.
local BindingProto = lib.proto or {}
lib.proto = BindingProto

--- @return table|nil target The widget, or nil if it was garbage collected.
function BindingProto:GetTarget() return self._ref[1] end

--- @return boolean active False once the binding has been unbound.
function BindingProto:IsBound() return self.active == true end

--- @return any value Last value written (multiple returns for multi-argument properties).
function BindingProto:GetValue()
    local cache = self._cache
    if not cache then return nil end
    return unpack(cache, 1, self._argc or 0)
end

--- Forces an immediate evaluation and write.
-- @param force boolean|nil Bypass the throttle and the "value unchanged" cache.
-- @return table binding Self, for chaining.
function BindingProto:Update(force)
    -- `_busy` makes a getter that calls back into its own binding a no-op
    -- instead of an infinite recursion.
    if not self.active or self._busy then return self end
    self._busy = true
    local ok, err = pcall(ApplyBinding, self, force and true or false)
    self._busy = false
    if not ok then ReportError(self, err) end
    return self
end

--- Detaches the binding: removes it from its chain, releases its events and
-- stops all future updates. If it was the binding currently writing to the
-- widget, the previous binding in the chain takes over again immediately.
-- Safe to call more than once.
-- @return boolean unbound True when this call removed the binding.
function BindingProto:Unbind()
    if not self.active then return false end
    self.active = false
    pending[self] = nil

    local target = self._ref[1]
    local byProperty = target and chains[target]
    local chain = byProperty and byProperty[self.key]
    local wasWriter = false

    if chain then
        for i = #chain, 1, -1 do
            if chain[i] == self then
                wasWriter = (i == #chain)
                tremove(chain, i)
            end
        end
        if #chain == 0 then byProperty[self.key] = nil end
    end

    for i = 1, #self.eventNames do removeBindingEvent(self, self.eventNames[i]) end
    self.eventNames = {}

    -- Hand the property back to the previous binding in the chain. This is a
    -- synchronous, forced write: the widget must not keep showing a value that
    -- nobody is maintaining any more.
    if wasWriter and chain and #chain > 0 then
        local previous = chain[#chain]
        if previous.active then
            local ok, err = pcall(ApplyBinding, previous, true)
            if not ok then ReportError(previous, err) end
        end
    end

    Sleep()   -- go dormant right away if nothing else is queued
    return true
end

--== The update path ========================================================

-- Compares the new argument list with the cached one.
local function argsEqual(cache, args, n)
    for i = 1, n do
        if cache[i] ~= args[i] then return false end
    end
    return true
end

--- Evaluates one binding and writes the result to the widget.
-- Pipeline: getter -> default -> formatter -> condition -> cache -> applier.
-- @param b table Binding.
-- @param force boolean|nil Skip the throttle and the change cache.
ApplyBinding = function(b, force)
    local target = b._ref[1]
    if not target then b:Unbind() return end          -- widget was garbage collected

    local now = GetTime()
    if not force and b.throttle and b._lastEval then
        local wait = b._lastEval + b.throttle - now
        if wait > 0 then Schedule(b, wait) return end
    end

    local res = pack(pcall(b.getter, b))
    stats.evaluations = stats.evaluations + 1
    if not res[1] then error(res[2], 0) end
    b._lastEval = now

    local count, value = res.n - 1, res[2]
    if count > 1 then
        value = { unpack(res, 2, res.n) }
    elseif count == 0 then
        value = nil
    end
    if value == nil then value = b.default end
    if value == nil then return end                   -- nothing to write; keep the widget as-is

    if b.formatter then
        -- A formatter may return several values (they become the property's
        -- arguments, e.g. r, g, b) or one value. `nil` suppresses the write.
        local out = pack(b.formatter(value, b))
        if out.n == 0 or out[1] == nil then return end
        value = out.n > 1 and { unpack(out, 1, out.n) } or out[1]
    end
    if b.condition and not b.condition(value, b) then return end

    local argc
    if type(value) == "table" then
        argc = #value
        for i = 1, argc do b._args[i] = value[i] end
    else
        argc = 1
        b._args[1] = value
    end
    for i = argc + 1, b._argc do b._args[i] = nil end

    local cache = b._cache
    if not force and cache and b._argc == argc and argsEqual(cache, b._args, argc) then
        stats.skips = stats.skips + 1                 -- redundant write suppressed
        if b.poll then Schedule(b, b.poll) end
        return
    end

    b.applier(target, b._args, argc, b)
    stats.writes = stats.writes + 1

    cache = cache or {}
    b._cache = cache
    for i = 1, argc do cache[i] = b._args[i] end
    for i = argc + 1, b._argc do cache[i] = nil end
    b._argc = argc

    if b.poll then Schedule(b, b.poll) end
    lib:Debug("write %s = %s (%d arg)", tostring(b.label), tostring(b._args[1]), argc)
end

--== Binding creation =======================================================

--- Splits a dotted path into keys.
-- @param path string e.g. ``"profile.health"``.
-- @return table keys
local function splitPath(path)
    local keys = {}
    for part in gmatch(path, "[^%.]+") do keys[#keys + 1] = part end
    return keys
end

--- Builds a getter that reads a dotted/array path from a root table.
-- Accepted forms: ``{ MyTable, "a", "b" }``, ``{ root = MyTable, path = "a.b" }``
-- or ``{ root = MyTable, path = { "a", "b" } }``.
-- @param source table Path descriptor.
-- @return function getter
local function makePathGetter(source)
    local root = source[1] or source.root
    if type(root) ~= "table" then
        error("NewBinding: a table source needs a root table, e.g. { MyTable, 'key' }", 4)
    end

    local keys
    if source.path then
        keys = type(source.path) == "table" and source.path or splitPath(source.path)
    else
        keys = {}
        for i = 2, #source do keys[#keys + 1] = source[i] end
    end
    if #keys == 0 then
        error("NewBinding: a table source needs at least one key", 3)
    end

    return function()
        local node = root
        for i = 1, #keys do
            if type(node) ~= "table" then return nil end
            node = node[keys[i]]
        end
        return node
    end
end

--- Resolves the ``source`` argument of ``NewBinding``.
-- @param source function|string|table Getter, registered source name, descriptor or path.
-- @return function getter
-- @return table events Normalized event specs (possibly empty).
-- @return string|nil sourceName Registered source name when applicable.
local function resolveSource(source)
    local kind = type(source)

    if kind == "function" then
        return source, EMPTY
    elseif kind == "string" then
        local found = sources[source]
        if not found then
            error(format("NewBinding: unknown data source %q (register it with RegisterDataSource)", source), 3)
        end
        return found.getter, found.events, source
    elseif kind == "table" then
        if type(source.getter) == "function" then
            return source.getter, normalizeEvents(source.events or source.event), source.name
        end
        if type(source.get) == "function" then
            return function() return source:get() end,
                normalizeEvents(source.events or source.event), source.name
        end
        return makePathGetter(source), EMPTY
    end

    error("NewBinding: source must be a function, a source name or a table path", 3)
end

--- Creates a binding between a widget property and a data source.
--
-- ``source`` may be:
--   * a ``function(binding)`` returning one or more values,
--   * the name of a source registered with ``RegisterDataSource``,
--   * a table path such as ``{ MyDB.profile, "health" }``,
--   * a table with ``getter`` (or ``get``) and optional ``events``.
--
-- The binding is evaluated once immediately, then whenever its events fire.
-- Several bindings may share one widget property: they form a chain and are
-- replayed in creation order, so the newest binding wins per frame.
--
-- @param target table The widget to write to.
-- @param property string|function ``SetText``, ``SetValue``, ``SetMinMaxValues``,
--   ``SetStatusBarColor``, ``SetVertexColor``, ``SetAlpha``, ``ShowHide``, any
--   widget method name, or a ``function(widget, args, argCount, binding)``.
-- @param source function|string|table See above.
-- @param options table|nil
--   ``formatter``   function(value, binding) -> value, ... (multiple returns become
--                   multiple property arguments; nil suppresses the write);
--   ``throttle``    minimum seconds between evaluations;
--   ``condition``   function(value, binding) -> boolean, false skips the write;
--   ``default``     value used when the getter returns nil;
--   ``poll``        seconds between timer-driven re-reads (for data without events);
--   ``unit``        unit token for unit sources (defaults to ``"player"``);
--   ``args``        array passed to sources that take parameters (power type, spell ID);
--   ``eventFilter`` function(binding, event, ...) -> boolean, extra event filter.
-- @return table binding The new binding (``:Update()``, ``:Unbind()``, ``:GetValue()``).
function lib:NewBinding(target, property, source, options)
    if type(target) ~= "table" then
        error("NewBinding: target must be a UI object", 2)
    end
    options = options or EMPTY

    local applier, key, label = resolveProperty(target, property)
    local getter, events, sourceName = resolveSource(source)

    lib.seq = lib.seq + 1
    local b = setmetatable({
        -- public, documented fields
        active = true,
        property = property,
        sourceName = sourceName,
        unit = options.unit,
        args = options.args,
        throttle = options.throttle,
        poll = options.poll,
        formatter = options.formatter,
        condition = options.condition,
        default = options.default,
        filter = options.eventFilter,
        seq = lib.seq,
        -- internals
        getter = getter,
        applier = applier,
        key = key,
        label = label,
        eventNames = {},
        _ref = setmetatable({ target }, { __mode = "v" }),
        _args = {},
        _argc = 0,
        _cache = nil,
        _lastEval = nil,
        errors = 0,
    }, { __index = BindingProto })

    -- Chain registration: [widget][property] = { binding, ... }
    local byProperty = chains[target]
    if not byProperty then
        byProperty = {}
        chains[target] = byProperty
    end
    local chain = byProperty[key]
    if not chain then
        chain = {}
        byProperty[key] = chain
    end
    chain[#chain + 1] = b

    for i = 1, #events do addBindingEvent(b, events[i]) end

    -- Apply once now so the widget never shows stale data for a frame.
    local ok, err = pcall(ApplyBinding, b, true)
    if not ok then ReportError(b, err) end

    if self.debug then
        self:Debug("new binding %s <- %s (%d event%s)", tostring(label),
            tostring(sourceName or "function"), #events, #events == 1 and "" or "s")
    end
    return b
end

--== Library-wide helpers ===================================================

-- Calls fn(binding) for one widget's bindings, or for all bindings when the
-- widget is nil. Chains are walked backwards because fn may unbind.
local function forEachBinding(target, fn)
    local groups = target and { chains[target] } or chains
    for _, byProperty in pairs(groups) do
        if type(byProperty) == "table" then
            for _, chain in pairs(byProperty) do
                for i = #chain, 1, -1 do fn(chain[i]) end
            end
        end
    end
end

--- @param target table Widget.
-- @return table Bindings attached to the widget (empty when none).
function lib:GetBindings(target)
    local out = {}
    forEachBinding(target, function(b) out[#out + 1] = b end)
    return out
end

--- Unbinds every binding on a widget, or on every widget when omitted.
-- @param target table|nil Widget to clean up.
-- @return number count Number of bindings removed.
function lib:UnbindAll(target)
    local victims, removed = {}, 0
    forEachBinding(target, function(b) victims[#victims + 1] = b end)
    for i = 1, #victims do
        if victims[i]:Unbind() then removed = removed + 1 end
    end
    return removed
end

--- Queues every active binding for an update and flushes immediately.
-- @return number count Number of bindings refreshed.
function lib:UpdateAll()
    local n = 0
    forEachBinding(nil, function(b)
        if b.active then
            n = n + 1
            Schedule(b, nil)
        end
    end)
    self:Flush()
    return n
end

--== Formatters =============================================================
-- Handy value -> string helpers, usable directly as ``options.formatter``.
lib.Formatters = lib.Formatters or {}

-- Rounds toward zero; avoids "%d" with a float, which errors on Lua 5.3+.
local floor, ceil = math.floor, math.ceil

local function round(n) return n >= 0 and floor(n + 0.5) or ceil(n - 0.5) end

--- Formats a number as a whole percentage: ``42 -> "42%"``.
function lib.Formatters.percent(value)
    return format("%d%%", round(tonumber(value) or 0))
end

--- Formats a number with SI suffixes: ``1234 -> "1.2k"``.
function lib.Formatters.abbreviate(value)
    local n = tonumber(value) or 0
    if n >= 1e9 then return format("%.1fb", n / 1e9) end
    if n >= 1e6 then return format("%.1fm", n / 1e6) end
    if n >= 1e4 then return format("%.0fk", n / 1e3) end
    if n >= 1e3 then return format("%.1fk", n / 1e3) end
    return format("%d", round(n))
end

--- Formats copper as a coin string (uses ``GetCoinTextureString`` when present).
function lib.Formatters.money(copper)
    local amount = tonumber(copper) or 0
    local coin = _G.GetCoinTextureString
    if type(coin) == "function" then return coin(amount) end
    return format("%dg %ds %dc", round(amount / 10000), round((amount / 100) % 100), round(amount % 100))
end

--- Formats seconds as ``"1.5s"`` (``"ready"`` at zero).
function lib.Formatters.seconds(value)
    local s = tonumber(value) or 0
    if s <= 0 then return "ready" end
    return format("%.1fs", s)
end

--== Built-in data sources ==================================================
-- Events that change *which* unit a token points at. They carry no unit
-- argument, so each spec names the binding unit it belongs to. A binding on
-- ``unit = "player"`` ignores them because none of them names "player".
local UNIT_SWITCH_EVENTS = {
    { event = "PLAYER_ENTERING_WORLD" },
    { event = "PLAYER_TARGET_CHANGED", unit = "target" },
    { event = "PLAYER_FOCUS_CHANGED", unit = "focus" },
    { event = "UPDATE_MOUSEOVER_UNIT", unit = "mouseover" },
    { event = "UNIT_PET", unit = "pet" },
}

--- Builds an event list of unit-token events plus the unit-switch events.
-- @param ... string Event names whose first argument is a unit token.
-- @return table events
local function unitEvents(...)
    local out, n = {}, select("#", ...)
    for i = 1, n do out[i] = { event = (select(i, ...)), unitArg = true } end
    for i = 1, #UNIT_SWITCH_EVENTS do out[#out + 1] = UNIT_SWITCH_EVENTS[i] end
    return out
end

local function unitOf(b) return b.unit or "player" end

lib:RegisterDataSource("UnitHealth", function(b) return UnitHealth(unitOf(b)) end,
    unitEvents("UNIT_HEALTH", "UNIT_HEALTH_FREQUENT"))
lib:RegisterDataSource("UnitHealthMax", function(b) return UnitHealthMax(unitOf(b)) end,
    unitEvents("UNIT_MAXHEALTH", "UNIT_HEALTH"))
--- Two return values, ready for ``SetMinMaxValues``.
lib:RegisterDataSource("UnitHealthMinMax", function(b)
    return 0, UnitHealthMax(unitOf(b))
end, unitEvents("UNIT_MAXHEALTH", "UNIT_HEALTH"))
--- Health as a 0-100 number.
lib:RegisterDataSource("UnitHealthPercent", function(b)
    local unit, max = unitOf(b), UnitHealthMax(unitOf(b))
    if max <= 0 then return 0 end
    return UnitHealth(unit) / max * 100
end, unitEvents("UNIT_HEALTH", "UNIT_HEALTH_FREQUENT", "UNIT_MAXHEALTH"))
lib:RegisterDataSource("UnitPower", function(b)
    return UnitPower(unitOf(b), b.args and b.args[1])
end, unitEvents("UNIT_POWER", "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_DISPLAYPOWER"))
lib:RegisterDataSource("UnitPowerMax", function(b)
    return UnitPowerMax(unitOf(b), b.args and b.args[1])
end, unitEvents("UNIT_MAXPOWER", "UNIT_DISPLAYPOWER"))
lib:RegisterDataSource("UnitName", function(b) return UnitName(unitOf(b)) end,
    unitEvents("UNIT_NAME_UPDATE"))
lib:RegisterDataSource("GetMoney", function() return GetMoney() end,
    { "PLAYER_MONEY", "PLAYER_ENTERING_WORLD" })
--- Remaining cooldown in seconds. Set ``options.args = { spellID }`` and, for a
-- smooth countdown, ``options.poll = 0.2``.
lib:RegisterDataSource("GetSpellCooldown", function(b)
    local spellID = b.args and b.args[1]
    if not spellID then return 0 end
    local start, duration = GetSpellCooldown(spellID)
    if not start or start == 0 or not duration or duration == 0 then return 0 end
    local remain = start + duration - GetTime()
    return remain > 0 and remain or 0
end, { "SPELL_UPDATE_COOLDOWN", "SPELLS_CHANGED", "PLAYER_ENTERING_WORLD" })

--== Driver scripts =========================================================
frame:SetScript("OnEvent", OnEvent)
-- The update handler never reads data itself: it only drains the queue when a
-- queued deadline has come due. It stays dormant while the frame is hidden.
frame:SetScript("OnUpdate", function()
    if nextDeadline and GetTime() < nextDeadline then return end
    lib:Flush()
end)

--== Debug: demo frame + self test ==========================================

--- Creates the small diagnostic frame used by ``/libdatabinding test``.
-- It shows live player health through several bindings (value, min/max,
-- colour and text), which doubles as a visual smoke test.
-- @return table frame The created frame.
local function CreateTestFrame()
    local tf = CreateFrame("Frame", nil, _G.UIParent)
    tf:SetSize(240, 74)
    tf:SetPoint("CENTER")
    tf:SetMovable(true)
    tf:EnableMouse(true)
    tf:RegisterForDrag("LeftButton")
    tf:SetScript("OnDragStart", function(self) self:StartMoving() end)
    tf:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local bg = tf:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(tf)
    bg:SetTexture(0, 0, 0, 0.75)
    -- Click to dismiss the panel and release every binding it owns.
    bg:SetScript("OnMouseDown", function()
        lib:UnbindAll(tf)
        tf:Hide()
    end)

    local title = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText("LibDataBinding " .. lib.VERSION .. "  (click to close)")

    local bar = CreateFrame("StatusBar", nil, tf)
    bar:SetSize(216, 16)
    bar:SetPoint("TOPLEFT", 8, -24)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.1, 0.9, 0.1)

    local label = tf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetAllPoints(bar)

    lib:NewBinding(bar, "SetMinMaxValues", "UnitHealthMinMax")
    lib:NewBinding(bar, "SetValue", "UnitHealth")
    lib:NewBinding(bar, "SetStatusBarColor", "UnitHealthPercent", {
        formatter = function(pct)
            local f = pct / 100
            return 1 - f * 0.85, 0.15 + f * 0.75, 0.15
        end,
    })
    -- A multi-value inline source: the formatter receives an array of returns,
    -- and the descriptor carries its own unit-aware events.
    lib:NewBinding(label, "SetText", {
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
            return format("%d / %d  (%s)", v[1], v[2],
                lib.Formatters.percent(v[1] / math.max(1, v[2]) * 100))
        end,
    })
    lib:NewBinding(label, "SetAlpha", "UnitHealth", {
        formatter = function(hp) return hp > 0 and 1 or 0.35 end,
    })

    return tf
end

--- Runs the built-in validation suite: binding, formatting, defaults,
-- conditions, change caching, throttling, table paths, event batching and
-- unbind cleanup. Prints one line per check.
-- @param showUI boolean|nil Also create the visible diagnostic frame.
-- @return number passed
-- @return number failed
function lib:RunSelfTest(showUI)
    local passed, failed = 0, 0
    local function check(label, ok)
        if ok then
            passed = passed + 1
            Print("|cff40ff40pass|r " .. label)
        else
            failed = failed + 1
            Print("|cffff4040FAIL|r " .. label)
        end
    end

    local holder = CreateFrame("Frame", nil, showUI and _G.UIParent or nil)
    if showUI then holder:SetPoint("CENTER") end
    local text = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local bar = CreateFrame("StatusBar", nil, holder)

    local state = { value = 42, nested = { deep = { name = "Azeroth" } }, events = 0 }
    local functionState = function() return state.value end

    -- 1. function source + formatter, written synchronously on creation
    local b1 = lib:NewBinding(text, "SetText", functionState, {
        formatter = function(v) return "v=" .. tostring(v) end,
    })
    check("function source writes on creation", text:GetText() == "v=42")

    -- 2. manual Update picks up a new value
    state.value = 7
    b1:Update()
    check("Update() re-reads the source", text:GetText() == "v=7")

    -- 3. redundant writes are suppressed by the change cache
    local beforeSkips = stats.skips
    b1:Update()
    check("unchanged values are not rewritten", stats.skips == beforeSkips + 1)

    -- 4. default is used when the getter returns nil
    lib:NewBinding(text, "SetText", function() return nil end, { default = "fallback" })
    check("default applies when source returns nil", text:GetText() == "fallback")

    -- 5. condition can skip a write entirely
    lib:NewBinding(text, "SetAlpha", function() return 0.5 end, {
        condition = function() return false end,
    })
    check("condition=false skips the write", math.abs(text:GetAlpha() - 1) < 1e-6)

    -- 6. table path sources resolve nested keys
    lib:NewBinding(text, "SetText", { state, "nested", "deep", "name" })
    check("table path source resolves", text:GetText() == "Azeroth")

    -- 7. multi-return sources feed multi-argument properties
    lib:NewBinding(bar, "SetMinMaxValues", function() return 0, 120 end)
    local min, max = bar:GetMinMaxValues()
    check("multi-return drives SetMinMaxValues", min == 0 and max == 120)

    -- 8. ShowHide binding
    lib:NewBinding(text, "ShowHide", function() return false end)
    check("ShowHide hides on falsy value", not text:IsShown())

    -- 9. throttle blocks a second evaluation inside the window
    local b9 = lib:NewBinding(text, "SetText", functionState, {
        throttle = 3600,
        formatter = tostring,
    })
    state.value = 99
    b9:Update()
    check("throttle suppresses rapid updates", text:GetText() ~= "99")
    b9:Update(true)                                  -- force bypasses the throttle
    check("force update bypasses throttle", text:GetText() == "99")

    -- 10. chain semantics: the newest binding on a property wins
    lib:NewBinding(text, "SetText", function() return "second" end)
    lib:Flush()
    check("newest binding in a chain wins", text:GetText() == "second")

    -- 11. events are registered on demand and released on unbind. Counts are
    -- relative: the calling addon may already hold its own UNIT_HEALTH binding.
    local baseline = lib:GetEventBindingCount("UNIT_HEALTH")
    local b11 = lib:NewBinding(bar, "SetValue", "UnitHealth", { unit = "player" })
    local hookedWhileBound = lib:GetEventBindingCount("UNIT_HEALTH") > baseline
    b11:Unbind()
    check("events register while bound", hookedWhileBound)
    check("events unregister after unbind", lib:GetEventBindingCount("UNIT_HEALTH") == baseline)

    -- 12. unbind detaches from the chain and stops writes
    local countBefore = #lib:GetBindings(text)
    b1:Unbind()
    check("Unbind() removes the binding", not b1.active and #lib:GetBindings(text) == countBefore - 1)
    check("Unbind() is idempotent", b1:Unbind() == false)

    -- 13. batching: N events in one frame produce exactly one write
    lib:RegisterDataSource("__LDBTest.evented", function() return state.events end,
        { "UNIT_HEALTH", { event = "UNIT_HEALTH", unitArg = true } })
    local b13 = lib:NewBinding(bar, "SetValue", "__LDBTest.evented")
    lib:Flush()
    local writesBefore = stats.writes
    state.events = 5
    for _ = 1, 5 do OnEvent(frame, "UNIT_HEALTH", "player") end
    lib:Flush()
    check("five events coalesce into one write", stats.writes == writesBefore + 1)

    -- 14. unit-filtered events do not wake a player binding
    writesBefore = stats.writes
    OnEvent(frame, "UNIT_HEALTH", "target")
    lib:Flush()
    check("events for another unit are ignored", stats.writes == writesBefore)
    lib:UnregisterDataSource("__LDBTest.evented")

    -- 15. cleanup
    lib:UnbindAll(holder)
    check("UnbindAll() clears the widget", #lib:GetBindings(holder) == 0)

    -- 16. with every binding gone, the library must release the events it
    -- registered and put the driver frame back to sleep.
    lib:UnbindAll()
    check("UnbindAll() unregisters events", lib:GetEventBindingCount("UNIT_HEALTH") == 0)
    check("driver frame sleeps when idle", not frame:IsShown())
    holder:Hide()

    if showUI then
        if lib.testFrame then lib:UnbindAll(lib.testFrame) lib.testFrame:Hide() end
        lib.testFrame = CreateTestFrame()
    end

    Print(format("self test: %d passed, %d failed", passed, failed))
    return passed, failed
end

-- Slash command. These are the only globals the file creates; they are the
-- namespaced keys the client itself requires for /commands.
_G.SLASH_LIBDATABINDING1 = "/libdatabinding"
_G.SLASH_LIBDATABINDING2 = "/ldb"
_G.SlashCmdList.LIBDATABINDING = function(input)
    local cmd = (input or ""):match("^%s*(%S*)"):lower()

    if cmd == "" or cmd == "help" then
        Print("commands: |cffffd100test|r (self test + demo frame), "
            .. "|cffffd100list|r, |cffffd100stats|r, |cffffd100flush|r, "
            .. "|cffffd100debug|r (toggle), |cffffd100reset|r")
    elseif cmd == "test" then
        lib:RunSelfTest(true)
    elseif cmd == "list" then
        local total = 0
        for target, byProperty in pairs(chains) do
            for key, chain in pairs(byProperty) do
                for i = 1, #chain do
                    local b = chain[i]
                    total = total + 1
                    Print(format("%s |cff888888<-|r %s%s%s",
                        type(key) == "string" and key or "custom",
                        tostring(b.sourceName or "function"),
                        b.unit and (" [" .. b.unit .. "]") or "",
                        b.poll and " (poll)" or ""))
                end
            end
        end
        Print(format("%d active binding%s", total, total == 1 and "" or "s"))
    elseif cmd == "stats" then
        local events = 0
        for _ in pairs(eventIndex) do events = events + 1 end
        Print(format("evaluations %d | writes %d | skipped %d | errors %d | live events %d",
            stats.evaluations, stats.writes, stats.skips, stats.errors, events))
    elseif cmd == "flush" then
        lib:Flush()
        Print("queue flushed")
    elseif cmd == "reset" then
        local n = lib:UnbindAll()
        if lib.testFrame then lib.testFrame:Hide() end
        Print(format("unbound %d binding%s", n, n == 1 and "" or "s"))
    elseif cmd == "debug" then
        lib:SetDebug(not lib:IsDebug())
        Print("debug " .. (lib:IsDebug() and "on" or "off"))
    else
        Print(format("unknown command %q, try /libdatabinding help", tostring(cmd)))
    end
end
