#!/usr/bin/env python3
"""stdio <-> HTTP bridge for MCP clients that can only launch a local process.

Reads JSON-RPC messages line by line from stdin, sends them to the Godot plugin
(POST http://127.0.0.1:<port>/mcp) and writes replies to stdout. Standard library only.

    python3 stdio_bridge.py --project /path/to/project
    python3 stdio_bridge.py --url http://127.0.0.1:6600/mcp --token <token>

Port and token are read from <project>/local_mcp.json and <project>/.godot/local_mcp_token,
so nothing needs changing after the editor restarts.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def log(msg: str) -> None:
    print(f"[local-mcp-bridge] {msg}", file=sys.stderr, flush=True)


def endpoint(args) -> tuple[str, str]:
    url, token = args.url, args.token
    if args.project:
        cfg_path = os.path.join(args.project, "local_mcp.json")
        tok_path = os.path.join(args.project, ".godot", "local_mcp_token")
        if not url and os.path.exists(cfg_path):
            with open(cfg_path, encoding="utf-8") as f:
                url = json.load(f).get("mcpServers", {}).get("godot", {}).get("url")
        if not token and os.path.exists(tok_path):
            with open(tok_path, encoding="utf-8") as f:
                token = f.read().strip()
    return url or "http://127.0.0.1:6600/mcp", token or ""


def error_reply(msg_id, text: str) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32000, "message": text}}


def forward(raw: str, args) -> str | None:
    url, token = endpoint(args)  # re-read every time: the editor may have restarted on another port
    req = urllib.request.Request(url, data=raw.encode("utf-8"), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            if resp.status == 202:
                return None
            body = resp.read().decode("utf-8")
            return body or None
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return None
        if not isinstance(msg, dict) or "id" not in msg:
            return None
        reason = getattr(e, "reason", e)
        return json.dumps(error_reply(
            msg["id"],
            f"Godot is not answering at {url} ({reason}). Open the project in the editor and enable the Local MCP plugin.",
        ), ensure_ascii=False)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--project", help="Godot project folder")
    p.add_argument("--url")
    p.add_argument("--token")
    p.add_argument("--timeout", type=float, default=60.0)
    args = p.parse_args()
    log("start, endpoint %s" % endpoint(args)[0])
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        out = forward(line, args)
        if out:
            sys.stdout.write(out.replace("\n", "") + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
