@tool
extends RefCounted
## Reply language. Source strings in the code are English; lang/<code>.json maps
## each English string to its translation. A missing entry falls back to English.
## Choose with the project setting local_mcp/language (auto follows the editor
## language) or the editor environment variable LOCAL_MCP_LANG.

const DIR := "res://addons/local_mcp/lang/"
const SETTING := "local_mcp/language"

static var code := "en"
static var _requested := ""
static var _dict: Dictionary = {}
static var _forced := ""


static func t(s: String) -> String:
	return _dict.get(s, s)


static func available() -> PackedStringArray:
	var out := PackedStringArray(["en"])
	for f in DirAccess.get_files_at(DIR):
		if f.ends_with(".json"):
			out.append(f.get_basename())
	return out


## Reads the env variable or project setting and reloads the dictionary if it changed.
static func refresh() -> void:
	var want := _forced
	if want == "":
		want = OS.get_environment("LOCAL_MCP_LANG").strip_edges()
	if want == "":
		want = str(ProjectSettings.get_setting(SETTING, "auto"))
	want = want.strip_edges().to_lower().replace("-", "_")
	if want == "" or want == "auto":
		want = _editor_language()
	if want == _requested:
		return
	_requested = want
	code = _resolve(want)
	_dict = _load(code)


## Forces a language for one request (MCP tools/call params._meta.lang); "" clears it.
static func force(lang: String) -> void:
	_forced = lang.strip_edges().to_lower().replace("-", "_")
	refresh()


static func _editor_language() -> String:
	if Engine.is_editor_hint():
		var es := EditorInterface.get_editor_settings()
		if es and es.has_setting("interface/editor/editor_language"):
			return str(es.get_setting("interface/editor/editor_language")).to_lower()
	return OS.get_locale().to_lower()


static func _resolve(want: String) -> String:
	var langs := available()
	if want in langs:
		return want
	var base := want.get_slice("_", 0)
	if base in langs:
		return base
	return "en"


static func _load(lang: String) -> Dictionary:
	if lang == "en":
		return {}
	var f := FileAccess.open(DIR + lang + ".json", FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}
