@tool
extends RefCounted
## Прощающее приведение значений из JSON к типам Godot.
## Тип берётся из самого свойства, поэтому модели не нужно писать теги типов.
## Возвращает {"ok": true, "value": v} или {"ok": false, "error": "..."}.

const VEC_KEYS := ["x", "y", "z", "w"]
const COLOR_KEYS := ["r", "g", "b", "a"]


static func ok(v) -> Dictionary:
	return {"ok": true, "value": v}


static func fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


## Тип и подсказка свойства объекта (с поддержкой путей вида "position:x").
static func property_info(obj: Object, prop: String) -> Dictionary:
	var base := prop.split(":")[0]
	for p in obj.get_property_list():
		if p.name == base:
			if base == prop:
				return p
			break
	# Подсвойство или неизвестное свойство: тип по текущему значению.
	var cur = obj.get_indexed(NodePath(prop)) if prop.contains(":") else obj.get(prop)
	return {"name": prop, "type": typeof(cur), "hint": PROPERTY_HINT_NONE, "hint_string": "", "class_name": ""}


static func has_property(obj: Object, prop: String) -> bool:
	var base := prop.split(":")[0]
	for p in obj.get_property_list():
		if p.name == base:
			return true
	return false


## Главная функция: привести raw к типу свойства prop объекта obj.
static func coerce_for(obj: Object, prop: String, raw) -> Dictionary:
	var info := property_info(obj, prop)
	return coerce(raw, int(info.get("type", TYPE_NIL)), int(info.get("hint", 0)),
		str(info.get("hint_string", "")), str(info.get("class_name", "")))


static func coerce(raw, t: int, hint: int = 0, hint_string: String = "", cls: String = "") -> Dictionary:
	if raw == null:
		return ok(null)
	match t:
		TYPE_NIL:
			return ok(_guess(raw))
		TYPE_BOOL:
			if raw is bool: return ok(raw)
			if raw is String:
				var s: String = raw.strip_edges().to_lower()
				if s in ["true", "1", "yes", "on", "да"]: return ok(true)
				if s in ["false", "0", "no", "off", "нет", ""]: return ok(false)
			if raw is float or raw is int: return ok(raw != 0)
			return fail("ожидается true/false")
		TYPE_INT:
			if raw is String and (hint == PROPERTY_HINT_ENUM or hint == PROPERTY_HINT_FLAGS):
				var e := _enum_value(raw, hint_string, hint == PROPERTY_HINT_FLAGS)
				if e.ok: return e
			if raw is String and raw.strip_edges().is_valid_float(): return ok(int(float(raw)))
			if raw is float or raw is int: return ok(int(raw))
			if raw is bool: return ok(int(raw))
			if hint == PROPERTY_HINT_ENUM:
				return fail("ожидается число или одно из: " + _enum_names(hint_string))
			return fail("ожидается целое число")
		TYPE_FLOAT:
			if raw is float or raw is int: return ok(float(raw))
			if raw is String and raw.strip_edges().is_valid_float(): return ok(float(raw))
			return fail("ожидается число")
		TYPE_STRING:
			return ok(raw if raw is String else JSON.stringify(raw))
		TYPE_STRING_NAME:
			return ok(StringName(str(raw)))
		TYPE_NODE_PATH:
			return ok(NodePath(str(raw)))
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
			return _vector(raw, t)
		TYPE_COLOR:
			return _color(raw)
		TYPE_RECT2, TYPE_RECT2I:
			var n := _numbers(raw, ["x", "y", "w", "h"], 4)
			if n.is_empty():
				if raw is Dictionary and raw.has("position") and raw.has("size"):
					var p := _vector(raw.position, TYPE_VECTOR2)
					var s := _vector(raw.size, TYPE_VECTOR2)
					if p.ok and s.ok:
						var r := Rect2(p.value, s.value)
						return ok(Rect2i(r) if t == TYPE_RECT2I else r)
				return fail("ожидается [x, y, ширина, высота]")
			var rect := Rect2(n[0], n[1], n[2], n[3])
			return ok(Rect2i(rect) if t == TYPE_RECT2I else rect)
		TYPE_OBJECT:
			return _object(raw, cls if cls != "" else hint_string)
		TYPE_ARRAY:
			if raw is Array: return ok(raw)
			if raw is String:
				var parsed = JSON.parse_string(raw)
				if parsed is Array: return ok(parsed)
			return fail("ожидается массив")
		TYPE_DICTIONARY:
			if raw is Dictionary: return ok(raw)
			return fail("ожидается объект")
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY:
			if not raw is Array: return fail("ожидается массив точек, например [[0,0],[10,0]]")
			var out = PackedVector2Array() if t == TYPE_PACKED_VECTOR2_ARRAY else PackedVector3Array()
			for item in raw:
				var v := _vector(item, TYPE_VECTOR2 if t == TYPE_PACKED_VECTOR2_ARRAY else TYPE_VECTOR3)
				if not v.ok: return v
				out.append(v.value)
			return ok(out)
		TYPE_PACKED_COLOR_ARRAY:
			if not raw is Array: return fail("ожидается массив цветов")
			var colors := PackedColorArray()
			for item in raw:
				var c := _color(item)
				if not c.ok: return c
				colors.append(c.value)
			return ok(colors)
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			if not raw is Array: return fail("ожидается массив")
			return ok(type_convert(raw, t))
		_:
			if raw is String:
				var v = str_to_var(raw)
				if v != null and typeof(v) == t: return ok(v)
			var converted = type_convert(raw, t)
			return ok(converted)


## Значение без известного типа: пробуем распознать строковые литералы Godot.
static func _guess(raw):
	if raw is String:
		var s: String = raw.strip_edges()
		if s.begins_with("res://"):
			var res = load(s) if ResourceLoader.exists(s) else null
			if res: return res
		if s.contains("(") and s.ends_with(")"):
			var v = str_to_var(s)
			if v != null: return v
	return raw


static func _vector(raw, t: int) -> Dictionary:
	var dims: int = {TYPE_VECTOR2: 2, TYPE_VECTOR2I: 2, TYPE_VECTOR3: 3, TYPE_VECTOR3I: 3, TYPE_VECTOR4: 4, TYPE_VECTOR4I: 4}[t]
	if typeof(raw) == t:
		return ok(raw)
	var n := _numbers(raw, VEC_KEYS, dims)
	if n.is_empty() and (raw is float or raw is int):
		n = []
		for i in dims: n.append(float(raw))  # одно число -> все компоненты
	if n.is_empty():
		var example := "[1, 2]" if dims == 2 else ("[1, 2, 3]" if dims == 3 else "[1, 2, 3, 4]")
		return fail("ожидается вектор, например %s или {\"x\":1,\"y\":2}" % example)
	match t:
		TYPE_VECTOR2: return ok(Vector2(n[0], n[1]))
		TYPE_VECTOR2I: return ok(Vector2i(roundi(n[0]), roundi(n[1])))
		TYPE_VECTOR3: return ok(Vector3(n[0], n[1], n[2]))
		TYPE_VECTOR3I: return ok(Vector3i(roundi(n[0]), roundi(n[1]), roundi(n[2])))
		TYPE_VECTOR4: return ok(Vector4(n[0], n[1], n[2], n[3]))
		_: return ok(Vector4i(roundi(n[0]), roundi(n[1]), roundi(n[2]), roundi(n[3])))


## Достаёт count чисел из [a,b], {x,y}, "a, b", "(a, b)", "Vector2(a, b)".
static func _numbers(raw, keys: Array, count: int) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw:
			if v is String and v.is_valid_float(): out.append(float(v))
			elif v is float or v is int: out.append(float(v))
			else: return []
	elif raw is Dictionary:
		for i in count:
			var k: String = keys[i]
			if raw.has(k): out.append(float(raw[k]))
			elif raw.has(k.to_upper()): out.append(float(raw[k.to_upper()]))
			else: return []
	elif raw is String:
		var s: String = raw.strip_edges()
		var open := s.find("(")
		if open >= 0 and s.ends_with(")"):
			s = s.substr(open + 1, s.length() - open - 2)
		s = s.trim_prefix("[").trim_suffix("]")
		for part in s.split(",", false):
			var p := part.strip_edges()
			if not p.is_valid_float(): return []
			out.append(float(p))
	else:
		return []
	if out.size() < count:
		return []
	return out.slice(0, count)


static func _color(raw) -> Dictionary:
	if raw is Color:
		return ok(raw)
	if raw is String:
		var s: String = raw.strip_edges()
		if s.begins_with("Color("):
			var n := _numbers(s, COLOR_KEYS, 3)
			if not n.is_empty():
				var parts := _numbers(s, COLOR_KEYS, 4)
				return ok(Color(n[0], n[1], n[2], parts[3] if not parts.is_empty() else 1.0))
		var sentinel := Color(0.1234, 0.5678, 0.9012, 0.3456)
		var c := Color.from_string(s, sentinel)
		if c != sentinel:
			return ok(c)
		return fail("неизвестный цвет \"%s\": используйте \"#ff8800\", \"red\" или [1, 0.5, 0]" % s)
	var n4 := _numbers(raw, COLOR_KEYS, 4)
	var n3 := n4 if not n4.is_empty() else _numbers(raw, COLOR_KEYS, 3)
	if n3.is_empty():
		return fail("ожидается цвет: \"#ff8800\", \"red\" или [1, 0.5, 0]")
	var scale := 255.0 if (n3[0] > 1.0 or n3[1] > 1.0 or n3[2] > 1.0) else 1.0
	var a: float = n4[3] if not n4.is_empty() else scale
	return ok(Color(n3[0] / scale, n3[1] / scale, n3[2] / scale, a / scale if a > 1.0 else a))


## Ресурсы: "res://..." загружает файл, {"type": "CircleShape2D", "radius": 20} создаёт новый.
static func _object(raw, expected_class: String) -> Dictionary:
	if raw is Object:
		return ok(raw)
	if raw is String:
		var path: String = raw.strip_edges()
		if path == "":
			return ok(null)
		if not path.begins_with("res://"):
			if ClassDB.class_exists(path) and ClassDB.can_instantiate(path):
				return ok(ClassDB.instantiate(path))
			return fail("ожидается путь res://... или {\"type\": \"%s\", ...свойства}" % (expected_class if expected_class != "" else "ClassName"))
		if not ResourceLoader.exists(path):
			return fail("файл не найден: " + path)
		return ok(load(path))
	if raw is Dictionary:
		var d: Dictionary = raw.duplicate()
		var cls: String = str(d.get("type", d.get("class", expected_class)))
		d.erase("type")
		d.erase("class")
		if cls.contains(","):
			cls = cls.split(",")[0]
		if cls == "" or not ClassDB.class_exists(cls) or not ClassDB.can_instantiate(cls):
			return fail("укажите класс ресурса в поле \"type\", например {\"type\": \"RectangleShape2D\", \"size\": [32, 32]}")
		if expected_class != "" and not expected_class.contains(",") and ClassDB.class_exists(expected_class) \
				and not ClassDB.is_parent_class(cls, expected_class):
			return fail("%s не подходит, нужен %s или его наследник" % [cls, expected_class])
		var obj: Object = ClassDB.instantiate(cls)
		var props = d.get("properties", d)
		if props is Dictionary:
			for k in props:
				if k == "properties": continue
				if not has_property(obj, k):
					return fail("у %s нет свойства \"%s\"" % [cls, k])
				var v := coerce_for(obj, k, props[k])
				if not v.ok:
					return fail("%s.%s: %s" % [cls, k, v.error])
				obj.set(k, v.value)
		return ok(obj)
	return fail("ожидается путь res://... или объект с полем \"type\"")


static func _enum_value(name: String, hint_string: String, flags: bool) -> Dictionary:
	var wanted := name.strip_edges().to_lower().replace("_", " ")
	var idx := 0
	for item in hint_string.split(","):
		var parts := item.split(":")
		var label := parts[0].strip_edges()
		var value := int(parts[1]) if parts.size() > 1 else (1 << idx if flags else idx)
		if label.to_lower().replace("_", " ") == wanted:
			return ok(value)
		idx += 1
	return fail("нет такого значения")


static func _enum_names(hint_string: String) -> String:
	var names: Array = []
	for item in hint_string.split(","):
		names.append(item.split(":")[0].strip_edges())
	return ", ".join(names)


## Короткое текстовое представление значения для ответов модели.
static func show(v) -> String:
	match typeof(v):
		TYPE_NIL: return "null"
		TYPE_STRING: return JSON.stringify(v)
		TYPE_VECTOR2, TYPE_VECTOR2I: return "[%s, %s]" % [_n(v.x), _n(v.y)]
		TYPE_VECTOR3, TYPE_VECTOR3I: return "[%s, %s, %s]" % [_n(v.x), _n(v.y), _n(v.z)]
		TYPE_COLOR: return "\"#%s\"" % (v as Color).to_html((v as Color).a < 1.0)
		TYPE_FLOAT: return _n(v)
		TYPE_OBJECT:
			if v == null: return "null"
			if v is Resource and (v as Resource).resource_path.begins_with("res://") and not (v as Resource).resource_path.contains("::"):
				return "\"%s\"" % (v as Resource).resource_path
			if v is Node: return "<%s>" % (v as Node).name
			return "{%s}" % (v as Object).get_class()
		TYPE_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			var s := var_to_str(v)
			return s if s.length() < 200 else s.substr(0, 200) + "…(%d эл.)" % v.size()
		_:
			var s2 := var_to_str(v)
			return s2 if s2.length() < 200 else s2.substr(0, 200) + "…"


static func _n(x) -> String:
	var f := float(x)
	if is_equal_approx(f, roundf(f)):
		return str(int(roundf(f)))
	return str(snappedf(f, 0.001))
