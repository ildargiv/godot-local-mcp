@tool
extends RefCounted
## Слой протокола MCP поверх JSON-RPC 2.0. Без состояния сессии, без SSE.

const PROTOCOL_VERSIONS := ["2025-06-18", "2025-03-26", "2024-11-05"]
const SERVER_INFO := {"name": "godot-local-mcp", "version": "0.1.0"}
const INSTRUCTIONS := "Godot editor tools. Node paths are relative to the open scene root: \".\" is the root, \"Player/Sprite2D\" is a child. Call scene_tree first to see the scene. Save with scene_save."

var _tools  # tools.gd


func _init(tools) -> void:
	_tools = tools


## Обработчик для http_server.gd.
func handle_http(body: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(body) != OK:
		return _reply(_error(null, -32700, "parse error: " + json.get_error_message()))
	var msg = json.data
	if msg is Array:
		var out: Array = []
		for m in msg:
			var r = _handle_one(m)
			if r != null:
				out.append(r)
		if out.is_empty():
			return {"status": 202}
		return _reply(out)
	var r = _handle_one(msg)
	if r == null:
		return {"status": 202}
	return _reply(r)


func _reply(payload) -> Dictionary:
	return {"status": 200, "body": JSON.stringify(payload)}


## Возвращает ответ JSON-RPC или null для уведомлений.
func _handle_one(msg):
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("method"):
		return _error(msg.get("id") if msg is Dictionary else null, -32600, "invalid request")
	var id = msg.get("id")
	# JSON в Godot читает все числа как float; id надо вернуть в том же виде (1, а не 1.0).
	if id is float and is_equal_approx(id, roundf(id)):
		id = int(id)
	var is_notification: bool = not msg.has("id")
	var params: Dictionary = msg.get("params", {}) if msg.get("params") is Dictionary else {}
	var method: String = msg.method

	if is_notification:
		return null  # notifications/initialized, notifications/cancelled и т.п.

	match method:
		"initialize":
			var requested: String = params.get("protocolVersion", PROTOCOL_VERSIONS[0])
			var version: String = requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
			return _result(id, {
				"protocolVersion": version,
				"capabilities": {"tools": {"listChanged": false}},
				"serverInfo": SERVER_INFO,
				"instructions": INSTRUCTIONS,
			})
		"ping":
			return _result(id, {})
		"tools/list":
			return _result(id, {"tools": _tools.list_tools()})
		"tools/call":
			var name: String = str(params.get("name", ""))
			var args = params.get("arguments", {})
			if typeof(args) == TYPE_STRING:
				# Некоторые клиенты присылают аргументы строкой JSON.
				var parsed = JSON.parse_string(args)
				args = parsed if parsed is Dictionary else {}
			if not args is Dictionary:
				args = {}
			var res: Dictionary = _tools.call_tool(name, args)
			return _result(id, {
				"content": [{"type": "text", "text": str(res.get("text", ""))}],
				"isError": bool(res.get("error", false)),
			})
		"resources/list":
			return _result(id, {"resources": []})
		"prompts/list":
			return _result(id, {"prompts": []})
		_:
			return _error(id, -32601, "method not found: " + method)


func _result(id, result) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _error(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
