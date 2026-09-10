"""Independent CUA surface probe: report the live `cua` API surface from a cua_repl kernel.

This is the cheap acceptance step for the CUA surface lock case. It starts the plugin's own
cua_repl MCP server over stdio, reads `Object.keys(cua)` out of a live kernel, and optionally
enumerates the real app/window inventory. Run it with the environment value Desktop writes
(`browser`); seeing `computer,getApp,listApps` under that value is what proves the forced surface
in `scripts/launch.mjs` survives the next Desktop reconcile.

Usage:
  python probe-cua-surface.py [--codex-home <path>] [--surfaces browser]
                              [--skip-inventory]

Exits 1 when a required surface member is missing from `Object.keys(cua)`.
"""
import argparse
import json
import re
import os
import subprocess
import sys
import threading
import time

REQUIRED_MEMBERS = ("computer", "getApp", "listApps")
BANNER_CONSUMING_CALL = "1"
KEYS_CALL = (
    "nodeRepl.write('CUA_KEYS=' + Object.keys(cua).join(','))"
)
INVENTORY_CALL = (
    "let s = await cua.getState();"
    " nodeRepl.write('APPS=' + (s.apps || []).length + ' BROWSERS=' + (s.browsers || []).length)"
)
# The Windows-native entry point. `cua.getApp` / `cua.listApps` are macOS-only in @oai/sky, so a
# Windows conversation has to use the window-based `cua.computer.*` API instead.
WINDOWS_CALL = (
    "let w = await cua.computer.list_windows();"
    " nodeRepl.write('WINDOWS=' + cua.computer.target + '/' + w.length)"
)
# The injected `js` tool description has to steer the model away from the macOS-only entry point,
# otherwise a Windows conversation calls cua.getApp and reads the thrown error as "unavailable".
GUIDANCE_TOKENS = (
    "cua.computer.target",
    "cua.computer.list_windows",
    "Native app bindings are unavailable for windows",
)


def find_mcp_json(codex_home):
    cache_root = os.path.join(codex_home, "plugins", "cache", "openai-bundled", "unified-computer-use")
    if not os.path.isdir(cache_root):
        raise SystemExit(f"no unified-computer-use plugin cache under {cache_root}")
    versions = sorted(
        (d for d in os.listdir(cache_root) if os.path.isfile(os.path.join(cache_root, d, ".mcp.json"))),
        reverse=True,
    )
    if not versions:
        raise SystemExit(f"no materialized .mcp.json under {cache_root}")
    return os.path.join(cache_root, versions[0], ".mcp.json")


def read_server_config(mcp_json):
    with open(mcp_json, encoding="utf-8") as fh:
        payload = json.load(fh)
    try:
        return payload["mcpServers"]["cua_repl"]
    except KeyError:
        raise SystemExit(f"{mcp_json} has no mcpServers.cua_repl entry")


def start_server(config, surfaces):
    env = dict(os.environ)
    env.update({k: v for k, v in config.get("env", {}).items() if isinstance(v, str)})
    if surfaces is not None:
        env["CUA_REPL_ENABLED_SURFACES"] = surfaces

    executable = config["command"]
    launch = config["args"][0]
    if not os.path.isfile(executable):
        raise SystemExit(f"runtime missing: {executable}")
    if not os.path.isfile(launch):
        raise SystemExit(f"launch script missing: {launch}")

    return subprocess.Popen(
        [executable, *config["args"]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    ), env.get("CUA_REPL_ENABLED_SURFACES")


def run_calls(proc, steps, timeout_per_call):
    """Send the MCP handshake, then one step per entry.

    A step is `{"method": "tools/list"}` or `{"method": "tools/call", "code": "<js>"}`.
    Returns one result text per step, in order.
    """
    payloads = {}
    stderr_lines = []
    lock = threading.Lock()

    def stdout_reader():
        for raw in proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message.get("id"), int):
                with lock:
                    payloads.setdefault(message["id"], []).append(message)

    def stderr_reader():
        for raw in proc.stderr:
            text = raw.decode("utf-8", "replace").strip()
            if text:
                stderr_lines.append(text)

    threading.Thread(target=stdout_reader, daemon=True).start()
    threading.Thread(target=stderr_reader, daemon=True).start()

    def send(method, params=None, message_id=None):
        message = {"jsonrpc": "2.0", "method": method}
        if message_id is not None:
            message["id"] = message_id
        if params is not None:
            message["params"] = params
        try:
            proc.stdin.write((json.dumps(message) + "\n").encode())
            proc.stdin.flush()
        except (OSError, ValueError) as exc:
            raise SystemExit(
                f"cua_repl stopped accepting input ({exc}); an invalid CUA_REPL_ENABLED_SURFACES "
                "value or a failed runtime start makes launch.mjs exit before the first call"
            )

    texts = []
    try:
        send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                            "clientInfo": {"name": "cua-surface-probe", "version": "1"}}, 1)
        time.sleep(2)
        send("notifications/initialized", None, None)
        time.sleep(1)

        for index, step in enumerate(steps):
            message_id = index + 2
            if step["method"] == "tools/list":
                send("tools/list", {}, message_id)
            else:
                send("tools/call", {"name": "js", "arguments": {"code": step["code"]}}, message_id)
            deadline = time.time() + timeout_per_call
            while time.time() < deadline:
                with lock:
                    arrived = list(payloads.get(message_id, []))
                if arrived:
                    break
                time.sleep(0.5)

            with lock:
                arrived = list(payloads.get(message_id, []))
            if not arrived:
                texts.append("")
                continue
            result = arrived[0].get("result", {})
            if result.get("isError"):
                texts.append("ERROR " + json.dumps(result)[:300])
                continue
            if step["method"] == "tools/list":
                tools = result.get("tools", [])
                texts.append("\n".join(tool.get("description", "") for tool in tools))
                continue
            texts.append("\n".join(part.get("text", "") for part in result.get("content", [])))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    return texts, stderr_lines


def extract(text, marker):
    """Pull the `MARKER=value` tail out of a tool result that also carries documentation."""
    if not text:
        return None
    flat = text.replace("\n", " ")
    match = re.search(re.escape(marker) + r"(.{0,300})", flat)
    return match.group(1).strip() if match else None


def main():
    parser = argparse.ArgumentParser(description="Probe the live cua API surface.")
    parser.add_argument("--codex-home", default=os.path.join(os.path.expanduser("~"), ".codex"))
    parser.add_argument("--surfaces", default="browser",
                        help="value to force for CUA_REPL_ENABLED_SURFACES (default: browser, "
                             "the value the Desktop reconcile writes)")
    parser.add_argument("--timeout", type=int, default=25, help="seconds to wait per call")
    parser.add_argument("--skip-inventory", action="store_true")
    args = parser.parse_args()

    mcp_json = find_mcp_json(args.codex_home)
    config = read_server_config(mcp_json)
    proc, effective = start_server(config, args.surfaces)

    print(f"mcp.json      : {mcp_json}")
    print(f"surfaces env  : {effective}")

    steps = [
        {"method": "tools/list"},
        {"method": "tools/call", "code": BANNER_CONSUMING_CALL},
        {"method": "tools/call", "code": KEYS_CALL},
    ]
    if not args.skip_inventory:
        steps.append({"method": "tools/call", "code": WINDOWS_CALL})
        steps.append({"method": "tools/call", "code": INVENTORY_CALL})
    texts, stderr_lines = run_calls(proc, steps, args.timeout)

    failures = []

    description = texts[0]
    missing_guidance = [token for token in GUIDANCE_TOKENS if token not in description]
    if missing_guidance:
        failures.append("tool description lacks " + ", ".join(missing_guidance))
        print("description   : FAIL missing Windows guidance")
    else:
        print("description   : windows guidance present")

    keys_line = extract(texts[2] if len(texts) > 2 else "", "CUA_KEYS=")
    if not keys_line:
        print("cua keys      : <no response>")
        for line in stderr_lines[-3:]:
            print(f"stderr        : {line[:200]}")
        return 1

    members = keys_line.split(",")
    print(f"cua keys      : {keys_line}")
    missing = [member for member in REQUIRED_MEMBERS if member not in members]
    if missing:
        failures.append("missing " + ", ".join(missing))

    if not args.skip_inventory:
        windows_line = extract(texts[3] if len(texts) > 3 else "", "WINDOWS=")
        print(f"windows api   : {windows_line or '<no response>'}")
        if not windows_line or windows_line.strip().split(" ")[-1] in ("0", ""):
            failures.append("cua.computer.list_windows returned nothing")

        inventory = extract(texts[4] if len(texts) > 4 else "", "APPS=")
        print(f"inventory     : {inventory or '<no response>'}")

    if failures:
        print("result        : FAIL " + "; ".join(failures))
        return 1

    print("result        : ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
