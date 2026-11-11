--[[ tests/LibStub.lua -- minimal stand-in for the real LibStub (1.0 API), so
    the test suite can load LibDataBinding-1.0.lua unmodified outside the game.
--]]

local MAJOR_VERSION = "LibStub"
local MINOR_VERSION = 1
if not LibStub or LibStub.minor < MINOR_VERSION then
    LibStub = LibStub or {}

    local libs = {}

    function LibStub:NewLibrary(major, minor)
        if type(major) ~= "string" then error("Bad argument #1 to NewLibrary: string expected", 2) end
        if type(minor) ~= "number" then error("Bad argument #2 to NewLibrary: number expected", 2) end
        local lib = libs[major]
        if lib then
            if lib.minor >= minor then return nil end
            lib.minor = minor
            return lib
        end
        lib = { minor = minor }
        libs[major] = lib
        return lib
    end

    function LibStub:GetLibrary(major, silent)
        local lib = libs[major]
        if not lib and not silent then
            error("Cannot find a library instance of \"" .. tostring(major) .. "\".", 2)
        end
        return lib
    end

    function LibStub:IterateLibraries() return pairs(libs) end

    -- The real LibStub is itself callable: LibStub("Foo-1.0") == LibStub:GetLibrary("Foo-1.0").
    setmetatable(LibStub, {
        __call = function(self, major, silent) return self:GetLibrary(major, silent) end,
    })

    LibStub.minor = MINOR_VERSION
    _G.LibStub = LibStub
end
