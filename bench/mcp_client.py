"""Минимальный клиент MCP по HTTP для плагина Local MCP (только стандартная библиотека)."""
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
        # Запросы к 127.0.0.1 не должны идти через системный прокси.
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
        """Возвращает (текст ответа, была ли ошибка)."""
        res = self.rpc("tools/call", {"name": name, "arguments": args})
        text = "".join(c.get("text", "") for c in res.get("content", []))
        return text, bool(res.get("isError"))
