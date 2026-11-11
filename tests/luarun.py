import sys, lupa.lua51 as lua51
rt = lua51.LuaRuntime(unpack_returned_tuples=True)
path = sys.argv[1] if len(sys.argv) > 1 else 'tests/run.lua'
rt.execute('arg = { [0] = "%s" }' % path)
try:
    rt.execute(open(path).read())
except Exception as e:
    print('LUA ERROR:', e)
    sys.exit(1)
