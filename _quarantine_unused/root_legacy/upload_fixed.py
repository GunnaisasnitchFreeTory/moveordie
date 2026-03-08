#!/usr/bin/env python3
"""
upload_fixed.py - Read a fixed Lua file and print its content length.
Used to verify files before uploading to Roblox Studio.
"""
import os
import sys

BASE_DIR = r"C:\Cursor\moveordie"

FILES = {
    "ShopPanel":       "fixed_ShopPanel.lua",
    "FateCrownsPanel": "fixed_FateCrownsPanel.lua",
    "CrateShopPanel":  "fixed_CrateShopPanel.lua",
    "IconImagesPanel": "fixed_IconImagesPanel.lua",
    "IndexPanel":      "fixed_IndexPanel.lua",
    "PetsPanel":       "fixed_PetsPanel.lua",
    "SpinWheelScript": "fixed_SpinWheelScript.lua",
    "UIController":    "fixed_UIController.lua",
}

for name, filename in FILES.items():
    filepath = os.path.join(BASE_DIR, filename)
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        print(f"  OK: {name} = {len(content)} chars, {content.count(chr(10))+1} lines")
    else:
        print(f"  MISSING: {name} ({filepath})")
