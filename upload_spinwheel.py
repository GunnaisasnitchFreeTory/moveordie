#!/usr/bin/env python3
"""Upload fixed SpinWheelScript to Roblox Studio via MCP HTTP API."""
import urllib.request
import json
import os

BASE_DIR = r"C:\Cursor\moveordie"
FIXED_FILE = os.path.join(BASE_DIR, "fixed_SpinWheelScript.lua")

# Read the fixed source
with open(FIXED_FILE, 'r', encoding='utf-8') as f:
    source = f.read()

print(f"Read {len(source)} chars from {FIXED_FILE}")
print(f"First 100 chars: {source[:100]}")
print(f"Last 100 chars: {source[-100:]}")

# Try to find MCP server port by probing common ports
PORTS = [3002, 3001, 3000, 28080, 8080, 3003]

for port in PORTS:
    base_url = f"http://localhost:{port}"
    
    # Try different endpoint patterns
    endpoints = [
        "/api/set-script-source",
        "/set-script-source", 
        "/api/v1/set-script-source",
        "/tools/set_script_source",
        "/api/execute",
    ]
    
    for endpoint in endpoints:
        url = base_url + endpoint
        payload = json.dumps({
            "instancePath": "game.StarterGui.SpinWheelGui.SpinWheelScript",
            "source": source
        }).encode('utf-8')
        
        req = urllib.request.Request(url, data=payload)
        req.add_header('Content-Type', 'application/json')
        
        try:
            response = urllib.request.urlopen(req, timeout=5)
            result = response.read().decode('utf-8')
            print(f"\nSUCCESS on {url}")
            print(f"Response: {result[:500]}")
            exit(0)
        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode('utf-8')[:200]
            except:
                pass
            # Only print non-404 errors (404 is expected for wrong endpoints)
            if e.code != 404:
                print(f"  HTTP {e.code} on {url}: {body}")
        except Exception as e:
            # Connection refused means wrong port, skip silently
            err_str = str(e)
            if "refused" not in err_str and "timed out" not in err_str:
                print(f"  ERR on {url}: {err_str[:100]}")

print("\nCould not find MCP HTTP endpoint. The file is ready at:")
print(f"  {FIXED_FILE}")
print(f"  Size: {len(source)} chars")
