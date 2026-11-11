@tool
extends RefCounted
## Набор инструментов ядра. Принципы:
## - плоские схемы, короткие описания (каждый инструмент ~100-150 токенов);
## - прощающий разбор аргументов (синонимы имён, значения в любом разумном формате);
## - ответы короткие и текстовые, ошибка = одна строка "что не так + как исправить";
## - все правки сцены идут через UndoRedo, пользователь может откатить Ctrl+Z.

const Values := preload("res://addons/local_mcp/values.gd")

const MAX_SCRIPT_READ := 400  # строк за один вызов script_read
const MAX_TREE_LINES := 250
const MAX_OUTPUT_LINES := 200

## Синонимы аргументов: локальные модели часто называют поля по-своему.
const ALIASES := {
	"path": ["node_path", "node", "target", "file", "file_path", "script_path", "scene_path"],
	"parent": ["parent_path", "parent_node"],
	"type": ["class", "class_name", "node_type", "node_class"],
	"name": ["node_name", "new_node_name"],
	"properties": ["props", "values", "property_values", "params"],
	"content": ["code", "source", "text", "script", "body"],
	"scene": ["scene_path"],
	"new_parent": ["new_parent_path", "to_parent"],
	"new_name": ["rename", "rename_to"],
	"old_text": ["old_string", "old", "find", "search"],
	"new_text": ["new_string", "new", "replace", "replacement"],
	"start_line": ["from_line", "line_start", "start"],
	"end_line": ["to_line", "line_end", "end"],
	"from": ["source_node", "emitter", "from_node"],
	"to": ["target_node", "receiver", "to_node"],
	"signal": ["signal_name"],
	"method": ["method_name", "callback", "handler"],
	"filter": ["query", "search", "pattern"],
	"tile": ["atlas_coords", "tile_coords", "atlas"],
	"cells": ["positions", "coords", "cell_list"],
	"texture": ["image", "texture_path", "atlas_texture"],
	"tile_size": ["cell_size", "tile_px"],
	"player": ["animation_player", "anim_player"],
	"animation": ["anim", "animation_name", "anim_name"],
	"keys": ["keyframes", "frames"],
}

## Подключаемые группы: имя -> скрипт. Включаются в настройках проекта local_mcp/groups/<имя>
## или переменной окружения LOCAL_MCP_GROUPS="tilemap,animation" (удобно для стенда).
const GROUPS := {
	"tilemap": "res://addons/local_mcp/groups/tilemap.gd",
	"animation": "res://addons/local_mcp/groups/animation.gd",
}

var _plugin: EditorPlugin
var _groups := {}  # имя -> объект группы
var _logger: Object = null
var _defs: Array = []
var _last_run_ms := 0


func setup(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_defs = _build_defs()
	for g in GROUPS:
		var script = load(GROUPS[g])
		if script:
			var obj = script.new()
			obj.t = self
			_groups[g] = obj
	if ClassDB.class_exists("Logger") and OS.has_method("add_logger"):
		var script = load("res://addons/local_mcp/logger_capture.gd")
		if script:
			_logger = script.new()
			OS.call("add_logger", _logger)


func teardown() -> void:
	if _logger and OS.has_method("remove_logger"):
		OS.call("remove_logger", _logger)
	_logger = null
	for g in _groups:
		_groups[g].t = null
	_groups.clear()
	_plugin = null


# ─────────────────────────── описание инструментов ───────────────────────────

static func _s(t: String, d: String = "") -> Dictionary:
	var out := {"type": t}
	if d != "":
		out["description"] = d
	return out


static func _tool(name: String, desc: String, props: Dictionary, required: Array = [], read_only := false) -> Dictionary:
	return {
		"name": name,
		"description": desc,
		"inputSchema": {"type": "object", "properties": props, "required": required},
		"annotations": {"readOnlyHint": read_only, "destructiveHint": false, "openWorldHint": false},
	}


func _build_defs() -> Array:
	return [
		_tool("project_info", "Project overview: name, Godot version, main scene, open scene, list of scene and script files.",
			{"filter": _s("string", "Optional substring to filter file paths.")}, [], true),
		_tool("scene_tree", "Show the open scene as an indented tree: name (Type) [script]. Call this before editing nodes.",
			{"path": _s("string", "Subtree root, default \".\"."), "depth": _s("integer", "Max depth, default 10.")}, [], true),
		_tool("scene_open", "Open a scene file in the editor.",
			{"path": _s("string", "res://... .tscn")}, ["path"]),
		_tool("scene_new", "Create a new scene file with one root node, save it and open it.",
			{"path": _s("string", "res://... .tscn"), "type": _s("string", "Root node class, default Node2D."),
			"name": _s("string", "Root node name, default from file name.")}, ["path"]),
		_tool("scene_save", "Save the open scene.", {}),
		_tool("node_add", "Add a node. type is a class (Sprite2D), a script class_name, or a scene file res://x.tscn to instance.",
			{"parent": _s("string", "Parent path, default \".\" (root)."), "type": _s("string"),
			"name": _s("string"), "properties": _s("object", "Property values, e.g. {\"position\": [100, 50]}.")}, ["type"]),
		_tool("node_info", "Show a node: type, script, changed properties, signals connections, children.",
			{"path": _s("string")}, ["path"], true),
		_tool("node_set", "Set node properties. Values are flexible: vectors [x, y], colors \"#ff0000\", resources \"res://a.png\" or {\"type\": \"CircleShape2D\", \"radius\": 16}, enums by name.",
			{"path": _s("string"), "properties": _s("object", "{\"property\": value, ...}")}, ["path", "properties"]),
		_tool("node_delete", "Delete a node and its children.",
			{"path": _s("string")}, ["path"]),
		_tool("node_move", "Rename, reparent or reorder a node. Give any of new_name, new_parent, index.",
			{"path": _s("string"), "new_name": _s("string"), "new_parent": _s("string"),
			"index": _s("integer", "Position among siblings, 0 = first.")}, ["path"]),
		_tool("signal_connect", "Connect a node signal to a method on another node and save it in the scene.",
			{"from": _s("string", "Node that emits, e.g. \"StartButton\"."), "signal": _s("string", "e.g. pressed"),
			"to": _s("string", "Node with the script, default \".\"."), "method": _s("string", "e.g. _on_start_pressed")},
			["from", "signal", "method"]),
		_tool("script_read", "Read a script or text file with line numbers.",
			{"path": _s("string", "res://..."), "start_line": _s("integer"), "end_line": _s("integer")}, ["path"], true),
		_tool("script_write", "Create or overwrite a script file and check it for errors. Optionally attach it to a node.",
			{"path": _s("string", "res://... .gd"), "content": _s("string", "Full file text."),
			"attach_to": _s("string", "Node path to attach the script to.")}, ["path", "content"]),
		_tool("script_edit", "Change part of a script. Either replace lines start_line..end_line with new_text, or replace old_text with new_text (indentation differences are tolerated).",
			{"path": _s("string"), "new_text": _s("string"), "old_text": _s("string"),
			"start_line": _s("integer"), "end_line": _s("integer")}, ["path", "new_text"]),
		_tool("game_run", "Run the game. scene: \"main\" (default), \"current\" or a res://... .tscn path. Then use game_output.",
			{"scene": _s("string")}),
		_tool("game_stop", "Stop the running game.", {}),
		_tool("game_output", "Show the output and errors of the last game run, and recent editor errors.",
			{"errors_only": _s("boolean", "Only errors and warnings."), "lines": _s("integer", "Max lines, default 60.")}, [], true),
		_tool("class_info", "Look up a Godot class: its properties, methods and signals. Use filter to search by name.",
			{"type": _s("string", "Class name, e.g. CharacterBody2D."), "filter": _s("string")}, ["type"], true),
	]


func list_tools() -> Array:
	var out: Array = _defs.duplicate()
	for g in enabled_groups():
		out.append_array(_groups[g].defs())
	return out


## Включённые группы. Читается при каждом tools/list: включили галочку — переподключите клиента.
func enabled_groups() -> Array:
	var out: Array = []
	var env := OS.get_environment("LOCAL_MCP_GROUPS").to_lower()
	for g in _groups:
		if env.contains(g) or env == "all" or bool(ProjectSettings.get_setting("local_mcp/groups/" + g, false)):
			out.append(g)
	return out


# ─────────────────────────── диспетчер ───────────────────────────

func call_tool(name: String, raw_args: Dictionary) -> Dictionary:
	var def := {}
	var all_defs := list_tools()
	for d in all_defs:
		if d.name == name:
			def = d
			break
	if def.is_empty():
		for g in _groups:
			for d in _groups[g].defs():
				if d.name == name:
					return _err("инструмент %s из группы \"%s\", она выключена. Включите local_mcp/groups/%s в настройках проекта и переподключите клиента" % [name, g, g])
		var names: Array = []
		for d in all_defs:
			names.append(d.name)
		return _err("нет инструмента \"%s\". Есть: %s" % [name, ", ".join(names)])
	var args := _normalize_args(raw_args, def.inputSchema.properties)
	for req in def.inputSchema.required:
		if not args.has(req) or (args[req] is String and args[req] == "" and req != "new_text" and req != "content"):
			return _err("не хватает аргумента \"%s\" (обязательные: %s)" % [req, ", ".join(def.inputSchema.required)])
	var fn := "_t_" + name
	var target: Object = self if has_method(fn) else null
	if target == null:
		for g in _groups:
			if _groups[g].has_method(fn):
				target = _groups[g]
	if target == null:
		return _err("инструмент не реализован: " + name)
	# В GDScript нет try/catch: при ошибке выполнения call() вернёт null, и раньше модель
	# получала пустой «успешный» ответ. Теперь это явная ошибка с текстом из лога.
	var mark: int = _logger.mark() if _logger else 0
	var res = target.call(fn, args)
	if res is Dictionary and res.has("text"):
		return res
	var why: Array = []
	if _logger:
		for l in _logger.since(mark):
			why.append(_clean_err(l))
	return _err("внутренняя ошибка инструмента %s%s. Попробуйте другие аргументы; если повторяется, это баг плагина" % [
		name, (": " + "; ".join(why.slice(0, 3))) if not why.is_empty() else ""])


## Переименовывает синонимы в канонические имена, приводит числа и булевы.
func _normalize_args(raw: Dictionary, schema_props: Dictionary) -> Dictionary:
	var known: Array = schema_props.keys()
	var out := {}
	for k in raw:
		out[str(k)] = raw[k]
	for canon in ALIASES:
		if not canon in known or out.has(canon):
			continue
		for alias in ALIASES[canon]:
			if out.has(alias) and not alias in known:
				out[canon] = out[alias]
				break
	# Приведение по типу из схемы: модели присылают "True", "1", "[32, 32]" строками.
	for k in out.keys():
		if not schema_props.has(k):
			continue
		var want: String = str(schema_props[k].get("type", ""))
		var v = out[k]
		match want:
			"boolean":
				if v is String:
					out[k] = (v as String).strip_edges().to_lower() in ["true", "1", "yes", "on", "да"]
				elif v is float or v is int:
					out[k] = v != 0
				elif v == null:
					out[k] = false
			"integer":
				if v is String and (v as String).strip_edges().is_valid_float():
					out[k] = int(float(v))
				elif v is float:
					out[k] = int(v)
			"number":
				if v is String and (v as String).strip_edges().is_valid_float():
					out[k] = float(v)
			"array", "object":
				if v is String:
					var parsed = JSON.parse_string(v)
					if (want == "array" and parsed is Array) or (want == "object" and parsed is Dictionary):
						out[k] = parsed
	return out


static func _ok(text: String) -> Dictionary:
	return {"text": text, "error": false}


static func _err(text: String) -> Dictionary:
	return {"text": "Ошибка: " + text, "error": true}


# ─────────────────────────── общие помощники ───────────────────────────

func _root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _ur() -> EditorUndoRedoManager:
	return _plugin.get_undo_redo()


func _no_scene() -> Dictionary:
	return _err("нет открытой сцены. Откройте её через scene_open или создайте через scene_new")


func _rel(node: Node) -> String:
	var root := _root()
	if node == root:
		return "."
	return str(root.get_path_to(node))


## Для сообщений: корень показываем по имени, а не точкой.
func _label(node: Node) -> String:
	return str(node.name) if node == _root() else _rel(node)


## Ищет узел по пути с поблажками: ".", имя корня, "./A/B", "Root/A/B", "/root/Root/A".
## Возвращает {"node": Node} или {"error": "..."} с подсказкой, какие узлы есть рядом.
func _find(path) -> Dictionary:
	var root := _root()
	if root == null:
		return {"error": _no_scene().text.trim_prefix("Ошибка: ")}
	var p := str(path if path != null else ".").strip_edges().replace("\\", "/")
	if p.begins_with("/root/"):
		p = p.substr(6)
	p = p.trim_prefix("/").trim_prefix("./").trim_suffix("/")
	if p == "" or p == "." or p == root.name:
		return {"node": root}
	if p.begins_with(root.name + "/") and root.get_node_or_null(p.get_slice("/", 0)) == null:
		p = p.substr(root.name.length() + 1)
	if p.begins_with("%"):
		var u := root.get_node_or_null(p)
		if u:
			return {"node": u}
	var n := root.get_node_or_null(p)
	if n:
		return {"node": n}
	# Уникальное имя где-то в глубине?
	var by_name := root.find_children(p.get_file(), "", true, false)
	if by_name.size() == 1 and not p.contains("/"):
		return {"node": by_name[0]}
	# Подсказка: дети ближайшего существующего предка.
	var parts := p.split("/")
	var cur: Node = root
	for part in parts:
		var next := cur.get_node_or_null(part)
		if next == null:
			break
		cur = next
	var kids: Array = []
	for c in cur.get_children():
		kids.append(str(c.name))
	var near := "у \"%s\" нет детей" % _rel(cur) if kids.is_empty() else "дети \"%s\": %s" % [_rel(cur), ", ".join(kids.slice(0, 20))]
	return {"error": "узел \"%s\" не найден; %s" % [str(path), near]}


func _res_path(p) -> Dictionary:
	var s := str(p if p != null else "").strip_edges().replace("\\", "/")
	if s == "":
		return {"error": "пустой путь"}
	if not s.begins_with("res://"):
		s = "res://" + s.trim_prefix("/")
	if s.contains("/../") or s.ends_with("/..") or s.begins_with("res://.."):
		return {"error": "путь не может выходить за пределы проекта"}
	if s.begins_with("res://addons/local_mcp/") or s.begins_with("res://.godot/"):
		return {"error": "эта папка защищена"}
	return {"path": s}


func _ensure_dir(res_path: String) -> void:
	var dir := res_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)


func _fs_update(path: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs:
		fs.update_file(path)


## Подбирает похожие имена свойств для подсказки.
static func _similar_props(obj: Object, wanted: String) -> String:
	var names: Array = []
	for p in obj.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR:
			names.append(str(p.name))
	return ", ".join(_similar(names, wanted, 6))


## Ближайшие по написанию строки (опечатки моделей: positon, Charakter).
static func _similar(names: Array, wanted: String, limit: int) -> Array:
	var w := wanted.to_lower().replace("_", "")
	var scored: Array = []
	for n in names:
		var nn := str(n).to_lower().replace("_", "")
		var score := nn.similarity(w)
		if nn.contains(w) or (w.contains(nn) and nn.length() > 3):
			score += 0.5
		if score >= 0.55:
			scored.append([score, n])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out: Array = []
	for pair in scored.slice(0, limit):
		out.append(pair[1])
	return out


## camelCase -> snake_case, частая ошибка моделей ("modulateColor", "zIndex").
static func _snake(s: String) -> String:
	return s.to_snake_case() if s != s.to_lower() else s


func _set_props(node: Node, props: Dictionary, ur: EditorUndoRedoManager) -> Array:
	## Возвращает [applied: Array[String], failed: Array[String]].
	var applied: Array = []
	var failed: Array = []
	for key in props:
		var prop := str(key)
		if not Values.has_property(node, prop) and Values.has_property(node, _snake(prop)):
			prop = _snake(prop)
		if prop == "script":
			failed.append("script: используйте script_write с attach_to или node_add")
			continue
		if not Values.has_property(node, prop):
			var sim := _similar_props(node, prop)
			failed.append("%s: у %s нет такого свойства%s" % [prop, node.get_class(), (" (похожие: " + sim + ")") if sim != "" else ""])
			continue
		var c := Values.coerce_for(node, prop, props[key])
		if not c.ok:
			failed.append("%s: %s" % [prop, c.error])
			continue
		if prop.contains(":"):
			var old = node.get_indexed(NodePath(prop))
			ur.add_do_method(node, "set_indexed", NodePath(prop), c.value)
			ur.add_undo_method(node, "set_indexed", NodePath(prop), old)
		else:
			ur.add_do_property(node, prop, c.value)
			ur.add_undo_property(node, prop, node.get(prop))
		if c.value is Resource:
			ur.add_do_reference(c.value)
		applied.append(prop)
	return [applied, failed]


func _report_props(node: Node, applied: Array) -> String:
	var parts: Array = []
	for prop in applied:
		var v = node.get_indexed(NodePath(prop)) if str(prop).contains(":") else node.get(prop)
		parts.append("%s=%s" % [prop, _show_prop(node, prop, v)])
	return ", ".join(parts)


## Значение свойства для ответа; у enum показываем имя.
func _show_prop(node: Node, prop: String, v) -> String:
	if typeof(v) == TYPE_INT:
		var info := Values.property_info(node, prop)
		if int(info.get("hint", 0)) == PROPERTY_HINT_ENUM:
			var idx := 0
			for item in str(info.hint_string).split(","):
				var parts := item.split(":")
				var val := int(parts[1]) if parts.size() > 1 else idx
				if val == v:
					return "%d (%s)" % [v, parts[0].strip_edges()]
				idx += 1
	return Values.show(v)


## Узлы поддерева, принадлежащие сцене (нужно, чтобы восстановить owner после undo).
func _owned(node: Node, root: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c.owner == root:
			out.append(c)
		out.append_array(_owned(c, root))
	return out


func _set_owners(nodes: Array, owner: Node) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.owner = owner


# ─────────────────────────── инструменты: проект и сцена ───────────────────────────

func _t_project_info(args: Dictionary) -> Dictionary:
	var lines: Array = []
	lines.append("Проект: %s" % ProjectSettings.get_setting("application/config/name", "?"))
	var v := Engine.get_version_info()
	lines.append("Godot: %d.%d.%d" % [v.major, v.minor, v.patch])
	lines.append("Главная сцена: %s" % (ProjectSettings.get_setting("application/run/main_scene", "") if ProjectSettings.get_setting("application/run/main_scene", "") != "" else "не задана"))
	var root := _root()
	lines.append("Открыта сцена: %s" % (root.scene_file_path if root and root.scene_file_path != "" else ("несохранённая" if root else "нет")))
	var autoloads: Array = []
	for prop in ProjectSettings.get_property_list():
		var n: String = prop.name
		if n.begins_with("autoload/"):
			autoloads.append(n.substr(9))
	if not autoloads.is_empty():
		lines.append("Автозагрузки: " + ", ".join(autoloads))
	var filter: String = str(args.get("filter", ""))
	var files: Array = []
	_collect_files("res://", files, filter)
	files.sort()
	lines.append("Файлы (%d):" % files.size())
	for f in files.slice(0, 200):
		lines.append("  " + f)
	if files.size() > 200:
		lines.append("  …и ещё %d, уточните filter" % (files.size() - 200))
	return _ok("\n".join(lines))


func _collect_files(dir: String, out: Array, filter: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = false
	for sub in d.get_directories():
		if sub.begins_with(".") or (dir == "res://" and sub == "addons"):
			continue
		_collect_files(dir.path_join(sub), out, filter)
	for f in d.get_files():
		var ext := f.get_extension()
		if ext in ["tscn", "gd", "cs", "tres", "gdshader"]:
			var full := dir.path_join(f)
			if filter == "" or full.containsn(filter):
				out.append(full)


func _t_scene_tree(args: Dictionary) -> Dictionary:
	var f := _find(args.get("path", "."))
	if f.has("error"):
		return _err(f.error)
	var depth: int = args.get("depth", 10)
	var lines: Array = []
	_tree_lines(f.node, 0, depth, lines)
	var root := _root()
	var header := "Сцена %s" % (root.scene_file_path if root.scene_file_path != "" else "(не сохранена)")
	if lines.size() > MAX_TREE_LINES:
		var extra := lines.size() - MAX_TREE_LINES
		lines = lines.slice(0, MAX_TREE_LINES)
		lines.append("…ещё %d узлов, используйте path или depth" % extra)
	return _ok(header + "\n" + "\n".join(lines))


func _tree_lines(node: Node, level: int, max_depth: int, out: Array) -> void:
	var line := "  ".repeat(level) + "%s (%s)" % [node.name, node.get_class()]
	var extras: Array = []
	var scr: Script = node.get_script()
	if scr and scr.resource_path != "":
		extras.append("script: " + scr.resource_path)
	if node != _root() and node.scene_file_path != "":
		extras.append("scene: " + node.scene_file_path)
	if node.unique_name_in_owner:
		extras.append("%" + str(node.name))
	if not extras.is_empty():
		line += " [" + ", ".join(extras) + "]"
	out.append(line)
	# Внутренности инстанса сцены не разворачиваем: модель их не редактирует.
	if level >= max_depth or (node != _root() and node.scene_file_path != ""):
		if node.get_child_count() > 0 and level >= max_depth:
			out.append("  ".repeat(level + 1) + "…%d детей" % node.get_child_count())
		return
	for c in node.get_children():
		if c.owner == null and c != _root():
			continue  # внутренние узлы редактора
		_tree_lines(c, level + 1, max_depth, out)


func _t_scene_open(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	if not ResourceLoader.exists(r.path):
		return _err("сцена не найдена: %s. Создайте её через scene_new" % r.path)
	EditorInterface.open_scene_from_path(r.path)
	return _ok("Открыта %s" % r.path)


func _t_scene_new(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	var path: String = r.path
	if path.get_extension() != "tscn":
		path = path.get_basename() + ".tscn"
	if FileAccess.file_exists(path):
		return _err("файл %s уже есть. Откройте его через scene_open" % path)
	var type: String = str(args.get("type", "Node2D"))
	if type == "":
		type = "Node2D"
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node") or not ClassDB.can_instantiate(type):
		return _err("\"%s\" не класс узла. Примеры: Node2D, Node3D, Control, CharacterBody2D" % type)
	var root: Node = ClassDB.instantiate(type)
	var name := str(args.get("name", ""))
	var root_name := name.validate_node_name() if name != "" else path.get_file().get_basename().to_pascal_case()
	root.name = root_name
	var packed := PackedScene.new()
	packed.pack(root)
	_ensure_dir(path)
	var err := ResourceSaver.save(packed, path)
	root.free()
	if err != OK:
		return _err("не удалось сохранить %s (код %d)" % [path, err])
	_fs_update(path)
	EditorInterface.open_scene_from_path(path)
	return _ok("Создана и открыта %s, корень %s (%s)" % [path, root_name, type])


func _t_scene_save(_args: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _no_scene()
	if root.scene_file_path == "":
		return _err("сцена ещё не сохранялась. Создавайте сцены через scene_new")
	var err := EditorInterface.save_scene()
	if err != OK:
		return _err("не удалось сохранить (код %d)" % err)
	return _ok("Сохранено: " + root.scene_file_path)


# ─────────────────────────── инструменты: узлы ───────────────────────────

func _t_node_add(args: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _no_scene()
	var pf := _find(args.get("parent", "."))
	if pf.has("error"):
		return _err("родитель: " + pf.error)
	var parent: Node = pf.node
	var type := str(args.type).strip_edges()
	var node: Node = null
	if type.ends_with(".tscn") or type.ends_with(".scn"):
		var r := _res_path(type)
		if r.has("error"):
			return _err(r.error)
		if not ResourceLoader.exists(r.path):
			return _err("сцена не найдена: " + r.path)
		var packed: PackedScene = load(r.path)
		if r.path == root.scene_file_path:
			return _err("нельзя вставить сцену саму в себя")
		node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	elif ClassDB.class_exists(type):
		if not ClassDB.is_parent_class(type, "Node"):
			return _err("%s не узел (это %s). Ресурсы задаются через node_set, например {\"shape\": {\"type\": \"%s\"}}" % [type, ClassDB.get_parent_class(type), type])
		if not ClassDB.can_instantiate(type):
			return _err("%s абстрактный класс, выберите наследника" % type)
		node = ClassDB.instantiate(type)
	else:
		var script_path := _global_class_path(type)
		if script_path == "":
			return _err("неизвестный тип \"%s\". Это не класс Godot, не class_name из скриптов и не .tscn" % type)
		var scr: Script = load(script_path)
		node = ClassDB.instantiate(scr.get_instance_base_type())
		node.set_script(scr)
	var wanted_name := str(args.get("name", ""))
	if wanted_name != "":
		node.name = wanted_name.validate_node_name()
	elif node.name == "" or node.name.begins_with("@"):
		node.name = type.get_file().get_basename() if type.contains("/") else type

	var ur := _ur()
	ur.create_action("MCP: добавить " + str(node.name), UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()

	var msg := "Добавлен %s (%s) в %s" % [_rel(node), node.get_class(), _rel(parent)]
	if wanted_name != "" and str(node.name) != wanted_name.validate_node_name():
		msg += "; имя было занято, выдано " + str(node.name)
	var props = args.get("properties", {})
	if props is Dictionary and not props.is_empty():
		ur.create_action("MCP: свойства " + str(node.name), UndoRedo.MERGE_DISABLE, root)
		var res := _set_props(node, props, ur)
		ur.commit_action()
		if not res[0].is_empty():
			msg += "\nСвойства: " + _report_props(node, res[0])
		if not res[1].is_empty():
			msg += "\nНе применено: " + "; ".join(res[1])
	return _ok(msg)


func _global_class_path(cls: String) -> String:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == cls:
			return str(entry.get("path", ""))
	return ""


func _t_node_info(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var node: Node = f.node
	var lines: Array = []
	lines.append("%s (%s)" % [_rel(node), node.get_class()])
	var scr: Script = node.get_script()
	if scr:
		lines.append("Скрипт: " + (scr.resource_path if scr.resource_path != "" else "встроенный"))
	if node.scene_file_path != "" and node != _root():
		lines.append("Инстанс сцены: " + node.scene_file_path)
	var changed: Array = []
	for p in node.get_property_list():
		if not (p.usage & PROPERTY_USAGE_STORAGE) or not (p.usage & PROPERTY_USAGE_EDITOR):
			continue
		var n: String = p.name
		if n in ["script", "owner", "name", "scene_file_path", "unique_name_in_owner"] or n.begins_with("metadata/"):
			continue
		var cur = node.get(n)
		var def = ClassDB.class_get_property_default_value(node.get_class(), n)
		if scr and scr.has_method("get_property_default_value"):
			var sdef = scr.get_property_default_value(n)
			if sdef != null:
				def = sdef
		if typeof(cur) == typeof(def) and cur == def:
			continue
		if cur == null and def == null:
			continue
		changed.append("  %s = %s" % [n, _show_prop(node, n, cur)])
	lines.append("Изменённые свойства:" if not changed.is_empty() else "Изменённых свойств нет")
	lines.append_array(changed.slice(0, 60))
	var conns: Array = []
	for sig in node.get_signal_list():
		for c in node.get_signal_connection_list(sig.name):
			if c.flags & CONNECT_PERSIST:
				var target = (c.callable as Callable).get_object()
				var tname := _rel(target) if target is Node and _root().is_ancestor_of(target) or target == _root() else "?"
				conns.append("  %s -> %s.%s" % [sig.name, tname, (c.callable as Callable).get_method()])
	if not conns.is_empty():
		lines.append("Сигналы:")
		lines.append_array(conns)
	var kids: Array = []
	for c in node.get_children():
		if c.owner != null:
			kids.append("%s (%s)" % [c.name, c.get_class()])
	if not kids.is_empty():
		lines.append("Дети: " + ", ".join(kids.slice(0, 40)))
	return _ok("\n".join(lines))


func _t_node_set(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var props = args.properties
	if not props is Dictionary or props.is_empty():
		return _err("properties должен быть объектом, например {\"position\": [100, 50]}")
	var node: Node = f.node
	var ur := _ur()
	ur.create_action("MCP: свойства " + str(node.name), UndoRedo.MERGE_DISABLE, _root())
	var res := _set_props(node, props, ur)
	ur.commit_action()
	var msg := ""
	if not res[0].is_empty():
		msg = "%s: %s" % [_rel(node), _report_props(node, res[0])]
	if not res[1].is_empty():
		msg += ("\n" if msg != "" else "") + "Не применено: " + "; ".join(res[1])
	return _err(msg.trim_prefix("\n")) if res[0].is_empty() else _ok(msg)


func _t_node_delete(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var node: Node = f.node
	var root := _root()
	if node == root:
		return _err("корень сцены удалить нельзя")
	var parent := node.get_parent()
	var owned := _owned(node, root)
	var path := _rel(node)
	var ur := _ur()
	ur.create_action("MCP: удалить " + str(node.name), UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node, true)
	ur.add_undo_method(parent, "move_child", node, node.get_index())
	ur.add_undo_method(node, "set_owner", root)
	ur.add_undo_method(self, "_set_owners", owned, root)
	ur.add_undo_reference(node)
	ur.commit_action()
	return _ok("Удалён %s%s" % [path, (" вместе с %d дочерними" % owned.size()) if owned.size() > 0 else ""])


func _t_node_move(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var node: Node = f.node
	var root := _root()
	if node == root:
		return _err("корень сцены нельзя перемещать или переименовывать")
	var has_change := args.has("new_name") or args.has("new_parent") or args.has("index")
	if not has_change:
		return _err("укажите хотя бы одно: new_name, new_parent или index")
	var old_parent := node.get_parent()
	var old_index := node.get_index()
	var new_parent: Node = old_parent
	if args.has("new_parent") and str(args.new_parent) != "":
		var pf := _find(args.new_parent)
		if pf.has("error"):
			return _err("new_parent: " + pf.error)
		new_parent = pf.node
		if new_parent == node or node.is_ancestor_of(new_parent):
			return _err("нельзя переместить узел внутрь самого себя")
	var ur := _ur()
	ur.create_action("MCP: переместить " + str(node.name), UndoRedo.MERGE_DISABLE, root)
	if args.has("new_name") and str(args.new_name) != "":
		var nn := str(args.new_name).validate_node_name()
		if new_parent.has_node(NodePath(nn)) and new_parent.get_node(NodePath(nn)) != node:
			ur.commit_action()
			return _err("в \"%s\" уже есть узел %s" % [_rel(new_parent), nn])
		ur.add_do_property(node, "name", nn)
		ur.add_undo_property(node, "name", node.name)
	var owned := _owned(node, root)
	if new_parent != old_parent:
		ur.add_do_method(node, "reparent", new_parent, true)
		ur.add_do_method(node, "set_owner", root)
		ur.add_do_method(self, "_set_owners", owned, root)
		ur.add_undo_method(node, "reparent", old_parent, true)
		ur.add_undo_method(old_parent, "move_child", node, old_index)
		ur.add_undo_method(node, "set_owner", root)
		ur.add_undo_method(self, "_set_owners", owned, root)
	if args.has("index"):
		ur.add_do_method(new_parent, "move_child", node, int(args.index))
		if new_parent == old_parent:
			ur.add_undo_method(old_parent, "move_child", node, old_index)
	ur.commit_action()
	return _ok("Теперь %s (позиция %d в %s)" % [_rel(node), node.get_index(), _rel(node.get_parent())])


func _t_signal_connect(args: Dictionary) -> Dictionary:
	var ff := _find(args.from)
	if ff.has("error"):
		return _err("from: " + ff.error)
	var tf := _find(args.get("to", "."))
	if tf.has("error"):
		return _err("to: " + tf.error)
	var src: Node = ff.node
	var dst: Node = tf.node
	var sig := str(args.signal).strip_edges().trim_suffix("()")
	if not src.has_signal(sig):
		var names: Array = []
		for s in src.get_signal_list():
			names.append(s.name)
		return _err("у %s (%s) нет сигнала \"%s\". Есть: %s" % [_rel(src), src.get_class(), sig, ", ".join(names.slice(0, 30))])
	var method := str(args.method).strip_edges().trim_suffix("()")
	var callable := Callable(dst, method)
	if src.is_connected(sig, callable):
		return _ok("Уже подключено: %s.%s -> %s.%s" % [_label(src), sig, _label(dst), method])
	var ur := _ur()
	ur.create_action("MCP: сигнал " + sig, UndoRedo.MERGE_DISABLE, _root())
	ur.add_do_method(src, "connect", sig, callable, CONNECT_PERSIST)
	ur.add_undo_method(src, "disconnect", sig, callable)
	ur.commit_action()
	var msg := "Подключено: %s.%s -> %s.%s" % [_label(src), sig, _label(dst), method]
	if not dst.has_method(method):
		var scr: Script = dst.get_script()
		msg += "\nВнимание: у %s нет метода %s. Добавьте в %s: func %s(%s):" % [
			_label(dst), method, scr.resource_path if scr else "его скрипт (скрипта нет)", method, _signal_args(src, sig)]
	return _ok(msg)


func _signal_args(src: Node, sig: String) -> String:
	for s in src.get_signal_list():
		if s.name == sig:
			var parts: Array = []
			for a in s.args:
				parts.append(a.name)
			return ", ".join(parts)
	return ""


# ─────────────────────────── инструменты: скрипты ───────────────────────────

func _t_script_read(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	if not FileAccess.file_exists(r.path):
		return _err("файл не найден: " + r.path)
	var text := FileAccess.get_file_as_string(r.path)
	var lines := text.split("\n")
	var total := lines.size()
	var start: int = clampi(int(args.get("start_line", 1)), 1, max(total, 1))
	var end: int = clampi(int(args.get("end_line", start + MAX_SCRIPT_READ - 1)), start, total)
	var out: Array = ["%s (строк: %d)" % [r.path, total]]
	for i in range(start - 1, end):
		out.append("%4d| %s" % [i + 1, lines[i]])
	if end < total:
		out.append("…дальше строки %d-%d, используйте start_line" % [end + 1, total])
	return _ok("\n".join(out))


func _t_script_write(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	var path: String = r.path
	var content := _clean_code(str(args.content))
	var existed := FileAccess.file_exists(path)
	var res := _save_script(path, content)
	if res.has("error"):
		return _err(res.error)
	var msg := "%s %s (%d строк)" % ["Перезаписан" if existed else "Создан", path, content.split("\n").size()]
	msg += "\n" + res.check
	var attach := str(args.get("attach_to", ""))
	if attach != "":
		var f := _find(attach)
		if f.has("error"):
			msg += "\nНе прикреплён: " + f.error
		elif res.valid:
			var node: Node = f.node
			var scr: Script = load(path)
			var base := scr.get_instance_base_type()
			if base != "" and not node.is_class(base):
				msg += "\nНе прикреплён: скрипт extends %s, а узел %s" % [base, node.get_class()]
			else:
				var ur := _ur()
				ur.create_action("MCP: скрипт на " + str(node.name), UndoRedo.MERGE_DISABLE, _root())
				ur.add_do_method(node, "set_script", scr)
				ur.add_undo_method(node, "set_script", node.get_script())
				ur.commit_action()
				msg += "\nПрикреплён к " + _rel(node)
		else:
			msg += "\nНе прикреплён, пока есть ошибки"
	return {"text": msg, "error": not res.valid}


func _t_script_edit(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	var path: String = r.path
	if not FileAccess.file_exists(path):
		return _err("файл не найден: %s. Для нового файла используйте script_write" % path)
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	var new_text := _clean_code(str(args.get("new_text", "")))
	var result := ""
	var where := ""
	if args.has("start_line"):
		var s: int = int(args.start_line)
		var e: int = int(args.get("end_line", s))
		if s < 1 or s > lines.size() + 1 or e < s - 1 or e > lines.size():
			return _err("строки %d-%d вне файла (в нём %d строк)" % [s, e, lines.size()])
		var before := lines.slice(0, s - 1)
		var after := lines.slice(e)
		var mid := PackedStringArray()
		if new_text != "":
			mid = new_text.split("\n")
		var all := PackedStringArray()
		all.append_array(before)
		all.append_array(mid)
		all.append_array(after)
		result = "\n".join(all)
		where = "строки %d-%d заменены на %d строк" % [s, e, mid.size()]
	elif args.has("old_text") and str(args.old_text) != "" and _count_exact(text, str(args.old_text).replace("\r\n", "\n")) > 0:
		# Точное совпадение подстроки (в том числе кусок строки: items[3] -> items[2]).
		var old := str(args.old_text).replace("\r\n", "\n")
		var n := _count_exact(text, old)
		if n > 1:
			return _err("old_text встречается %d раз. Добавьте соседний текст, чтобы он был уникальным, или используйте start_line" % n)
		var at := text.find(old)
		var first_line := text.substr(0, at).count("\n") + 1
		var raw_new := str(args.get("new_text", "")).replace("\r\n", "\n")
		result = text.substr(0, at) + raw_new + text.substr(at + old.length())
		where = "замена в строке %d" % first_line if not old.contains("\n") else "замена со строки %d" % first_line
	elif args.has("old_text") and str(args.old_text) != "":
		var m := _match_span(lines, _clean_code(str(args.old_text)))
		if m.has("error"):
			return _err(m.error)
		var indent_new := _reindent(new_text, m.indent_file, m.indent_given)
		var before2 := lines.slice(0, m.start)
		var after2 := lines.slice(m.end + 1)
		var all2 := PackedStringArray()
		all2.append_array(before2)
		if indent_new != "":
			all2.append_array(indent_new.split("\n"))
		all2.append_array(after2)
		result = "\n".join(all2)
		where = "заменены строки %d-%d" % [m.start + 1, m.end + 1]
	else:
		return _err("укажите start_line (и end_line) или old_text")
	var res := _save_script(path, result)
	if res.has("error"):
		return _err(res.error)
	return {"text": "%s: %s\n%s" % [path, where, res.check], "error": not res.valid}


static func _count_exact(text: String, needle: String) -> int:
	if needle == "":
		return 0
	return text.count(needle)


## Ищет фрагмент построчно, сравнивая строки без учёта ведущих пробелов/табов.
## Возвращает {start, end, indent_file, indent_given} (индексы строк с 0) или {error}.
func _match_span(lines: PackedStringArray, needle: String) -> Dictionary:
	var want: Array = []
	for l in needle.split("\n"):
		want.append(l)
	while not want.is_empty() and want[0].strip_edges() == "":
		want.pop_front()
	while not want.is_empty() and want[-1].strip_edges() == "":
		want.pop_back()
	if want.is_empty():
		return {"error": "old_text пустой"}
	var hits: Array = []
	for i in range(0, lines.size() - want.size() + 1):
		var ok := true
		for j in want.size():
			if lines[i + j].strip_edges() != str(want[j]).strip_edges():
				ok = false
				break
		if ok:
			hits.append(i)
	if hits.is_empty():
		# Подсказка: где встречается первая строка фрагмента.
		var first := str(want[0]).strip_edges()
		var near: Array = []
		for i in lines.size():
			if first.length() > 3 and lines[i].strip_edges().contains(first.substr(0, min(first.length(), 25))):
				near.append(str(i + 1))
		var tip := ("похожее начало в строках " + ", ".join(near.slice(0, 5))) if not near.is_empty() else "прочитайте файл через script_read"
		return {"error": "old_text не найден (%s). Можно заменить по номерам строк через start_line/end_line" % tip}
	if hits.size() > 1:
		var where: Array = []
		for h in hits:
			where.append(str(h + 1))
		return {"error": "old_text встречается %d раз (строки %s). Добавьте соседние строки или используйте start_line" % [hits.size(), ", ".join(where.slice(0, 8))]}
	var start: int = hits[0]
	return {
		"start": start,
		"end": start + want.size() - 1,
		"indent_file": _leading_ws(lines[start]),
		"indent_given": _leading_ws(str(want[0])),
	}


static func _leading_ws(s: String) -> String:
	var i := 0
	while i < s.length() and (s[i] == " " or s[i] == "\t"):
		i += 1
	return s.substr(0, i)


## Переносит отступ: если модель прислала фрагмент с другим базовым отступом
## (или пробелами вместо табов), выравниваем по файлу.
func _reindent(text: String, indent_file: String, indent_given: String) -> String:
	if text == "":
		return ""
	var unit_file := "\t" if indent_file.contains("\t") or indent_file == "" else "    "
	var out: Array = []
	for l in text.split("\n"):
		if l.strip_edges() == "":
			out.append("")
			continue
		var ws := _leading_ws(l)
		var body := l.substr(ws.length())
		var rel := ws.trim_prefix(indent_given) if ws.begins_with(indent_given) else ws
		# пробелы -> табы, если файл на табах
		if unit_file == "\t":
			rel = rel.replace("    ", "\t")
		out.append(indent_file + rel + body)
	return "\n".join(out)


## Снимает обёртку ```gdscript ... ```, которую модели часто добавляют.
static func _clean_code(s: String) -> String:
	var t := s.replace("\r\n", "\n")
	var stripped := t.strip_edges()
	if stripped.begins_with("```"):
		var nl := stripped.find("\n")
		if nl > 0 and stripped.ends_with("```"):
			return stripped.substr(nl + 1, stripped.length() - nl - 4).trim_suffix("\n") + "\n"
	return t


## Пишет файл, проверяет GDScript, обновляет редактор.
## Возвращает {valid: bool, check: String} или {error}.
func _save_script(path: String, content: String) -> Dictionary:
	if not path.get_extension() in ["gd", "gdshader", "cs", "txt", "md", "json", "cfg", "tres", "gdshaderinc"]:
		return {"error": "можно писать только текстовые файлы (.gd, .gdshader, .cs, .json, .txt ...)"}
	var check := {"valid": true, "check": "Проверка: не GDScript, синтаксис не проверялся"}
	if path.get_extension() == "gd":
		check = _check_gdscript(content)
	_ensure_dir(path)
	var old_text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "не удалось записать %s (код %d)" % [path, FileAccess.get_open_error()]}
	f.store_string(content)
	f.close()
	_fs_update(path)
	_sync_open_editors(old_text, content)
	if path.get_extension() == "gd" and ResourceLoader.has_cached(path):
		var scr: Script = load(path)
		scr.source_code = content
		if check.valid:
			scr.reload(true)
	return check


## Если файл открыт во встроенном редакторе скриптов (например, его открыл отладчик после ошибки),
## в буфере остаётся старый текст, и при следующем запуске игры редактор сохранит его поверх нашей правки.
## Обновляем такие буферы. Буфер с несохранёнными правками пользователя не трогаем: его текст
## отличается от старого содержимого файла.
func _sync_open_editors(old_text: String, new_text: String) -> void:
	if old_text == "" or old_text == new_text:
		return
	var se := EditorInterface.get_script_editor()
	if se == null:
		return
	var old_norm := old_text.replace("\r\n", "\n").strip_edges(false, true)
	for ed in se.get_open_script_editors():
		var ce = ed.get_base_editor()
		if not (ce is TextEdit):
			continue
		var te: TextEdit = ce
		if te.text.replace("\r\n", "\n").strip_edges(false, true) != old_norm:
			continue
		var line := te.get_caret_line()
		te.text = new_text
		te.tag_saved_version()
		te.set_caret_line(mini(line, te.get_line_count() - 1))


func _check_gdscript(content: String) -> Dictionary:
	var scr := GDScript.new()
	# class_name в безымянном скрипте конфликтует с уже зарегистрированным классом,
	# поэтому для проверки комментируем его (номера строк сохраняются).
	var rx := RegEx.create_from_string("(?m)^class_name\\b")
	scr.source_code = rx.sub(content, "#class_name", true)
	var mark: int = _logger.mark() if _logger else 0
	var err := scr.reload()
	if err == OK:
		return {"valid": true, "check": "Проверка: ошибок нет"}
	var details: Array = []
	if _logger:
		for l in _logger.since(mark):
			details.append("  " + _clean_err(l))
	if details.is_empty():
		details.append("  подробности в панели Output редактора (на Godot 4.5+ они приходят сюда)")
	return {"valid": false, "check": "Проверка: ОШИБКИ\n" + "\n".join(details.slice(0, 10))}


static func _clean_err(l: String) -> String:
	var rx := RegEx.create_from_string("\\s*\\(gdscript://[^:]*:(\\d+)\\)")
	var m := rx.search(l)
	var out := l.replace("SCRIPT ERROR: ", "")
	if m:
		out = "строка %s: %s" % [m.get_string(1), rx.sub(out, "")]
	return out


# ─────────────────────────── инструменты: игра ───────────────────────────

func _t_game_run(args: Dictionary) -> Dictionary:
	var scene := str(args.get("scene", "main")).strip_edges()
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	_last_run_ms = Time.get_ticks_msec()
	if _logger:
		_logger.clear()
	match scene:
		"", "main":
			var main := str(ProjectSettings.get_setting("application/run/main_scene", ""))
			if main == "":
				return _err("главная сцена проекта не задана. Запустите scene=\"current\" или укажите путь res://...tscn")
			EditorInterface.play_main_scene()
			return _ok("Запущена главная сцена %s. Через пару секунд вызовите game_output" % main)
		"current":
			var root := _root()
			if root == null:
				return _no_scene()
			if root.scene_file_path != "":
				EditorInterface.save_scene()
			EditorInterface.play_current_scene()
			return _ok("Запущена текущая сцена %s. Через пару секунд вызовите game_output" % root.scene_file_path)
		_:
			var r := _res_path(scene)
			if r.has("error"):
				return _err(r.error)
			if not ResourceLoader.exists(r.path):
				return _err("сцена не найдена: " + r.path)
			EditorInterface.play_custom_scene(r.path)
			return _ok("Запущена %s. Через пару секунд вызовите game_output" % r.path)


func _t_game_stop(_args: Dictionary) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return _ok("Игра не запущена")
	EditorInterface.stop_playing_scene()
	return _ok("Игра остановлена")


func _t_game_output(args: Dictionary) -> Dictionary:
	var errors_only := bool(args.get("errors_only", false))
	var max_lines: int = clampi(int(args.get("lines", 60)), 5, MAX_OUTPUT_LINES)
	var out: Array = []
	out.append("Игра: " + ("запущена" if EditorInterface.is_playing_scene() else "не запущена"))
	var log_path := OS.get_user_data_dir().path_join("logs/godot.log")
	var game_lines: Array = []
	var hidden := 0
	if _last_run_ms == 0:
		game_lines.append("(игра в этой сессии не запускалась, вызовите game_run)")
	else:
		# Пока игра идёт, читаем живые источники редактора: панель Output (print) и вкладку
		# Errors отладчика. На Windows файл лога игры до её остановки может быть недоступен.
		var raw := PackedStringArray()
		if EditorInterface.is_playing_scene():
			raw = _live_game_output()
		if raw.is_empty() and FileAccess.file_exists(log_path):
			raw = FileAccess.get_file_as_string(log_path).split("\n")
		if raw.is_empty() and not EditorInterface.is_playing_scene() and not FileAccess.file_exists(log_path):
			game_lines.append("(лог не найден: включите debug/file_logging/enable_file_logging в настройках проекта)")
		else:
			var parsed := _filter_log(raw, errors_only)
			game_lines = parsed.lines
			hidden = parsed.hidden
	if game_lines.size() > max_lines:
		game_lines = ["…пропущено %d строк" % (game_lines.size() - max_lines)] + game_lines.slice(game_lines.size() - max_lines)
	out.append("Вывод игры:" if not game_lines.is_empty() else ("Вывод игры: ошибок нет" if errors_only else "Вывод игры: пусто"))
	out.append_array(game_lines)
	if hidden > 0:
		out.append("(скрыто %d служебных сообщений движка: драйверы, звук, дисплей)" % hidden)
	if EditorInterface.is_playing_scene():
		var frame := _debugger_break_frame()
		if frame != "":
			out.append("Игра стоит на паузе: отладчик остановил её на ошибке (%s). Ждать бесполезно: исправьте код и вызовите game_run заново (или game_stop)." % frame)
	if _logger:
		var ed := _filter_log(PackedStringArray(_logger.since(0)), true)
		if not ed.lines.is_empty():
			out.append("Ошибки редактора:")
			out.append_array(ed.lines.slice(max(0, ed.lines.size() - 20)))
	return _ok("\n".join(out))


## Вывод текущего запуска из редактора, в формате файла лога:
## print-строки из панели Output и ошибки с вкладки Errors отладчика.
func _live_game_output() -> PackedStringArray:
	var out := PackedStringArray()
	var panel := _editor_output_text().split("\n")
	var start := 0
	for i in panel.size():
		if panel[i].begins_with("Godot Engine v"):
			start = i + 1
	for i in range(start, panel.size()):
		var l: String = panel[i]
		# Строки с отступом и ERROR/WARNING в панели пишет сам редактор, а не игра.
		if l.begins_with("  ERROR:") or l.begins_with("  WARNING:") or l.begins_with("OpenGL API") or l.begins_with("Vulkan "):
			continue
		out.append(l)
	out.append_array(_debugger_errors())
	return out


## Ошибки текущей сессии с вкладки Errors отладчика.
func _debugger_errors() -> PackedStringArray:
	var out := PackedStringArray()
	var base := EditorInterface.get_base_control()
	if base == null:
		return out
	var warn_icon: Texture2D = null
	var theme := EditorInterface.get_editor_theme()
	if theme and theme.has_icon("Warning", "EditorIcons"):
		warn_icon = theme.get_icon("Warning", "EditorIcons")
	var src_rx := RegEx.create_from_string("[\\w./-]+\\.\\w+:\\d+")
	for d in base.find_children("*", "ScriptEditorDebugger", true, false):
		for t in (d as Node).find_children("*", "Tree", true, false):
			var tr: Tree = t
			if not _is_error_tree(tr):
				continue
			var it := tr.get_root().get_first_child()
			while it:
				var msg := it.get_text(1)
				var marker := msg.find("(): ")
				var colon := msg.find(": ")
				if marker > 0 and msg.substr(0, marker).contains(" @ "):
					msg = msg.substr(marker + 4)  # "m2.gd:7 @ _ready(): текст" -> "текст"
				elif colon > 0 and not msg.substr(0, colon).contains(" "):
					msg = msg.substr(colon + 2)  # "_ready: текст" -> "текст"
				var warning := warn_icon != null and it.get_icon(0) == warn_icon
				var where := ""
				var is_script := false
				var meta = it.get_metadata(0)
				if meta is Array and meta.size() >= 2 and str(meta[0]).begins_with("res://"):
					# В метаданных полный путь к скрипту и строка.
					is_script = true
					where = "%s:%d" % [meta[0], int(meta[1])]
				else:
					var kid := it.get_first_child()
					while kid:
						if src_rx.search(kid.get_text(1)):
							where = kid.get_text(1)
						kid = kid.get_next()
				var kind := ("SCRIPT " if is_script else "") + ("WARNING: " if warning else "ERROR: ")
				out.append(kind + msg)
				if where != "":
					out.append("   at: " + where)
				it = it.get_next()
	return out


## Если отладчик остановил игру на ошибке, возвращает верхний кадр стека ("res://main.gd:6 @ _ready").
func _debugger_break_frame() -> String:
	var base := EditorInterface.get_base_control()
	if base == null:
		return ""
	var rx := RegEx.create_from_string("^\\d+ - (res://[^ ]+:\\d+)(?: - [^:]+: (\\S+))?")
	for d in base.find_children("*", "ScriptEditorDebugger", true, false):
		for t in (d as Node).find_children("*", "Tree", true, false):
			var tr: Tree = t
			if tr.columns != 1 or tr.get_root() == null or tr.get_root().get_first_child() == null:
				continue
			var m := rx.search(tr.get_root().get_first_child().get_text(0))
			if m:
				return m.get_string(1) + ((" @ " + m.get_string(2)) if m.get_string(2) != "" else "")
	return ""


## Дерево вкладки ошибок отладчика. Имя вкладки переведено на язык редактора («Errors», «Ошибки»),
## поэтому узнаём его по содержимому: 2 колонки, в первой время вида 0:00:01:234.
static func _is_error_tree(tr: Tree) -> bool:
	if tr.columns != 2 or tr.get_root() == null:
		return false
	var first := tr.get_root().get_first_child()
	if first == null:
		return false
	return RegEx.create_from_string("^\\d+:\\d\\d:\\d\\d:\\d\\d\\d$").search(first.get_text(0)) != null


## Текст панели Output редактора (туда отладчик пишет вывод запущенной игры).
## Нужен, когда файл лога игры недоступен для чтения (Windows держит его, пока игра работает).
func _editor_output_text() -> String:
	var base := EditorInterface.get_base_control()
	if base == null:
		return ""
	var logs := base.find_children("*", "EditorLog", true, false)
	if logs.is_empty():
		return ""
	var rtls := (logs[0] as Node).find_children("*", "RichTextLabel", true, false)
	if rtls.is_empty():
		return ""
	return (rtls[0] as RichTextLabel).get_parsed_text()


## Делит лог на записи (строка + её отступленные продолжения) и убирает шум движка.
## Ошибку оставляем, если это ошибка скрипта/пользователя или она ссылается на res://.
func _filter_log(raw: PackedStringArray, errors_only: bool) -> Dictionary:
	var entries: Array = []
	for l in raw:
		if l.strip_edges() == "":
			continue
		if (l.begins_with(" ") or l.begins_with("\t")) and not entries.is_empty():
			entries[-1].append(l)
		else:
			entries.append([l])
	var lines: Array = []
	var hidden := 0
	for e in entries:
		var head: String = e[0]
		if head.begins_with("Godot Engine v") or head.begins_with("OpenGL API") or head.begins_with("Vulkan "):
			continue
		var is_msg := head.begins_with("ERROR") or head.begins_with("WARNING") or head.contains("SCRIPT ERROR") \
			or head.contains("USER ERROR") or head.contains("SCRIPT WARNING") or head.contains("USER WARNING")
		if not is_msg:
			if not errors_only:
				lines.append_array(e)
			continue
		var text := "\n".join(e)
		var mine := head.contains("SCRIPT") or head.contains("USER") or text.contains("res://")
		if not mine:
			hidden += 1
			continue
		# Backtrace GDScript дублирует строку "at:", оставляем сообщение и место.
		lines.append_array(e.slice(0, 2))
	return {"lines": lines, "hidden": hidden}


# ─────────────────────────── инструменты: справка ───────────────────────────

func _t_class_info(args: Dictionary) -> Dictionary:
	var cls := str(args.type).strip_edges()
	if not ClassDB.class_exists(cls):
		var gp := _global_class_path(cls)
		if gp != "":
			return _err("%s это class_name из %s. Прочитайте скрипт через script_read" % [cls, gp])
		var sim := _similar(Array(ClassDB.get_class_list()), cls, 8)
		return _err("нет класса \"%s\"%s" % [cls, (". Похожие: " + ", ".join(sim)) if not sim.is_empty() else ""])
	var filter := str(args.get("filter", "")).strip_edges()
	var chain: Array = [cls]
	var p := ClassDB.get_parent_class(cls)
	while p != "":
		chain.append(p)
		p = ClassDB.get_parent_class(p)
	var lines: Array = ["%s: %s" % [cls, " < ".join(chain.slice(1))]]
	# Без фильтра показываем только собственные члены класса, с фильтром ищем по всей цепочке.
	var classes: Array = [cls] if filter == "" else chain
	var props: Array = []
	var methods: Array = []
	var signals: Array = []
	for c in classes:
		var accessors := {}
		for pr in ClassDB.class_get_property_list(c, true):
			accessors[ClassDB.class_get_property_setter(c, pr.name)] = true
			accessors[ClassDB.class_get_property_getter(c, pr.name)] = true
		for pr in ClassDB.class_get_property_list(c, true):
			if pr.usage & PROPERTY_USAGE_EDITOR and (filter == "" or str(pr.name).containsn(filter)):
				var hint := ""
				if pr.hint == PROPERTY_HINT_ENUM:
					hint = " {" + str(pr.hint_string) + "}"
				props.append("  %s: %s%s%s" % [pr.name, _type_name(pr), hint, (" (" + c + ")") if c != cls else ""])
		for m in ClassDB.class_get_method_list(c, true):
			var mn: String = m.name
			if mn.begins_with("_") and not (m.flags & METHOD_FLAG_VIRTUAL):
				continue
			if accessors.has(StringName(mn)) and filter == "":
				continue  # сеттеры/геттеры: свойства уже показаны выше
			if filter != "" and not mn.containsn(filter):
				continue
			var a: Array = []
			for arg in m.args:
				a.append("%s: %s" % [arg.name, _type_name(arg)])
			methods.append("  %s(%s) -> %s%s" % [mn, ", ".join(a), _type_name(m["return"]), (" (" + c + ")") if c != cls else ""])
		for s in ClassDB.class_get_signal_list(c, true):
			if filter == "" or str(s.name).containsn(filter):
				var sa: Array = []
				for arg in s.args:
					sa.append(arg.name)
				signals.append("  %s(%s)" % [s.name, ", ".join(sa)])
	if not props.is_empty():
		lines.append("Свойства:")
		lines.append_array(props.slice(0, 50))
	if not signals.is_empty():
		lines.append("Сигналы:")
		lines.append_array(signals.slice(0, 30))
	if not methods.is_empty():
		lines.append("Методы:")
		lines.append_array(methods.slice(0, 50))
	if props.size() + methods.size() + signals.size() == 0:
		lines.append("Ничего не найдено" + (" по фильтру \"%s\"" % filter if filter != "" else ""))
	elif filter == "":
		lines.append("(только члены %s; унаследованные ищите через filter)" % cls)
	return _ok("\n".join(lines))


static func _type_name(info: Dictionary) -> String:
	var t: int = info.get("type", TYPE_NIL)
	if t == TYPE_OBJECT and str(info.get("class_name", "")) != "":
		return str(info.class_name)
	if t == TYPE_NIL:
		return "void" if not (int(info.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT) else "Variant"
	return type_string(t)
