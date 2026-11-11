@tool
extends EditorPlugin
## Точка входа плагина: поднимает HTTP-сервер MCP и пишет конфиг для клиентов.

const HttpServer := preload("res://addons/local_mcp/http_server.gd")
const Mcp := preload("res://addons/local_mcp/mcp.gd")
const Tools := preload("res://addons/local_mcp/tools.gd")

const SETTING_PORT := "local_mcp/port"
const SETTING_AUTH := "local_mcp/require_token"
const DEFAULT_PORT := 6600
const TOKEN_FILE := "res://.godot/local_mcp_token"
const CONFIG_FILE := "res://local_mcp.json"

var _server: HttpServer
var _mcp: Mcp
var _tools: Tools


func _enter_tree() -> void:
	_ensure_settings()
	var port: int = ProjectSettings.get_setting(SETTING_PORT, DEFAULT_PORT)
	var token := ""
	if ProjectSettings.get_setting(SETTING_AUTH, true):
		token = _make_token()
		_write_token(token)

	_tools = Tools.new()
	_tools.setup(self)
	_mcp = Mcp.new(_tools)
	_server = HttpServer.new()
	_server.token = token
	_server.handler = _mcp.handle_http
	var bound := _server.start(port)
	if bound < 0:
		push_error("[LocalMCP] не удалось занять порты %d-%d" % [port, port + 9])
		return
	_write_client_config(bound, token)
	print("[LocalMCP] слушаю http://127.0.0.1:%d/mcp" % bound)


func _exit_tree() -> void:
	if _server:
		_server.stop()
	_server = null
	_mcp = null
	if _tools:
		_tools.teardown()
	_tools = null


func _process(_delta: float) -> void:
	if _server:
		_server.poll()


func _ensure_settings() -> void:
	if not ProjectSettings.has_setting(SETTING_PORT):
		ProjectSettings.set_setting(SETTING_PORT, DEFAULT_PORT)
	ProjectSettings.set_initial_value(SETTING_PORT, DEFAULT_PORT)
	if not ProjectSettings.has_setting(SETTING_AUTH):
		ProjectSettings.set_setting(SETTING_AUTH, true)
	ProjectSettings.set_initial_value(SETTING_AUTH, true)
	for g in Tools.GROUPS:
		var key: String = "local_mcp/groups/" + g
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, false)
		ProjectSettings.set_initial_value(key, false)


func _make_token() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(24).hex_encode()


func _write_token(token: String) -> void:
	var f := FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(token)


## Пишет local_mcp.json с готовыми блоками для HTTP-клиентов и для моста stdio.
func _write_client_config(port: int, token: String) -> void:
	var url := "http://127.0.0.1:%d/mcp" % port
	var http_entry := {"url": url}
	if token != "":
		http_entry["headers"] = {"Authorization": "Bearer " + token}
	var bridge_path := ProjectSettings.globalize_path("res://addons/local_mcp/bridge/stdio_bridge.py")
	var cfg := {
		"_comment": "Скопируйте нужный блок в конфиг вашего MCP-клиента. Файл перезаписывается при каждом запуске редактора.",
		"mcpServers": {
			"godot": http_entry,
		},
		"stdio_variant": {
			"mcpServers": {
				"godot": {
					"command": "python3",
					"args": [bridge_path, "--project", ProjectSettings.globalize_path("res://")],
				}
			}
		},
	}
	var f := FileAccess.open(CONFIG_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(cfg, "  "))
