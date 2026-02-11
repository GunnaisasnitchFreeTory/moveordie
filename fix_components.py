"""
Fix Components UIStyle wait: 60s -> FindFirstChild + 5s fallback
"""
import json

# Read the MCP output JSON
with open(r'C:\Users\david\.cursor\projects\c-Cursor-moveordie\agent-tools\34f0c56b-1158-41a9-bffb-3d422b4da3ed.txt', 'r', encoding='utf-8') as f:
    data = json.load(f)

source = data['source']
print(f"Original: {len(source)} chars, {len(source.splitlines())} lines")

# Fix 1: Replace the 60s WaitForChild with FindFirstChild + 5s fallback
old1 = 'local UIStyleModule = Client:WaitForChild("UIStyle", 60)'
new1 = 'local UIStyleModule = Client:FindFirstChild("UIStyle") or Client:WaitForChild("UIStyle", 5)'

if old1 in source:
    source = source.replace(old1, new1, 1)
    print("Fix 1 applied: WaitForChild 60s -> FindFirstChild + 5s")
else:
    print("ERROR: Fix 1 pattern not found!")

# Fix 2: Update the warning message
old2 = 'warn("[Components] UIStyle not found after 60s'
new2 = 'warn("[Components] UIStyle not found after 5s'

if old2 in source:
    source = source.replace(old2, new2, 1)
    print("Fix 2 applied: warning message updated")
else:
    print("ERROR: Fix 2 pattern not found!")

# Also fix the Shared WaitForChild to use FindFirstChild first
old3 = 'local Shared = ReplicatedStorage:WaitForChild("Shared")\n'
new3 = 'local Shared = ReplicatedStorage:FindFirstChild("Shared") or ReplicatedStorage:WaitForChild("Shared", 5)\n'

if old3 in source:
    source = source.replace(old3, new3, 1)
    print("Fix 3 applied: Shared WaitForChild -> FindFirstChild + 5s")
else:
    print("Note: Shared fix pattern not found (may be different format)")

# Save modified source
with open(r'C:\Cursor\moveordie\components_fixed.lua', 'w', encoding='utf-8') as f:
    f.write(source)

print(f"\nSaved: {len(source)} chars, {len(source.splitlines())} lines")
