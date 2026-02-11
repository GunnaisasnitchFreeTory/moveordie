import json

# Read the full source JSON
with open(r'C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\0bdc89f7-208b-42ea-81cd-40b106a39a51.txt', 'r', encoding='utf-8') as f:
    data = json.load(f)

source = data['source']

# Find where the old header ends: line "local player = Players.LocalPlayer"
# In the original, this is on line 56 (0-indexed: 55)
lines = source.split('\n')

# Find the exact line index for "local player = Players.LocalPlayer"
target_idx = None
for i, line in enumerate(lines):
    if line.strip() == 'local player = Players.LocalPlayer':
        target_idx = i
        break

if target_idx is None:
    print("ERROR: Could not find 'local player = Players.LocalPlayer'")
    exit(1)

print(f"Found target line at index {target_idx}")

# New header
new_header_lines = [
    'local TweenService = game:GetService("TweenService")',
    'local Players = game:GetService("Players")',
    'local UserInputService = game:GetService("UserInputService")',
    'local RunService = game:GetService("RunService")',
    'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
    'local MarketplaceService = game:GetService("MarketplaceService")',
    '',
    '-- \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550',
    'local Shared = ReplicatedStorage:WaitForChild("Shared", 5)',
    'local Deps = require(Shared.ClientDepsProvider)',
    'local ItemCatalog = Deps.ItemCatalog',
    'local SpinWheelConfig = Deps.SpinWheelConfig',
    '',
    'if not SpinWheelConfig then',
    '\twarn("[SpinWheelScript] SpinWheelConfig not available \u2014 spin wheel disabled")',
    '\treturn',
    'end',
]

# Combine: new header + rest of script from target_idx onwards
modified_lines = new_header_lines + lines[target_idx:]
modified = '\n'.join(modified_lines)

with open(r'C:\Cursor\moveordie\spinwheel_final.lua', 'w', encoding='utf-8') as f:
    f.write(modified)

print(f'Written {len(modified)} chars, {len(modified_lines)} lines')
