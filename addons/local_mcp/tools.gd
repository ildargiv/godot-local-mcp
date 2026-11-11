@tool
extends RefCounted

const L := preload("res://addons/local_mcp/lang.gd")
## Core tool set. Principles:
## - flat schemas, short descriptions (~100-150 tokens per tool);
## - forgiving argument parsing (name aliases, values in any reasonable format);
## - short text replies; an error is one line: "what is wrong + how to fix it";
## - every scene edit goes through UndoRedo, so the user can revert it with Ctrl+Z.

const Values := preload("res://addons/local_mcp/values.gd")

const MAX_SCRIPT_READ := 400  # lines per script_read call
const MAX_TREE_LINES := 250
const MAX_OUTPUT_LINES := 200

## Argument aliases: local models often name fields their own way.
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

## Optional groups: name -> script. Enabled in Project Settings local_mcp/groups/<name>
## or with the env variable LOCAL_MCP_GROUPS="tilemap,animation" (handy for the bench).
const GROUPS := {
	"tilemap": "res://addons/local_mcp/groups/tilemap.gd",
	"animation": "res://addons/local_mcp/groups/animation.gd",
}

var _plugin: EditorPlugin
var _groups := {}  # name -> group object
var _logger: Object = null
var _defs: Array = []
var _last_run_ms := 0
var _class_scan := {}  # class_name -> path from reading .gd files; cleared on every script write


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


# ─────────────────────────── tool definitions ───────────────────────────

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


## Enabled groups. Read on every tools/list: after ticking a box, reconnect the client.
func enabled_groups() -> Array:
	var out: Array = []
	var env := OS.get_environment("LOCAL_MCP_GROUPS").to_lower()
	for g in _groups:
		if env.contains(g) or env == "all" or bool(ProjectSettings.get_setting("local_mcp/groups/" + g, false)):
			out.append(g)
	return out


# ─────────────────────────── dispatcher ───────────────────────────

func call_tool(name: String, raw_args: Dictionary) -> Dictionary:
	L.refresh()
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
					return _err(L.t("tool %s belongs to group \"%s\", which is disabled. Enable local_mcp/groups/%s in Project Settings and reconnect the client") % [name, g, g])
		var names: Array = []
		for d in all_defs:
			names.append(d.name)
		return _err(L.t("no tool \"%s\". Available: %s") % [name, ", ".join(names)])
	var args := _normalize_args(raw_args, def.inputSchema.properties)
	for req in def.inputSchema.required:
		if not args.has(req) or (args[req] is String and args[req] == "" and req != "new_text" and req != "content"):
			return _err(L.t("missing argument \"%s\" (required: %s)") % [req, ", ".join(def.inputSchema.required)])
	var fn := "_t_" + name
	var target: Object = self if has_method(fn) else null
	if target == null:
		for g in _groups:
			if _groups[g].has_method(fn):
				target = _groups[g]
	if target == null:
		return _err(L.t("tool not implemented: ") + name)
	# GDScript has no try/catch: on a runtime error call() returns null, and the model used to
	# get an empty "success". Now it is an explicit error with the text from the log.
	var mark: int = _logger.mark() if _logger else 0
	var res = target.call(fn, args)
	if res is Dictionary and res.has("text"):
		return res
	var why: Array = []
	if _logger:
		for l in _logger.since(mark):
			why.append(_clean_err(l))
	return _err(L.t("internal error in tool %s%s. Try other arguments; if it keeps happening, it is a plugin bug") % [
		name, (": " + "; ".join(why.slice(0, 3))) if not why.is_empty() else ""])


## Renames aliases to canonical names, coerces numbers and booleans.
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
	# Coerce by schema type: models send "True", "1", "[32, 32]" as strings.
	for k in out.keys():
		if not schema_props.has(k):
			continue
		var want: String = str(schema_props[k].get("type", ""))
		var v = out[k]
		match want:
			"boolean":
				if v is String:
					out[k] = (v as String).strip_edges().to_lower() in ["true", "1", "yes", "y", "on", "да", "sí", "si", "ja", "oui", "sim", "是", "はい"]
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
	return {"text": L.t("Error: ") + text, "error": true}


# ─────────────────────────── shared helpers ───────────────────────────

func _root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _ur() -> EditorUndoRedoManager:
	return _plugin.get_undo_redo()


func _no_scene() -> Dictionary:
	return _err(L.t("no scene is open. Open one with scene_open or create one with scene_new"))


func _rel(node: Node) -> String:
	var root := _root()
	if node == root:
		return "."
	return str(root.get_path_to(node))


## For messages: show the root by name, not as a dot.
func _label(node: Node) -> String:
	return str(node.name) if node == _root() else _rel(node)


## Finds a node by a lenient path: ".", the root name, "./A/B", "Root/A/B", "/root/Root/A".
## Returns {"node": Node} or {"error": "..."} with a hint about nearby nodes.
func _find(path) -> Dictionary:
	var root := _root()
	if root == null:
		return {"error": _no_scene().text.trim_prefix(L.t("Error: "))}
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
	# A unique name somewhere deeper?
	var by_name := root.find_children(p.get_file(), "", true, false)
	if by_name.size() == 1 and not p.contains("/"):
		return {"node": by_name[0]}
	# Hint: children of the nearest existing ancestor.
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
	var near := L.t("\"%s\" has no children") % _rel(cur) if kids.is_empty() else L.t("children of \"%s\": %s") % [_rel(cur), ", ".join(kids.slice(0, 20))]
	return {"error": L.t("node \"%s\" not found; %s") % [str(path), near]}


func _res_path(p) -> Dictionary:
	var s := str(p if p != null else "").strip_edges().replace("\\", "/")
	if s == "":
		return {"error": L.t("empty path")}
	if not s.begins_with("res://"):
		s = "res://" + s.trim_prefix("/")
	if s.contains("/../") or s.ends_with("/..") or s.begins_with("res://.."):
		return {"error": L.t("path cannot leave the project")}
	if s.begins_with("res://addons/local_mcp/") or s.begins_with("res://.godot/"):
		return {"error": L.t("this folder is protected")}
	return {"path": s}


func _ensure_dir(res_path: String) -> void:
	var dir := res_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)


func _fs_update(path: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs:
		fs.update_file(path)


## Finds similar property names for a hint.
static func _similar_props(obj: Object, wanted: String) -> String:
	var names: Array = []
	for p in obj.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR:
			names.append(str(p.name))
	return ", ".join(_similar(names, wanted, 6))


## Closest strings by spelling (model typos: positon, Charakter).
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


## camelCase -> snake_case, a common model mistake ("modulateColor", "zIndex").
static func _snake(s: String) -> String:
	return s.to_snake_case() if s != s.to_lower() else s


## Adds the property changes to the open UndoRedo action.
## Returns [planned: Array, failed: Array[String]]; planned items are {prop, value, old}.
## Call _verify_props after commit_action: only it knows what really got applied.
func _set_props(node: Node, props: Dictionary, ur: EditorUndoRedoManager) -> Array:
	var planned: Array = []
	var failed: Array = []
	for key in props:
		var prop := str(key)
		if not Values.has_property(node, prop) and Values.has_property(node, _snake(prop)):
			prop = _snake(prop)
		if prop == "script":
			failed.append(L.t("script: use script_write with attach_to, or node_add"))
			continue
		if not Values.has_property(node, prop):
			var sim := _similar_props(node, prop)
			failed.append(L.t("%s: %s has no such property%s") % [prop, node.get_class(), (L.t(" (similar: ") + sim + ")") if sim != "" else ""])
			continue
		var c := Values.coerce_for(node, prop, props[key])
		if not c.ok:
			failed.append("%s: %s" % [prop, c.error])
			continue
		var old = _get_prop(node, prop)
		if prop.contains(":"):
			ur.add_do_method(node, "set_indexed", NodePath(prop), c.value)
			ur.add_undo_method(node, "set_indexed", NodePath(prop), old)
		else:
			ur.add_do_property(node, prop, c.value)
			ur.add_undo_property(node, prop, old)
		if c.value is Resource:
			ur.add_do_reference(c.value)
		planned.append({"prop": prop, "value": c.value, "old": old})
	return [planned, failed]


static func _get_prop(obj: Object, prop: String):
	return obj.get_indexed(NodePath(prop)) if prop.contains(":") else obj.get(prop)


## Reads every planned property back after commit_action and compares it with the intent.
## The engine fails silently on a wrong sub-property ("position:z"), a read-only property
## or a setter that rejects the value, so without this the model got a "success".
## Returns [applied: Array[String], failed: Array[String], notes: Array[String]].
func _verify_props(node: Node, planned: Array) -> Array:
	var applied: Array = []
	var failed: Array = []
	var notes: Array = []
	for item in planned:
		var prop: String = item.prop
		var now = _get_prop(node, prop)
		if _same(now, item.value):
			applied.append(prop)
		elif _same(now, item.old):
			failed.append("%s: %s" % [prop, _not_applied_hint(node, prop)])
		else:
			applied.append(prop)
			notes.append(L.t("%s: the engine stored %s instead of %s") % [prop, _show_prop(node, prop, now), Values.show(item.value)])
	return [applied, failed, notes]


## Why a value did not stick. For "position:z" on a Vector2 lists the parts it does have.
func _not_applied_hint(node: Node, prop: String) -> String:
	if prop.contains(":"):
		var base := prop.get_slice(":", 0)
		var parts := {TYPE_VECTOR2: "x, y", TYPE_VECTOR2I: "x, y", TYPE_VECTOR3: "x, y, z", TYPE_VECTOR3I: "x, y, z",
			TYPE_VECTOR4: "x, y, z, w", TYPE_VECTOR4I: "x, y, z, w", TYPE_COLOR: "r, g, b, a",
			TYPE_RECT2: "position, size", TYPE_RECT2I: "position, size"}
		var t := typeof(node.get(base))
		if prop.get_slice_count(":") == 2 and parts.has(t):
			return L.t("value not applied: %s is %s, its parts are %s") % [base, type_string(t), parts[t]]
		return L.t("value not applied: no such sub-property")
	return L.t("value not applied: the property is read-only or rejected the value")


## Equality for verification: numbers and vectors approximately, String == StringName.
static func _same(a, b) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if (a is String or a is StringName) and (b is String or b is StringName):
		return str(a) == str(b)
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_RECT2, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_QUATERNION, TYPE_BASIS, TYPE_PLANE, TYPE_AABB:
			return a.is_equal_approx(b)
	return a == b


func _report_props(node: Node, applied: Array) -> String:
	var parts: Array = []
	for prop in applied:
		parts.append("%s=%s" % [prop, _show_prop(node, prop, _get_prop(node, str(prop)))])
	return ", ".join(parts)


## Sets properties in one UndoRedo step and verifies them.
## Returns {applied, failed, tail}: tail is the "Not applied"/"Note" text to append to a reply.
func _apply_props(node: Node, props: Dictionary) -> Dictionary:
	var ur := _ur()
	ur.create_action(L.t("MCP: properties ") + str(node.name), UndoRedo.MERGE_DISABLE, _root())
	var res := _set_props(node, props, ur)
	ur.commit_action()
	var v := _verify_props(node, res[0])
	var failed: Array = res[1] + v[1]
	var tail := ""
	if not failed.is_empty():
		tail += L.t("\nNot applied: ") + "; ".join(failed)
	if not v[2].is_empty():
		tail += L.t("\nNote: ") + "; ".join(v[2])
	return {"applied": v[0], "failed": failed, "tail": tail}


## Property value for a reply; enums are shown by name.
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


## The instanced scene a node comes from, if the node is part of an instance's insides
## (its owner is the instance root, not the open scene). Godot saves only property overrides
## for such nodes: deleting, renaming or moving them is lost on save. null = the scene owns it.
func _instance_of(node: Node) -> Node:
	var root := _root()
	if node == root or node.owner == null or node.owner == root:
		return null
	return node.owner


## Error for a structural change inside an instance, or "" if the change is fine.
## editable_ok: the change is saved when Editable Children is on (adding a child, a signal).
func _instance_guard(node: Node, editable_ok := false) -> String:
	var inst := _instance_of(node)
	if inst == null or (editable_ok and _root().is_editable_instance(inst)):
		return ""
	var src := inst.scene_file_path if inst.scene_file_path != "" else str(inst.name)
	return L.t("%s is part of the instanced scene %s (node %s). Godot does not save structural changes inside an instance: edit %s itself (scene_open), or change only properties with node_set") % [
		_rel(node), src, _rel(inst), src]


## Subtree nodes owned by the scene (needed to restore owner after undo).
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


# ─────────────────────────── tools: project and scene ───────────────────────────

func _t_project_info(args: Dictionary) -> Dictionary:
	var lines: Array = []
	lines.append(L.t("Project: %s") % ProjectSettings.get_setting("application/config/name", "?"))
	var v := Engine.get_version_info()
	lines.append("Godot: %d.%d.%d" % [v.major, v.minor, v.patch])
	lines.append(L.t("Main scene: %s") % (ProjectSettings.get_setting("application/run/main_scene", "") if ProjectSettings.get_setting("application/run/main_scene", "") != "" else L.t("not set")))
	var root := _root()
	lines.append(L.t("Open scene: %s") % (root.scene_file_path if root and root.scene_file_path != "" else (L.t("unsaved") if root else L.t("none"))))
	var autoloads: Array = []
	for prop in ProjectSettings.get_property_list():
		var n: String = prop.name
		if n.begins_with("autoload/"):
			autoloads.append(n.substr(9))
	if not autoloads.is_empty():
		lines.append(L.t("Autoloads: ") + ", ".join(autoloads))
	var filter: String = str(args.get("filter", ""))
	var files: Array = []
	_collect_files("res://", files, filter)
	files.sort()
	lines.append(L.t("Files (%d):") % files.size())
	for f in files.slice(0, 200):
		lines.append("  " + f)
	if files.size() > 200:
		lines.append(L.t("  …and %d more, narrow it with filter") % (files.size() - 200))
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
	var header := L.t("Scene %s") % (root.scene_file_path if root.scene_file_path != "" else L.t("(not saved)"))
	if lines.size() > MAX_TREE_LINES:
		var extra := lines.size() - MAX_TREE_LINES
		lines = lines.slice(0, MAX_TREE_LINES)
		lines.append(L.t("…%d more nodes, use path or depth") % extra)
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
	if level >= max_depth:
		if node.get_child_count() > 0:
			out.append("  ".repeat(level + 1) + L.t("…%d children") % node.get_child_count())
		return
	# The insides of a scene instance are not expanded (they belong to the other scene),
	# but children added to the instance in this scene are shown.
	var is_instance := node != _root() and node.scene_file_path != ""
	for c in node.get_children():
		if c.owner == null and c != _root():
			continue  # internal editor nodes
		if is_instance and c.owner != _root():
			continue
		_tree_lines(c, level + 1, max_depth, out)


func _t_scene_open(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	if not ResourceLoader.exists(r.path):
		return _err(L.t("scene not found: %s. Create it with scene_new") % r.path)
	EditorInterface.open_scene_from_path(r.path)
	return _ok(L.t("Opened %s") % r.path)


func _t_scene_new(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	var path: String = r.path
	if path.get_extension() != "tscn":
		path = path.get_basename() + ".tscn"
	if FileAccess.file_exists(path):
		return _err(L.t("file %s already exists. Open it with scene_open") % path)
	var type: String = str(args.get("type", "Node2D"))
	if type == "":
		type = "Node2D"
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node") or not ClassDB.can_instantiate(type):
		return _err(L.t("\"%s\" is not a node class. Examples: Node2D, Node3D, Control, CharacterBody2D") % type)
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
		return _err(L.t("could not save %s (code %d)") % [path, err])
	_fs_update(path)
	EditorInterface.open_scene_from_path(path)
	return _ok(L.t("Created and opened %s, root %s (%s)") % [path, root_name, type])


func _t_scene_save(_args: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _no_scene()
	if root.scene_file_path == "":
		return _err(L.t("scene has never been saved. Create scenes with scene_new"))
	var err := EditorInterface.save_scene()
	if err != OK:
		return _err(L.t("could not save (code %d)") % err)
	return _ok(L.t("Saved: ") + root.scene_file_path)


# ─────────────────────────── tools: nodes ───────────────────────────

func _t_node_add(args: Dictionary) -> Dictionary:
	var root := _root()
	if root == null:
		return _no_scene()
	var pf := _find(args.get("parent", "."))
	if pf.has("error"):
		return _err(L.t("parent: ") + pf.error)
	var parent: Node = pf.node
	var guard := _instance_guard(parent, true)
	if guard != "":
		return _err(guard)
	var type := str(args.type).strip_edges()
	var node: Node = null
	if type.ends_with(".tscn") or type.ends_with(".scn"):
		var r := _res_path(type)
		if r.has("error"):
			return _err(r.error)
		if not ResourceLoader.exists(r.path):
			return _err(L.t("scene not found: ") + r.path)
		var packed: PackedScene = load(r.path)
		if r.path == root.scene_file_path:
			return _err(L.t("cannot instance a scene inside itself"))
		node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	elif ClassDB.class_exists(type):
		if not ClassDB.is_parent_class(type, "Node"):
			return _err(L.t("%s is not a node (it is %s). Set resources with node_set, e.g. {\"shape\": {\"type\": \"%s\"}}") % [type, ClassDB.get_parent_class(type), type])
		if not ClassDB.can_instantiate(type):
			return _err(L.t("%s is an abstract class, pick a subclass") % type)
		node = ClassDB.instantiate(type)
	else:
		var script_path := _global_class_path(type)
		if script_path == "":
			return _err(L.t("unknown type \"%s\". It is not a Godot class, a script class_name or a .tscn") % type)
		var scr: Script = load(script_path)
		var base: StringName = scr.get_instance_base_type() if scr else &""
		if base == &"" or not ClassDB.is_parent_class(base, "Node"):
			return _err(L.t("class %s (%s) cannot be added: the script does not compile or does not extend a node. Check it with script_read") % [type, script_path])
		node = ClassDB.instantiate(base)
		node.set_script(scr)
	var wanted_name := str(args.get("name", ""))
	if wanted_name != "":
		node.name = wanted_name.validate_node_name()
	elif node.name == "" or node.name.begins_with("@"):
		node.name = type.get_file().get_basename() if type.contains("/") else type

	var ur := _ur()
	ur.create_action(L.t("MCP: add ") + str(node.name), UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", node, true)
	ur.add_do_method(node, "set_owner", root)
	ur.add_do_reference(node)
	ur.add_undo_method(parent, "remove_child", node)
	ur.commit_action()

	var msg := L.t("Added %s (%s) to %s") % [_rel(node), node.get_class(), _rel(parent)]
	if wanted_name != "" and str(node.name) != wanted_name.validate_node_name():
		msg += L.t("; the name was taken, got ") + str(node.name)
	var props = args.get("properties", {})
	if props is Dictionary and not props.is_empty():
		var r := _apply_props(node, props)
		if not r.applied.is_empty():
			msg += L.t("\nProperties: ") + _report_props(node, r.applied)
		msg += r.tail
		if not r.failed.is_empty():
			# The node stays (no work is lost), but the reply is an error so the model fixes it.
			msg += L.t("\nThe node was added. Fix the properties with node_set on %s") % _rel(node)
			return {"text": L.t("Error: ") + msg, "error": true}
	return _ok(msg)


func _global_class_path(cls: String) -> String:
	var registered := _registered_class_path(cls)
	if registered != "":
		return registered
	# The editor registers a new class_name only after its file scan, so right after
	# script_write the class is not in the list yet. Fall back to reading the .gd files.
	if _class_scan.is_empty():
		_scan_class_names("res://", _class_scan)
	return str(_class_scan.get(cls, ""))


static func _registered_class_path(cls: String) -> String:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == cls:
			return str(entry.get("path", ""))
	return ""


## class_name declared in the source, or "".
static func _class_name_in(source: String) -> String:
	var m := RegEx.create_from_string("(?m)^(?:@\\w+\\s+)*class_name\\s+([A-Za-z_]\\w*)").search(source)
	return m.get_string(1) if m else ""


## Fills out with {class_name: path} for every .gd file under dir.
func _scan_class_names(dir: String, out: Dictionary) -> void:
	if dir == "res://.godot" or FileAccess.file_exists(dir.path_join(".gdignore")):
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension() == "gd":
			var path := dir.path_join(f)
			var cls := _class_name_in(FileAccess.get_file_as_string(path))
			if cls != "" and not out.has(cls):
				out[cls] = path
	for sub in d.get_directories():
		if not sub.begins_with("."):
			_scan_class_names(dir.path_join(sub), out)


func _t_node_info(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var node: Node = f.node
	var lines: Array = []
	lines.append("%s (%s)" % [_rel(node), node.get_class()])
	var scr: Script = node.get_script()
	if scr:
		lines.append(L.t("Script: ") + (scr.resource_path if scr.resource_path != "" else L.t("built-in")))
	if node.scene_file_path != "" and node != _root():
		lines.append(L.t("Scene instance: ") + node.scene_file_path)
	var inst := _instance_of(node)
	if inst:
		lines.append(L.t("Part of the instance %s (%s): only properties can be changed here") % [_rel(inst), inst.scene_file_path])
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
	lines.append(L.t("Changed properties:") if not changed.is_empty() else L.t("No changed properties"))
	lines.append_array(changed.slice(0, 60))
	var conns: Array = []
	for sig in node.get_signal_list():
		for c in node.get_signal_connection_list(sig.name):
			if c.flags & CONNECT_PERSIST:
				var target = (c.callable as Callable).get_object()
				var tname := _rel(target) if target is Node and _root().is_ancestor_of(target) or target == _root() else "?"
				conns.append("  %s -> %s.%s" % [sig.name, tname, (c.callable as Callable).get_method()])
	if not conns.is_empty():
		lines.append(L.t("Signals:"))
		lines.append_array(conns)
	var kids: Array = []
	for c in node.get_children():
		if c.owner != null:
			kids.append("%s (%s)" % [c.name, c.get_class()])
	if not kids.is_empty():
		lines.append(L.t("Children: ") + ", ".join(kids.slice(0, 40)))
	return _ok("\n".join(lines))


func _t_node_set(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var props = args.properties
	if not props is Dictionary or props.is_empty():
		return _err(L.t("properties must be an object, e.g. {\"position\": [100, 50]}"))
	var node: Node = f.node
	var r := _apply_props(node, props)
	var msg := ""
	if not r.applied.is_empty():
		msg = "%s: %s" % [_rel(node), _report_props(node, r.applied)]
	msg += r.tail
	if r.failed.is_empty():
		return _ok(msg)
	# Any property that did not stick is an error: the model must not move on believing it did.
	return _err(msg.trim_prefix("\n"))


func _t_node_delete(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var node: Node = f.node
	var root := _root()
	if node == root:
		return _err(L.t("cannot delete the scene root"))
	var guard := _instance_guard(node)
	if guard != "":
		return _err(guard)
	var parent := node.get_parent()
	var owned := _owned(node, root)
	var path := _rel(node)
	var ur := _ur()
	ur.create_action(L.t("MCP: delete ") + str(node.name), UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node, true)
	ur.add_undo_method(parent, "move_child", node, node.get_index())
	ur.add_undo_method(node, "set_owner", root)
	ur.add_undo_method(self, "_set_owners", owned, root)
	ur.add_undo_reference(node)
	ur.commit_action()
	return _ok(L.t("Deleted %s%s") % [path, (L.t(" with %d children") % owned.size()) if owned.size() > 0 else ""])


func _t_node_move(args: Dictionary) -> Dictionary:
	var f := _find(args.path)
	if f.has("error"):
		return _err(f.error)
	var node: Node = f.node
	var root := _root()
	if node == root:
		return _err(L.t("the scene root cannot be moved or renamed"))
	var guard := _instance_guard(node)
	if guard != "":
		return _err(guard)
	var has_change := args.has("new_name") or args.has("new_parent") or args.has("index")
	if not has_change:
		return _err(L.t("give at least one of: new_name, new_parent or index"))
	var old_parent := node.get_parent()
	var old_index := node.get_index()
	var new_parent: Node = old_parent
	if args.has("new_parent") and str(args.new_parent) != "":
		var pf := _find(args.new_parent)
		if pf.has("error"):
			return _err("new_parent: " + pf.error)
		new_parent = pf.node
		if new_parent == node or node.is_ancestor_of(new_parent):
			return _err(L.t("cannot move a node into itself"))
		var pguard := _instance_guard(new_parent, true)
		if pguard != "":
			return _err("new_parent: " + pguard)
	var ur := _ur()
	ur.create_action(L.t("MCP: move ") + str(node.name), UndoRedo.MERGE_DISABLE, root)
	if args.has("new_name") and str(args.new_name) != "":
		var nn := str(args.new_name).validate_node_name()
		if new_parent.has_node(NodePath(nn)) and new_parent.get_node(NodePath(nn)) != node:
			ur.commit_action()
			return _err(L.t("\"%s\" already has a node named %s") % [_rel(new_parent), nn])
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
	return _ok(L.t("Now %s (index %d in %s)") % [_rel(node), node.get_index(), _rel(node.get_parent())])


func _t_signal_connect(args: Dictionary) -> Dictionary:
	var ff := _find(args.from)
	if ff.has("error"):
		return _err("from: " + ff.error)
	var tf := _find(args.get("to", "."))
	if tf.has("error"):
		return _err("to: " + tf.error)
	var src: Node = ff.node
	var dst: Node = tf.node
	var guard := _instance_guard(src, true)
	if guard != "":
		return _err("from: " + guard)
	var sig := str(args.signal).strip_edges().trim_suffix("()")
	if not src.has_signal(sig):
		var names: Array = []
		for s in src.get_signal_list():
			names.append(s.name)
		return _err(L.t("%s (%s) has no signal \"%s\". Available: %s") % [_rel(src), src.get_class(), sig, ", ".join(names.slice(0, 30))])
	var method := str(args.method).strip_edges().trim_suffix("()")
	var callable := Callable(dst, method)
	if src.is_connected(sig, callable):
		return _ok(L.t("Already connected: %s.%s -> %s.%s") % [_label(src), sig, _label(dst), method])
	var ur := _ur()
	ur.create_action(L.t("MCP: signal ") + sig, UndoRedo.MERGE_DISABLE, _root())
	ur.add_do_method(src, "connect", sig, callable, CONNECT_PERSIST)
	ur.add_undo_method(src, "disconnect", sig, callable)
	ur.commit_action()
	var msg := L.t("Connected: %s.%s -> %s.%s") % [_label(src), sig, _label(dst), method]
	if not dst.has_method(method):
		var scr: Script = dst.get_script()
		msg += L.t("\nWarning: %s has no method %s. Add to %s: func %s(%s):") % [
			_label(dst), method, scr.resource_path if scr else L.t("its script (there is no script)"), method, _signal_args(src, sig)]
	return _ok(msg)


func _signal_args(src: Node, sig: String) -> String:
	for s in src.get_signal_list():
		if s.name == sig:
			var parts: Array = []
			for a in s.args:
				parts.append(a.name)
			return ", ".join(parts)
	return ""


# ─────────────────────────── tools: scripts ───────────────────────────

func _t_script_read(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	if not FileAccess.file_exists(r.path):
		return _err(L.t("file not found: ") + r.path)
	var text := FileAccess.get_file_as_string(r.path)
	var lines := text.split("\n")
	var total := lines.size()
	var start: int = clampi(int(args.get("start_line", 1)), 1, max(total, 1))
	var end: int = clampi(int(args.get("end_line", start + MAX_SCRIPT_READ - 1)), start, total)
	var out: Array = [L.t("%s (lines: %d)") % [r.path, total]]
	for i in range(start - 1, end):
		out.append("%4d| %s" % [i + 1, lines[i]])
	if end < total:
		out.append(L.t("…more at lines %d-%d, use start_line") % [end + 1, total])
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
	var msg := L.t("%s %s (%d lines)") % [L.t("Overwrote") if existed else L.t("Created"), path, content.split("\n").size()]
	msg += "\n" + res.check
	var attach := str(args.get("attach_to", ""))
	if attach != "":
		var f := _find(attach)
		if f.has("error"):
			msg += L.t("\nNot attached: ") + f.error
		elif res.valid:
			var node: Node = f.node
			var scr: Script = load(path)
			var base := scr.get_instance_base_type()
			if base != "" and not node.is_class(base):
				msg += L.t("\nNot attached: the script extends %s, but the node is %s") % [base, node.get_class()]
			else:
				var ur := _ur()
				ur.create_action(L.t("MCP: script on ") + str(node.name), UndoRedo.MERGE_DISABLE, _root())
				ur.add_do_method(node, "set_script", scr)
				ur.add_undo_method(node, "set_script", node.get_script())
				ur.commit_action()
				msg += L.t("\nAttached to ") + _rel(node)
		else:
			msg += L.t("\nNot attached while there are errors")
	return {"text": msg, "error": not res.valid}


func _t_script_edit(args: Dictionary) -> Dictionary:
	var r := _res_path(args.path)
	if r.has("error"):
		return _err(r.error)
	var path: String = r.path
	if not FileAccess.file_exists(path):
		return _err(L.t("file not found: %s. For a new file use script_write") % path)
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	var new_text := _clean_code(str(args.get("new_text", "")))
	var result := ""
	var where := ""
	if args.has("start_line"):
		var s: int = int(args.start_line)
		var e: int = int(args.get("end_line", s))
		if s < 1 or s > lines.size() + 1 or e < s - 1 or e > lines.size():
			return _err(L.t("lines %d-%d are outside the file (it has %d lines)") % [s, e, lines.size()])
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
		where = L.t("lines %d-%d replaced with %d lines") % [s, e, mid.size()]
	elif args.has("old_text") and str(args.old_text) != "" and _count_exact(text, str(args.old_text).replace("\r\n", "\n")) > 0:
		# Exact substring match (including part of a line: items[3] -> items[2]).
		var old := str(args.old_text).replace("\r\n", "\n")
		var n := _count_exact(text, old)
		if n > 1:
			return _err(L.t("old_text occurs %d times. Add surrounding text to make it unique, or use start_line") % n)
		var at := text.find(old)
		var first_line := text.substr(0, at).count("\n") + 1
		var raw_new := str(args.get("new_text", "")).replace("\r\n", "\n")
		result = text.substr(0, at) + raw_new + text.substr(at + old.length())
		where = L.t("replaced at line %d") % first_line if not old.contains("\n") else L.t("replaced starting at line %d") % first_line
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
		where = L.t("replaced lines %d-%d") % [m.start + 1, m.end + 1]
	else:
		return _err(L.t("give start_line (and end_line) or old_text"))
	var res := _save_script(path, result)
	if res.has("error"):
		return _err(res.error)
	return {"text": "%s: %s\n%s" % [path, where, res.check], "error": not res.valid}


static func _count_exact(text: String, needle: String) -> int:
	if needle == "":
		return 0
	return text.count(needle)


## Finds a fragment line by line, ignoring leading spaces/tabs.
## Returns {start, end, indent_file, indent_given} (0-based line indexes) or {error}.
func _match_span(lines: PackedStringArray, needle: String) -> Dictionary:
	var want: Array = []
	for l in needle.split("\n"):
		want.append(l)
	while not want.is_empty() and want[0].strip_edges() == "":
		want.pop_front()
	while not want.is_empty() and want[-1].strip_edges() == "":
		want.pop_back()
	if want.is_empty():
		return {"error": L.t("old_text is empty")}
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
		# Hint: where the first line of the fragment occurs.
		var first := str(want[0]).strip_edges()
		var near: Array = []
		for i in lines.size():
			if first.length() > 3 and lines[i].strip_edges().contains(first.substr(0, min(first.length(), 25))):
				near.append(str(i + 1))
		var tip := (L.t("similar start at lines ") + ", ".join(near.slice(0, 5))) if not near.is_empty() else L.t("read the file with script_read")
		return {"error": L.t("old_text not found (%s). You can replace by line numbers with start_line/end_line") % tip}
	if hits.size() > 1:
		var where: Array = []
		for h in hits:
			where.append(str(h + 1))
		return {"error": L.t("old_text occurs %d times (lines %s). Add neighbouring lines or use start_line") % [hits.size(), ", ".join(where.slice(0, 8))]}
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


## Re-indents: if the model sent a fragment with a different base indent
## (or spaces instead of tabs), align it to the file.
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
		# spaces -> tabs if the file uses tabs
		if unit_file == "\t":
			rel = rel.replace("    ", "\t")
		out.append(indent_file + rel + body)
	return "\n".join(out)


## Strips the ```gdscript ... ``` fence that models often add.
static func _clean_code(s: String) -> String:
	var t := s.replace("\r\n", "\n")
	var stripped := t.strip_edges()
	if stripped.begins_with("```"):
		var nl := stripped.find("\n")
		if nl > 0 and stripped.ends_with("```"):
			return stripped.substr(nl + 1, stripped.length() - nl - 4).trim_suffix("\n") + "\n"
	return t


## Writes the file, checks GDScript, refreshes the editor.
## Returns {valid: bool, check: String} or {error}.
func _save_script(path: String, content: String) -> Dictionary:
	if not path.get_extension() in ["gd", "gdshader", "cs", "txt", "md", "json", "cfg", "tres", "gdshaderinc"]:
		return {"error": L.t("only text files can be written (.gd, .gdshader, .cs, .json, .txt ...)")}
	var is_gd := path.get_extension() == "gd"
	var check := {"valid": true, "check": L.t("Check: not GDScript, syntax not checked")}
	# A script whose class_name is already registered for this very file cannot be checked as an
	# anonymous copy (it would "hide" its own class), so it is compiled for real after writing.
	var check_after := false
	if is_gd:
		_class_scan.clear()
		var cls := _class_name_in(content)
		var taken := _class_owner_conflict(cls, path)
		if taken != "":
			check = {"valid": false, "check": L.t("Check: ERRORS\n") + "  " +
				L.t("class_name %s is already declared in %s. Pick another name") % [cls, taken]}
		elif cls != "" and _registered_class_path(cls) == path:
			check_after = true
		else:
			check = _check_gdscript(content)
	_ensure_dir(path)
	var old_text := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": L.t("could not write %s (code %d)") % [path, FileAccess.get_open_error()]}
	f.store_string(content)
	f.close()
	_fs_update(path)
	_sync_open_editors(old_text, content)
	if check_after:
		check = _check_real_script(path, content)
	elif is_gd and ResourceLoader.has_cached(path):
		var scr: Script = load(path)
		scr.source_code = content
		if check.valid:
			scr.reload(true)
	return check


## The other file that already declares class_name cls, or "" if there is none.
func _class_owner_conflict(cls: String, path: String) -> String:
	if cls == "":
		return ""
	var owner := _registered_class_path(cls)
	if owner == "":
		if _class_scan.is_empty():
			_scan_class_names("res://", _class_scan)
		owner = str(_class_scan.get(cls, ""))
	return owner if owner != "" and owner != path else ""


## Compiles the file's own script resource (the one the editor and the game use).
func _check_real_script(path: String, content: String) -> Dictionary:
	var mark: int = _logger.mark() if _logger else 0
	var scr: Script = load(path)
	var err := ERR_PARSE_ERROR
	if scr:
		scr.source_code = content
		err = scr.reload(true)
	return _check_result(err, mark, path)


func _check_gdscript(content: String) -> Dictionary:
	var scr := GDScript.new()
	# class_name stays: the file's own type is then known, so "signal died(e: Enemy)" in
	# class_name Enemy compiles. Clashes with other files are caught by _class_owner_conflict.
	scr.source_code = content
	var mark: int = _logger.mark() if _logger else 0
	return _check_result(scr.reload(), mark)


## own_path: the checked file; its name is dropped from error lines, other files keep theirs.
func _check_result(err: int, mark: int, own_path := "") -> Dictionary:
	if err == OK:
		return {"valid": true, "check": L.t("Check: no errors")}
	var details: Array = []
	if _logger:
		for l in _logger.since(mark):
			var d := "  " + _clean_err(l, own_path)
			if not details.has(d):  # loading and reloading report the same error twice
				details.append(d)
	if details.is_empty():
		details.append(L.t("  details are in the editor Output panel (on Godot 4.5+ they come here)"))
	return {"valid": false, "check": L.t("Check: ERRORS\n") + "\n".join(details.slice(0, 10))}


## If the file is open in the built-in script editor (e.g. the debugger opened it after an error),
## the buffer keeps the old text, and the next game run would save it over our edit.
## So refresh those buffers. A buffer with the user's unsaved edits is left alone: its text
## differs from the old file content.
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


## "SCRIPT ERROR: Parse Error: x (gdscript://12.gd:5)" -> "line 5: Parse Error: x".
## A res:// location is shortened the same way only when it is own_path.
static func _clean_err(l: String, own_path := "") -> String:
	var rx := RegEx.create_from_string("\\s*\\((gdscript://[^:]*|res://[^:)]*):(\\d+)\\)")
	var m := rx.search(l)
	var out := l.replace("SCRIPT ERROR: ", "")
	if m and (m.get_string(1).begins_with("gdscript://") or m.get_string(1) == own_path):
		out = L.t("line %s: %s") % [m.get_string(2), rx.sub(out, "")]
	return out


# ─────────────────────────── tools: game ───────────────────────────

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
				return _err(L.t("the project has no main scene. Run scene=\"current\" or give a path res://...tscn"))
			EditorInterface.play_main_scene()
			return _ok(L.t("Started the main scene %s. Call game_output in a couple of seconds") % main)
		"current":
			var root := _root()
			if root == null:
				return _no_scene()
			if root.scene_file_path != "":
				EditorInterface.save_scene()
			EditorInterface.play_current_scene()
			return _ok(L.t("Started the current scene %s. Call game_output in a couple of seconds") % root.scene_file_path)
		_:
			var r := _res_path(scene)
			if r.has("error"):
				return _err(r.error)
			if not ResourceLoader.exists(r.path):
				return _err(L.t("scene not found: ") + r.path)
			EditorInterface.play_custom_scene(r.path)
			return _ok(L.t("Started %s. Call game_output in a couple of seconds") % r.path)


func _t_game_stop(_args: Dictionary) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return _ok(L.t("The game is not running"))
	EditorInterface.stop_playing_scene()
	return _ok(L.t("Game stopped"))


func _t_game_output(args: Dictionary) -> Dictionary:
	var errors_only := bool(args.get("errors_only", false))
	var max_lines: int = clampi(int(args.get("lines", 60)), 5, MAX_OUTPUT_LINES)
	var out: Array = []
	out.append(L.t("Game: ") + (L.t("running") if EditorInterface.is_playing_scene() else L.t("not running")))
	var log_path := OS.get_user_data_dir().path_join("logs/godot.log")
	var game_lines: Array = []
	var hidden := 0
	if _last_run_ms == 0:
		game_lines.append(L.t("(the game was not started in this session, call game_run)"))
	else:
		# While the game runs, read live editor sources: the Output panel (print) and the debugger
		# Errors tab. On Windows the game log file may be locked until the game stops.
		var raw := PackedStringArray()
		if EditorInterface.is_playing_scene():
			raw = _live_game_output()
		if raw.is_empty() and FileAccess.file_exists(log_path):
			raw = FileAccess.get_file_as_string(log_path).split("\n")
		if raw.is_empty() and not EditorInterface.is_playing_scene() and not FileAccess.file_exists(log_path):
			game_lines.append(L.t("(log not found: enable debug/file_logging/enable_file_logging in Project Settings)"))
		else:
			var parsed := _filter_log(raw, errors_only)
			game_lines = parsed.lines
			hidden = parsed.hidden
	if game_lines.size() > max_lines:
		game_lines = [L.t("…%d lines skipped") % (game_lines.size() - max_lines)] + game_lines.slice(game_lines.size() - max_lines)
	out.append(L.t("Game output:") if not game_lines.is_empty() else (L.t("Game output: no errors") if errors_only else L.t("Game output: empty")))
	out.append_array(game_lines)
	if hidden > 0:
		out.append(L.t("(%d engine service messages hidden: drivers, audio, display)") % hidden)
	if EditorInterface.is_playing_scene():
		var frame := _debugger_break_frame()
		if frame != "":
			out.append(L.t("The game is paused: the debugger stopped it on an error (%s). Waiting will not help: fix the code and call game_run again (or game_stop).") % frame)
	if _logger:
		var ed := _filter_log(PackedStringArray(_logger.since(0)), true)
		if not ed.lines.is_empty():
			out.append(L.t("Editor errors:"))
			out.append_array(ed.lines.slice(max(0, ed.lines.size() - 20)))
	return _ok("\n".join(out))


## Output of the current run from the editor, in log file format:
## print lines from the Output panel and errors from the debugger Errors tab.
func _live_game_output() -> PackedStringArray:
	var out := PackedStringArray()
	var panel := _editor_output_text().split("\n")
	var start := 0
	for i in panel.size():
		if panel[i].begins_with("Godot Engine v"):
			start = i + 1
	for i in range(start, panel.size()):
		var l: String = panel[i]
		# Indented lines and ERROR/WARNING lines in the panel come from the editor, not the game.
		if l.begins_with("  ERROR:") or l.begins_with("  WARNING:") or l.begins_with("OpenGL API") or l.begins_with("Vulkan "):
			continue
		out.append(l)
	out.append_array(_debugger_errors())
	return out


## Errors of the current session from the debugger Errors tab.
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
					msg = msg.substr(marker + 4)  # "m2.gd:7 @ _ready(): text" -> "text"
				elif colon > 0 and not msg.substr(0, colon).contains(" "):
					msg = msg.substr(colon + 2)  # "_ready: text" -> "text"
				var warning := warn_icon != null and it.get_icon(0) == warn_icon
				var where := ""
				var is_script := false
				var meta = it.get_metadata(0)
				if meta is Array and meta.size() >= 2 and str(meta[0]).begins_with("res://"):
					# The metadata holds the full script path and line.
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


## If the debugger stopped the game on an error, returns the top stack frame ("res://main.gd:6 @ _ready").
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


## Tree of the debugger errors tab. The tab name is localized to the editor language,
## so detect it by content: 2 columns, the first holds a time like 0:00:01:234.
static func _is_error_tree(tr: Tree) -> bool:
	if tr.columns != 2 or tr.get_root() == null:
		return false
	var first := tr.get_root().get_first_child()
	if first == null:
		return false
	return RegEx.create_from_string("^\\d+:\\d\\d:\\d\\d:\\d\\d\\d$").search(first.get_text(0)) != null


## Text of the editor Output panel (the debugger writes the running game's output there).
## Needed when the game log file cannot be read (Windows locks it while the game runs).
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


## Splits the log into entries (a line plus its indented continuation) and drops engine noise.
## An error is kept if it is a script/user error or mentions res://.
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
		# The GDScript backtrace repeats the "at:" line; keep the message and location.
		lines.append_array(e.slice(0, 2))
	return {"lines": lines, "hidden": hidden}


# ─────────────────────────── tools: reference ───────────────────────────

func _t_class_info(args: Dictionary) -> Dictionary:
	var cls := str(args.type).strip_edges()
	if not ClassDB.class_exists(cls):
		var gp := _global_class_path(cls)
		if gp != "":
			return _err(L.t("%s is a class_name from %s. Read the script with script_read") % [cls, gp])
		var sim := _similar(Array(ClassDB.get_class_list()), cls, 8)
		return _err(L.t("no class \"%s\"%s") % [cls, (L.t(". Similar: ") + ", ".join(sim)) if not sim.is_empty() else ""])
	var filter := str(args.get("filter", "")).strip_edges()
	var chain: Array = [cls]
	var p := ClassDB.get_parent_class(cls)
	while p != "":
		chain.append(p)
		p = ClassDB.get_parent_class(p)
	var lines: Array = ["%s: %s" % [cls, " < ".join(chain.slice(1))]]
	# Without a filter show only the class's own members; with a filter search the whole chain.
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
				continue  # setters/getters: the properties are already listed above
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
		lines.append(L.t("Properties:"))
		lines.append_array(props.slice(0, 50))
	if not signals.is_empty():
		lines.append(L.t("Signals:"))
		lines.append_array(signals.slice(0, 30))
	if not methods.is_empty():
		lines.append(L.t("Methods:"))
		lines.append_array(methods.slice(0, 50))
	if props.size() + methods.size() + signals.size() == 0:
		lines.append(L.t("Nothing found") + (L.t(" matching \"%s\"") % filter if filter != "" else ""))
	elif filter == "":
		lines.append(L.t("(only members of %s; find inherited ones with filter)") % cls)
	return _ok("\n".join(lines))


static func _type_name(info: Dictionary) -> String:
	var t: int = info.get("type", TYPE_NIL)
	if t == TYPE_OBJECT and str(info.get("class_name", "")) != "":
		return str(info.class_name)
	if t == TYPE_NIL:
		return "void" if not (int(info.get("usage", 0)) & PROPERTY_USAGE_NIL_IS_VARIANT) else "Variant"
	return type_string(t)
