"""Runs tests/smoke.lua under LuaJIT through lupa."""
import os, sys
from lupa import luajit21
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
lua = luajit21.LuaRuntime()
with open(os.path.join(root, "tests", "smoke.lua"), encoding="utf-8") as f:
    sys.exit(lua.execute(f.read()) or 0)
