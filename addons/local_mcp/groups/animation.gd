@tool
extends RefCounted
## Группа «animation»: AnimationPlayer, анимации, дорожки свойств и ключи.
## Правки идут через замену анимации в библиотеке, поэтому одна правка = один шаг Ctrl+Z.

const Values := preload("res://addons/local_mcp/values.gd")

var t  # tools.gd


func defs() -> Array:
	var s = t._s
	return [
		t._tool("anim_create", "Create (or update) an animation in an AnimationPlayer. The player is created under the root if missing.",
			{"player": s.call("string", "AnimationPlayer path, default \"AnimationPlayer\"."),
			"name": s.call("string", "Animation name, e.g. \"walk\"."),
			"length": s.call("number", "Seconds, default 1."), "loop": s.call("boolean"),
			"autoplay": s.call("boolean", "Play automatically when the scene starts.")}, ["name"]),
		t._tool("anim_key", "Animate a node property: adds keys to a track (created if missing). Values are flexible like in node_set.",
			{"player": s.call("string", "Default \"AnimationPlayer\"."), "animation": s.call("string"),
			"target": s.call("string", "Animated node path, e.g. \"Player/Sprite2D\"."),
			"property": s.call("string", "e.g. position, modulate, rotation, frame"),
			"keys": s.call("array", "[{\"time\": 0, \"value\": [0, 0]}, {\"time\": 0.5, \"value\": [0, -10]}]"),
			"interpolation": s.call("string", "linear (default), nearest or cubic")}, ["animation", "target", "property", "keys"]),
		t._tool("anim_info", "List animations of an AnimationPlayer, or show tracks and keys of one animation.",
			{"player": s.call("string", "Default \"AnimationPlayer\"."), "animation": s.call("string")}, [], true),
	]


func _player(path, create: bool) -> Dictionary:
	var p := str(path if path != null and str(path) != "" else "AnimationPlayer")
	var f: Dictionary = t._find(p)
	if f.has("node"):
		if not f.node is AnimationPlayer:
			return {"error": "%s это %s, а нужен AnimationPlayer" % [t._rel(f.node), f.node.get_class()]}
		return f
	if not create:
		var found: Array = t._root().find_children("*", "AnimationPlayer", true, false) if t._root() else []
		var names: Array = []
		for n in found:
			names.append(t._rel(n))
		return {"error": "AnimationPlayer \"%s\" не найден%s" % [p, (". Есть: " + ", ".join(names)) if not names.is_empty() else ". Создайте анимацию через anim_create"]}
	var root: Node = t._root()
	var parent: Node = root
	p = p.trim_prefix("./")
	if p.contains("/"):
		var pf: Dictionary = t._find(p.get_base_dir())
		if pf.has("error"):
			return pf
		parent = pf.node
	var ap := AnimationPlayer.new()
	ap.name = p.get_file().validate_node_name()
	var ur: EditorUndoRedoManager = t._ur()
	ur.create_action("MCP: AnimationPlayer", UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", ap, true)
	ur.add_do_method(ap, "set_owner", root)
	ur.add_do_reference(ap)
	ur.add_undo_method(parent, "remove_child", ap)
	ur.commit_action()
	return {"node": ap, "created": true}


## Библиотека по умолчанию ("") создаётся при необходимости.
static func _library(ap: AnimationPlayer) -> AnimationLibrary:
	if ap.has_animation_library(&""):
		return ap.get_animation_library(&"")
	var lib := AnimationLibrary.new()
	ap.add_animation_library(&"", lib)
	return lib


## Находит анимацию по имени, в том числе "lib/name". Возвращает {lib, key, anim} или {error}.
func _find_anim(ap: AnimationPlayer, name: String) -> Dictionary:
	if ap.has_animation(name):
		var lib_name := ""
		var key := name
		if name.contains("/"):
			lib_name = name.get_slice("/", 0)
			key = name.substr(lib_name.length() + 1)
		return {"lib": ap.get_animation_library(lib_name), "key": key, "anim": ap.get_animation(name)}
	var list := Array(ap.get_animation_list())
	return {"error": "нет анимации \"%s\" в %s. Есть: %s" % [name, t._rel(ap), ", ".join(list) if not list.is_empty() else "ни одной (создайте через anim_create)"]}


## Замена анимации в библиотеке целиком: так undo простой и надёжный.
func _commit_anim(lib: AnimationLibrary, key: String, new_anim: Animation, old_anim, label: String) -> void:
	var ur: EditorUndoRedoManager = t._ur()
	ur.create_action("MCP: " + label, UndoRedo.MERGE_DISABLE, t._root())
	ur.add_do_method(lib, "add_animation", key, new_anim)
	if old_anim:
		ur.add_undo_method(lib, "add_animation", key, old_anim)
	else:
		ur.add_undo_method(lib, "remove_animation", key)
	ur.add_do_reference(new_anim)
	ur.commit_action()


func _t_anim_create(args: Dictionary) -> Dictionary:
	if t._root() == null:
		return t._no_scene()
	var pf := _player(args.get("player"), true)
	if pf.has("error"):
		return t._err(pf.error)
	var ap: AnimationPlayer = pf.node
	var name := str(args.name).strip_edges()
	if name == "" or name.contains("/") or name.contains(":"):
		return t._err("имя анимации без / и :, например \"walk\"")
	var lib := _library(ap)
	var old: Animation = lib.get_animation(name) if lib.has_animation(name) else null
	var anim: Animation = old.duplicate(true) if old else Animation.new()
	if args.has("length") or old == null:
		anim.length = maxf(float(args.get("length", 1.0)), 0.001)
	if args.has("loop"):
		anim.loop_mode = Animation.LOOP_LINEAR if bool(args.loop) else Animation.LOOP_NONE
	_commit_anim(lib, name, anim, old, "анимация " + name)
	var extra := ""
	if bool(args.get("autoplay", false)):
		var ur: EditorUndoRedoManager = t._ur()
		ur.create_action("MCP: autoplay " + name, UndoRedo.MERGE_DISABLE, t._root())
		ur.add_do_property(ap, "autoplay", name)
		ur.add_undo_property(ap, "autoplay", ap.autoplay)
		ur.commit_action()
		extra = ", autoplay"
	return t._ok("%s анимация \"%s\" в %s%s: длина %s c, %s%s" % [
		"Обновлена" if old else "Создана", name, t._rel(ap), " (плеер создан)" if pf.get("created", false) else "",
		Values._n(anim.length), "зациклена" if anim.loop_mode != Animation.LOOP_NONE else "без цикла", extra])


func _t_anim_key(args: Dictionary) -> Dictionary:
	if t._root() == null:
		return t._no_scene()
	var pf := _player(args.get("player"), false)
	if pf.has("error"):
		return t._err(pf.error)
	var ap: AnimationPlayer = pf.node
	var fa := _find_anim(ap, str(args.animation))
	if fa.has("error"):
		return t._err(fa.error)
	var tf: Dictionary = t._find(args.target)
	if tf.has("error"):
		return t._err("target: " + tf.error)
	var target: Node = tf.node
	var prop := str(args.property).strip_edges()
	if not Values.has_property(target, prop) and Values.has_property(target, prop.to_snake_case()):
		prop = prop.to_snake_case()
	if not Values.has_property(target, prop):
		var sim: String = t._similar_props(target, prop)
		return t._err("у %s нет свойства \"%s\"%s" % [target.get_class(), prop, (" (похожие: " + sim + ")") if sim != "" else ""])
	var raw_keys = args.keys
	if raw_keys is String:
		raw_keys = JSON.parse_string(raw_keys)
	if raw_keys is Dictionary:
		raw_keys = [raw_keys]
	if not raw_keys is Array or raw_keys.is_empty():
		return t._err("keys: список вида [{\"time\": 0, \"value\": ...}, ...]")
	var keys: Array = []
	for k in raw_keys:
		var time_v = null
		var value_v = null
		if k is Dictionary:
			time_v = k.get("time", k.get("t", k.get("at")))
			value_v = k.get("value", k.get("v", k.get("val")))
		elif k is Array and k.size() == 2:
			time_v = k[0]
			value_v = k[1]
		if time_v == null or not str(time_v).is_valid_float():
			return t._err("у каждого ключа нужны time (секунды) и value, например {\"time\": 0.5, \"value\": [0, -10]}")
		var c := Values.coerce_for(target, prop, value_v)
		if not c.ok:
			return t._err("value в ключе %s: %s" % [str(time_v), c.error])
		keys.append([float(time_v), c.value])

	var root_node: Node = ap.get_node_or_null(ap.root_node)
	if root_node == null:
		return t._err("у %s неверный root_node" % t._rel(ap))
	var track_path := NodePath(str(root_node.get_path_to(target)) + ":" + prop)
	var anim: Animation = (fa.anim as Animation).duplicate(true)
	var idx := anim.find_track(track_path, Animation.TYPE_VALUE)
	var new_track := idx < 0
	if new_track:
		idx = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(idx, track_path)
		# Дискретные свойства (frame, visible, текст) обновляем скачком, а не плавно.
		var vt := typeof(keys[0][1])
		if vt in [TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_OBJECT, TYPE_STRING_NAME]:
			anim.value_track_set_update_mode(idx, Animation.UPDATE_DISCRETE)
	var interp := str(args.get("interpolation", "")).to_lower()
	if interp != "":
		var mode: int = {"nearest": Animation.INTERPOLATION_NEAREST, "linear": Animation.INTERPOLATION_LINEAR,
			"cubic": Animation.INTERPOLATION_CUBIC}.get(interp, -1)
		if mode == -1:
			return t._err("interpolation: linear, nearest или cubic")
		anim.track_set_interpolation_type(idx, mode)
	var max_time := 0.0
	for k in keys:
		var existing := anim.track_find_key(idx, k[0], Animation.FIND_MODE_APPROX)
		if existing >= 0:
			anim.track_remove_key(idx, existing)
		anim.track_insert_key(idx, k[0], k[1])
		max_time = maxf(max_time, k[0])
	var note := ""
	if max_time > anim.length:
		anim.length = max_time
		note = "; длина анимации увеличена до %s c" % Values._n(max_time)
	_commit_anim(fa.lib, fa.key, anim, fa.anim, "ключи " + prop)
	var shown: Array = []
	for k in keys:
		shown.append("%s c: %s" % [Values._n(k[0]), Values.show(k[1])])
	return t._ok("%s дорожка %s в \"%s\": %s%s" % ["Новая" if new_track else "Обновлена", str(track_path), str(args.animation),
		"; ".join(shown), note])


func _t_anim_info(args: Dictionary) -> Dictionary:
	if t._root() == null:
		return t._no_scene()
	var pf := _player(args.get("player"), false)
	if pf.has("error"):
		return t._err(pf.error)
	var ap: AnimationPlayer = pf.node
	var lines: Array = ["%s, root_node %s%s" % [t._rel(ap), str(ap.root_node), (", autoplay \"%s\"" % ap.autoplay) if ap.autoplay != "" else ""]]
	var name := str(args.get("animation", ""))
	if name == "":
		var list := Array(ap.get_animation_list())
		if list.is_empty():
			lines.append("Анимаций нет")
		for a in list:
			var anim := ap.get_animation(a)
			lines.append("  %s: %s c, %s, дорожек %d" % [a, Values._n(anim.length), "цикл" if anim.loop_mode != Animation.LOOP_NONE else "без цикла", anim.get_track_count()])
		return t._ok("\n".join(lines))
	var fa := _find_anim(ap, name)
	if fa.has("error"):
		return t._err(fa.error)
	var anim: Animation = fa.anim
	lines.append("\"%s\": %s c, %s" % [name, Values._n(anim.length), "цикл" if anim.loop_mode != Animation.LOOP_NONE else "без цикла"])
	for i in anim.get_track_count():
		var keys: Array = []
		for k in mini(anim.track_get_key_count(i), 20):
			keys.append("%s: %s" % [Values._n(anim.track_get_key_time(i, k)), Values.show(anim.track_get_key_value(i, k))])
		lines.append("  %s%s: %s" % [str(anim.track_get_path(i)), "" if anim.track_get_type(i) == Animation.TYPE_VALUE else " (тип %d)" % anim.track_get_type(i), "; ".join(keys)])
	if anim.get_track_count() == 0:
		lines.append("  дорожек нет, добавьте через anim_key")
	return t._ok("\n".join(lines))
