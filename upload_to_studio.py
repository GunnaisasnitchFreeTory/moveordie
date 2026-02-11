"""
Upload modified SpinWheelScript to Roblox Studio via MCP HTTP API.
"""
import urllib.request
import json

# Read the modified source
with open(r'C:\Cursor\moveordie\spinwheel_final.lua', 'r', encoding='utf-8') as f:
    source = f.read()

print(f"Source: {len(source)} chars, {len(source.splitlines())} lines")

# Try the MCP endpoint
payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
        "name": "set_script_source",
        "arguments": {
            "instancePath": "game.StarterGui.SpinWheelGui.SpinWheelScript",
            "source": source
        }
    }
}

# Try common MCP ports
for port in [3002, 3000, 3001, 28823, 28080]:
    for path in ['/mcp', '/sse', '/api/set-script-source']:
        url = f"http://localhost:{port}{path}"
        try:
            data = json.dumps(payload).encode('utf-8')
            req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=5) as resp:
                result = resp.read().decode('utf-8')
                print(f"SUCCESS on {url}: {result[:200]}")
                exit(0)
        except Exception as e:
            print(f"  {url}: {e}")

print("Could not connect to MCP server on any port/path")
