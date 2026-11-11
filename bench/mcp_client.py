"""Minimal MCP-over-HTTP client for the Local MCP plugin (standard library only)."""
import json
import os
import urllib.request


class McpError(Exception):
    pass


class GodotMcp:
    def __init__(self, project: str | None = None, url: str | None = None, token: str | None = None):
        if project:
            cfg = os.path.join(project, "local_mcp.json")
            tok = os.path.join(project, ".godot", "local_mcp_token")
            if not url and os.path.exists(cfg):
                with open(cfg, encoding="utf-8") as f:
                    url = json.load(f)["mcpServers"]["godot"]["url"]
            if token is None and os.path.exists(tok):
                with open(tok, encoding="utf-8") as f:
                    token = f.read().strip()
        self.url = url or "http://127.0.0.1:6600/mcp"
        self.token = token or ""
        self._id = 0
        # Reply language forced for call() ("en" keeps bench checks language-independent); "" = plugin setting.
        self.lang = "en"
        # Requests to 127.0.0.1 must bypass the system proxy.
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def rpc(self, method: str, params: dict | None = None):
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        with self._opener.open(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        if "error" in data:
            raise McpError(data["error"].get("message"))
        return data["result"]

    def initialize(self):
        return self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                       "clientInfo": {"name": "godot-local-mcp-bench", "version": "0.1"}})

    def tools(self) -> list:
        return self.rpc("tools/list")["tools"]

    def call(self, name: str, /, **args) -> tuple[str, bool]:
        """Returns (reply text, is_error), with replies in self.lang."""
        return self.call_lang(name, args, self.lang)

    def call_lang(self, name: str, args: dict, lang: str = "") -> tuple[str, bool]:
        """Calls a tool; lang forces the reply language via params._meta.lang ("" = plugin setting)."""
        params = {"name": name, "arguments": args}
        if lang:
            params["_meta"] = {"lang": lang}
        res = self.rpc("tools/call", params)
        text = "".join(c.get("text", "") for c in res.get("content", []))
        return text, bool(res.get("isError"))
