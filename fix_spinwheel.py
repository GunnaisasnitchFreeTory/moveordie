import json

# Read the full source JSON
with open(r'C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\0bdc89f7-208b-42ea-81cd-40b106a39a51.txt', 'r', encoding='utf-8') as f:
    data = json.load(f)

source = data['source']
lines = source.split('\n')

# New header (replaces lines 0-54, i.e. first 55 lines)
new_header = 'local TweenService = game:GetService("TweenService")\n'
new_header += 'local Players = game:GetService("Players")\n'
new_header += 'local UserInputService = game:GetService("UserInputService")\n'
new_header += 'local RunService = game:GetService("RunService")\n'
new_header += 'local ReplicatedStorage = game:GetService("ReplicatedStorage")\n'
new_header += 'local MarketplaceService = game:GetService("MarketplaceService")\n'
new_header += '\n'
new_header += '-- \xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\xe2\x95\x90\n'
new_header += 'local Shared = ReplicatedStorage:WaitForChild("Shared", 5)\n'
new_header += 'local Deps = require(Shared.ClientDepsProvider)\n'
new_header += 'local ItemCatalog = Deps.ItemCatalog\n'
new_header += 'local SpinWheelConfig = Deps.SpinWheelConfig\n'
new_header += '\n'
new_header += 'if not SpinWheelConfig then\n'
new_header += '\twarn("[SpinWheelScript] SpinWheelConfig not available -- spin wheel disabled")\n'
new_header += '\treturn\n'
new_header += 'end'

# Rest of the script (from line 56 onwards - 0-indexed line 55)
rest = '\n'.join(lines[55:])
modified = new_header + '\n' + rest

with open(r'C:\Cursor\moveordie\spinwheel_modified.lua', 'w', encoding='utf-8') as f:
    f.write(modified)

print(f'Written {len(modified)} chars, {len(modified.split(chr(10)))} lines')
