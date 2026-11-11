@tool
extends RefCounted

const L := preload("res://addons/local_mcp/lang.gd")
## MCP protocol layer over JSON-RPC 2.0. No session state, no SSE.

const PROTOCOL_VERSIONS := ["2025-06-18", "2025-03-26", "2024-11-05"]
const SERVER_INFO := {"name": "godot-local-mcp", "version": "0.1.0"}
const INSTRUCTIONS := "Godot editor tools. Node paths are relative to the open scene root: \".\" is the root, \"Player/Sprite2D\" is a child. Call scene_tree first to see the scene. Save with scene_save."

var _tools  # tools.gd


func _init(tools) -> void:
	_tools = tools


## Handler for http_server.gd.
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


## Returns a JSON-RPC response, or null for notifications.
func _handle_one(msg):
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("method"):
		return _error(msg.get("id") if msg is Dictionary else null, -32600, "invalid request")
	var id = msg.get("id")
	# Godot's JSON reads every number as float; the id must come back as sent (1, not 1.0).
	if id is float and is_equal_approx(id, roundf(id)):
		id = int(id)
	var is_notification: bool = not msg.has("id")
	var params: Dictionary = msg.get("params", {}) if msg.get("params") is Dictionary else {}
	var method: String = msg.method

	if is_notification:
		return null  # notifications/initialized, notifications/cancelled and so on

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
				# Some clients send arguments as a JSON string.
				var parsed = JSON.parse_string(args)
				args = parsed if parsed is Dictionary else {}
			if not args is Dictionary:
				args = {}
			# The client may ask for a reply language: params._meta.lang ("en", "ru", ...).
			var meta = params.get("_meta", {})
			var forced: String = str(meta.get("lang", "")) if meta is Dictionary else ""
			if forced != "":
				L.force(forced)
			var res: Dictionary = _tools.call_tool(name, args)
			if forced != "":
				L.force("")
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
