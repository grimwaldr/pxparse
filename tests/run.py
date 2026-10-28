"""Runs tests/run.lua under LuaJIT (the same Lua Ashita uses), through lupa: pip install lupa."""
import os
import sys

from lupa import luajit21

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(root)
lua = luajit21.LuaRuntime()
print(lua.eval("jit and jit.version or _VERSION"))
with open(os.path.join(root, "tests", "run.lua"), encoding="utf-8") as f:
    failed = lua.execute(f.read())
sys.exit(1 if failed else 0)
