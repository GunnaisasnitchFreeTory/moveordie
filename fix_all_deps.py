#!/usr/bin/env python3
"""
fix_all_deps.py
Fix ClientDepsProvider access pattern across all panel scripts + SpinWheelScript + UIController.

Problem: Scripts use Shared.ClientDepsProvider (direct dot access) which crashes
         if the module hasn't replicated yet in multiplayer tests.
Fix:     Use Shared:WaitForChild("ClientDepsProvider", 10) with graceful fallbacks.
"""
import os
import json

BASE_DIR = r"C:\Cursor\moveordie"

# ─── SpinWheelScript: read from agent-tools JSON ────────────────────
SPINWHEEL_JSON = r"C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\bde733fd-5f7d-4e55-8525-9901c89ecd5a.txt"

# ─── Panel scripts (ModuleScripts) ──────────────────────────────────
PANEL_SCRIPTS = [
    "ShopPanel",
    "FateCrownsPanel",
    "CrateShopPanel",
    "IconImagesPanel",
    "IndexPanel",
    "PetsPanel",
]

# ─── Replacement patterns ───────────────────────────────────────────

# OLD: common to all 7 scripts (6 panels + SpinWheelScript)
OLD_CDP_PATTERN = 'local Shared = ReplicatedStorage:WaitForChild("Shared", 5)\nlocal Deps = require(Shared.ClientDepsProvider)'

# Also handle unbounded Shared wait (UIController uses this)
OLD_SHARED_UNBOUNDED = 'local Shared = ReplicatedStorage:WaitForChild("Shared")\n'
NEW_SHARED_BOUNDED   = 'local Shared = ReplicatedStorage:WaitForChild("Shared", 10)\n'

STUB_TABLE = '{ Init = function() end, Show = function() end, Hide = function() end,\n\t\tIsVisible = function() return false end, Toggle = function() end }'

def make_module_replacement(name):
    return f'''local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
\twarn("[{name}] ReplicatedStorage.Shared not found — panel disabled")
\treturn {STUB_TABLE}
end
local CDPModule = Shared:WaitForChild("ClientDepsProvider", 10)
if not CDPModule then
\twarn("[{name}] ClientDepsProvider not found — panel disabled")
\treturn {STUB_TABLE}
end
local Deps = require(CDPModule)'''

def make_local_replacement(name):
    return f'''local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
if not Shared then
\twarn("[{name}] ReplicatedStorage.Shared not found — disabled")
\treturn
end
local CDPModule = Shared:WaitForChild("ClientDepsProvider", 10)
if not CDPModule then
\twarn("[{name}] ClientDepsProvider not found — disabled")
\treturn
end
local Deps = require(CDPModule)'''


# ─── UIController replacement patterns ──────────────────────────────

OLD_UI_REQUIRES = '''local SoundUtil         = require(UI:WaitForChild("SoundUtil"))
local Components        = require(UI:WaitForChild("Components"))
local HUDPanel          = require(UI:WaitForChild("HUDPanel"))
local ShopPanel         = require(UI:WaitForChild("ShopPanel"))
local FateCrownsPanel   = require(UI:WaitForChild("FateCrownsPanel"))
local PetsPanel         = require(UI:WaitForChild("PetsPanel"))
local CrateShopPanel    = require(UI:WaitForChild("CrateShopPanel"))
local IndexPanel        = require(UI:WaitForChild("IndexPanel"))
local SpectatePanel     = require(UI:WaitForChild("SpectatePanel"))
local SettingsPanel     = require(UI:WaitForChild("SettingsPanel"))
local IconImagesPanel   = require(UI:WaitForChild("IconImagesPanel"))
local SpinWheelPanel    = require(UI:WaitForChild("SpinWheelPanel"))
local KillFeed          = require(UI:WaitForChild("KillFeed"))'''

NEW_UI_REQUIRES = '''local SoundUtil         = require(UI:WaitForChild("SoundUtil"))
local Components        = require(UI:WaitForChild("Components"))
local HUDPanel          = require(UI:WaitForChild("HUDPanel"))

-- Helper: safely require a panel module; returns stub if module fails to load
local PANEL_STUB = {
\tInit = function() end, Show = function() end, Hide = function() end,
\tIsVisible = function() return false end, Toggle = function() end,
}
local function safeRequire(name)
\tlocal ok, mod = pcall(function()
\t\treturn require(UI:WaitForChild(name, 10))
\tend)
\tif ok and mod then return mod end
\twarn("[UIController] Failed to load " .. name .. ": " .. tostring(mod) .. " — using stub")
\treturn PANEL_STUB
end

local ShopPanel         = safeRequire("ShopPanel")
local FateCrownsPanel   = safeRequire("FateCrownsPanel")
local PetsPanel         = safeRequire("PetsPanel")
local CrateShopPanel    = safeRequire("CrateShopPanel")
local IndexPanel        = safeRequire("IndexPanel")
local SpectatePanel     = safeRequire("SpectatePanel")
local SettingsPanel     = safeRequire("SettingsPanel")
local IconImagesPanel   = safeRequire("IconImagesPanel")
local SpinWheelPanel    = safeRequire("SpinWheelPanel")
local KillFeed          = safeRequire("KillFeed")'''

OLD_UI_INITS = '''\t-- 4. Init all panels
\tShopPanel.Init(panelGui, onPanelClosed)
\tFateCrownsPanel.Init(panelGui, onPanelClosed)
\tPetsPanel.Init(panelGui, onPanelClosed)
\tCrateShopPanel.Init(panelGui, onPanelClosed)
\tIndexPanel.Init(panelGui, onPanelClosed)
\tSpectatePanel.Init(panelGui, onPanelClosed)
\tSettingsPanel.Init(panelGui, onPanelClosed)
\tIconImagesPanel.Init(panelGui, onPanelClosed)
\tSpinWheelPanel.Init(panelGui, onPanelClosed)

\t-- 4b. Init Kill Feed (always visible on HUD layer)
\tKillFeed.Init(hudGui)'''

NEW_UI_INITS = '''\t-- 4. Init all panels (wrapped in pcall — one failure doesn't kill all UI)
\tlocal function safeInit(name, fn, ...)
\t\tlocal args = {...}
\t\tlocal ok, err = pcall(function()
\t\t\tfn(table.unpack(args))
\t\tend)
\t\tif not ok then
\t\t\twarn("[UIController] " .. name .. " Init FAILED: " .. tostring(err))
\t\tend
\tend

\tsafeInit("ShopPanel", ShopPanel.Init, panelGui, onPanelClosed)
\tsafeInit("FateCrownsPanel", FateCrownsPanel.Init, panelGui, onPanelClosed)
\tsafeInit("PetsPanel", PetsPanel.Init, panelGui, onPanelClosed)
\tsafeInit("CrateShopPanel", CrateShopPanel.Init, panelGui, onPanelClosed)
\tsafeInit("IndexPanel", IndexPanel.Init, panelGui, onPanelClosed)
\tsafeInit("SpectatePanel", SpectatePanel.Init, panelGui, onPanelClosed)
\tsafeInit("SettingsPanel", SettingsPanel.Init, panelGui, onPanelClosed)
\tsafeInit("IconImagesPanel", IconImagesPanel.Init, panelGui, onPanelClosed)
\tsafeInit("SpinWheelPanel", SpinWheelPanel.Init, panelGui, onPanelClosed)

\t-- 4b. Init Kill Feed (always visible on HUD layer)
\tsafeInit("KillFeed", KillFeed.Init, hudGui)'''


def read_source(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        return f.read()

def write_source(filepath, source):
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(source)
    print(f"  Saved: {filepath} ({len(source)} chars, {source.count(chr(10))+1} lines)")

def main():
    print("=" * 60)
    print("fix_all_deps.py: Fixing ClientDepsProvider access patterns")
    print("=" * 60)

    results = {}

    # ─── Fix 6 panel scripts ────────────────────────────────────
    print("\n--- Panel Scripts (ModuleScript) ---")
    for name in PANEL_SCRIPTS:
        filepath = os.path.join(BASE_DIR, f"temp_{name}.lua")
        if not os.path.exists(filepath):
            print(f"  SKIP {name}: {filepath} not found")
            continue

        source = read_source(filepath)
        if OLD_CDP_PATTERN not in source:
            print(f"  WARNING: Pattern not found in {name}!")
            # Try to find what's there instead
            if 'require(Shared.ClientDepsProvider)' in source:
                print(f"  -> Found 'require(Shared.ClientDepsProvider)' — pattern mismatch in surrounding context")
            continue

        new_pattern = make_module_replacement(name)
        fixed = source.replace(OLD_CDP_PATTERN, new_pattern, 1)
        out_path = os.path.join(BASE_DIR, f"fixed_{name}.lua")
        write_source(out_path, fixed)
        results[name] = True

    # ─── Fix SpinWheelScript ────────────────────────────────────
    print("\n--- SpinWheelScript (LocalScript) ---")
    if os.path.exists(SPINWHEEL_JSON):
        with open(SPINWHEEL_JSON, 'r', encoding='utf-8') as f:
            data = json.load(f)
        source = data.get("source", "")
        if OLD_CDP_PATTERN in source:
            new_pattern = make_local_replacement("SpinWheelScript")
            fixed = source.replace(OLD_CDP_PATTERN, new_pattern, 1)
            out_path = os.path.join(BASE_DIR, "fixed_SpinWheelScript.lua")
            write_source(out_path, fixed)
            results["SpinWheelScript"] = True
        else:
            print("  WARNING: CDP pattern not found in SpinWheelScript!")
            if 'require(Shared.ClientDepsProvider)' in source:
                print("  -> Found direct access but surrounding context differs")
    else:
        print(f"  SKIP: JSON file not found: {SPINWHEEL_JSON}")

    # ─── Fix UIController ───────────────────────────────────────
    print("\n--- UIController ---")
    ui_path = os.path.join(BASE_DIR, "temp_UIController.lua")
    if os.path.exists(ui_path):
        source = read_source(ui_path)
        changes = 0

        # 1. Fix unbounded Shared wait
        if OLD_SHARED_UNBOUNDED in source:
            source = source.replace(OLD_SHARED_UNBOUNDED, NEW_SHARED_BOUNDED, 1)
            changes += 1
            print("  [1/3] Fixed unbounded Shared WaitForChild -> 10s timeout")

        # 2. Fix require block (add safeRequire)
        if OLD_UI_REQUIRES in source:
            source = source.replace(OLD_UI_REQUIRES, NEW_UI_REQUIRES, 1)
            changes += 1
            print("  [2/3] Fixed panel requires -> safeRequire with pcall + stub")
        else:
            print("  WARNING: Require block pattern not found!")

        # 3. Fix Init block (add safeInit)
        if OLD_UI_INITS in source:
            source = source.replace(OLD_UI_INITS, NEW_UI_INITS, 1)
            changes += 1
            print("  [3/3] Fixed panel Init calls -> safeInit with pcall")
        else:
            print("  WARNING: Init block pattern not found!")

        if changes > 0:
            out_path = os.path.join(BASE_DIR, "fixed_UIController.lua")
            write_source(out_path, source)
            results["UIController"] = True
        else:
            print("  No changes made to UIController!")
    else:
        print(f"  SKIP: {ui_path} not found")

    # ─── Summary ────────────────────────────────────────────────
    print("\n" + "=" * 60)
    print(f"SUMMARY: {len(results)}/8 scripts fixed")
    for name, ok in results.items():
        print(f"  {'OK' if ok else 'FAIL'}: {name}")
    if len(results) < 8:
        missing = set(PANEL_SCRIPTS + ["SpinWheelScript", "UIController"]) - set(results.keys())
        for name in missing:
            print(f"  MISSING: {name}")
    print("=" * 60)

if __name__ == "__main__":
    main()
