@tool
extends RefCounted

const L := preload("res://addons/local_mcp/lang.gd")
## Group "tilemap": tileset from an image, painting cells, reading the map as text.
## Works with TileMapLayer (Godot 4.3+) and the old TileMap (layer 0).

const Values := preload("res://addons/local_mcp/values.gd")
const MAX_READ_W := 64
const MAX_READ_H := 40
const MAX_CELLS := 4096
const CHARS := "#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@$%&*+=?"

var t  # tools.gd


func defs() -> Array:
	var s = t._s
	return [
		t._tool("tilemap_setup", "Make a tile map ready to paint: creates the TileMapLayer if needed and a TileSet from a tile sheet image. collision adds a full square collider to every tile.",
			{"path": s.call("string", "TileMapLayer node, e.g. \"Ground\". Created under the root if missing."),
			"texture": s.call("string", "Tile sheet image, res://... .png/.svg"),
			"tile_size": s.call("array", "Tile size in pixels, e.g. [16, 16]."),
			"collision": s.call("boolean", "Add physics collision to all tiles.")}, ["path", "texture", "tile_size"]),
		t._tool("tilemap_info", "Show a tile map: tile size, available tiles (atlas coords) and painted area.",
			{"path": s.call("string")}, ["path"], true),
		t._tool("tilemap_paint", "Paint tiles. Give cells [[x, y], ...] and/or rect [x1, y1, x2, y2] (inclusive). tile is the atlas coord [col, row] from tilemap_info. erase=true clears cells.",
			{"path": s.call("string"), "tile": s.call("array", "Atlas coords [col, row], default [0, 0]."),
			"cells": s.call("array", "List of cells [[x, y], ...]."), "rect": s.call("array", "[x1, y1, x2, y2]"),
			"erase": s.call("boolean")}, ["path"]),
		t._tool("tilemap_read", "Show painted cells as a text grid with a legend. rect [x1, y1, x2, y2] limits the area.",
			{"path": s.call("string"), "rect": s.call("array")}, ["path"], true),
	]


# ─────────────────────────── cell access (TileMapLayer / TileMap) ───────────────────────────

static func _is_map(n: Node) -> bool:
	return n.is_class("TileMapLayer") or n is TileMap


static func _get_cell(n: Node, c: Vector2i) -> Array:
	if n is TileMap:
		return [n.get_cell_source_id(0, c), n.get_cell_atlas_coords(0, c), n.get_cell_alternative_tile(0, c)]
	return [n.call("get_cell_source_id", c), n.call("get_cell_atlas_coords", c), n.call("get_cell_alternative_tile", c)]


static func _set_cell(n: Node, c: Vector2i, sid: int, atlas: Vector2i, alt: int) -> void:
	if n is TileMap:
		n.set_cell(0, c, sid, atlas, alt)
	else:
		n.call("set_cell", c, sid, atlas, alt)


static func _used_cells(n: Node) -> Array:
	return n.get_used_cells(0) if n is TileMap else n.call("get_used_cells")


## For UndoRedo: apply a list of [Vector2i, sid, atlas, alt].
func apply_cells(n: Node, data: Array) -> void:
	if not is_instance_valid(n):
		return
	for d in data:
		_set_cell(n, d[0], d[1], d[2], d[3])


func _map(path) -> Dictionary:
	var f: Dictionary = t._find(path)
	if f.has("error"):
		return f
	if not _is_map(f.node):
		return {"error": L.t("%s is %s, but a TileMapLayer is needed. Create one with tilemap_setup") % [t._rel(f.node), f.node.get_class()]}
	return f


static func _vec2i(raw, label: String) -> Dictionary:
	var v := Values.coerce(raw, TYPE_VECTOR2I)
	if not v.ok:
		return {"error": "%s: %s" % [label, v.error]}
	return {"value": v.value}


static func _json(raw):
	if raw is String:
		var p = JSON.parse_string(raw)
		if p != null:
			return p
	return raw


func _first_source(ts: TileSet) -> int:
	return ts.get_source_id(0) if ts and ts.get_source_count() > 0 else -1


# ─────────────────────────── tools ───────────────────────────

func _t_tilemap_setup(args: Dictionary) -> Dictionary:
	var root: Node = t._root()
	if root == null:
		return t._no_scene()
	var tex_path: Dictionary = t._res_path(args.texture)
	if tex_path.has("error"):
		return t._err(tex_path.error)
	if not ResourceLoader.exists(tex_path.path):
		return t._err(L.t("image not found: ") + tex_path.path)
	var tex = load(tex_path.path)
	if not tex is Texture2D:
		return t._err(L.t("%s is not an image") % tex_path.path)
	var size := _vec2i(_json(args.tile_size), "tile_size")
	if size.has("error"):
		return t._err(size.error)
	var ts_px: Vector2i = size.value
	if ts_px.x <= 0 or ts_px.y <= 0:
		return t._err(L.t("tile_size must be greater than zero, e.g. [16, 16]"))
	var tex_size := Vector2i((tex as Texture2D).get_size())
	var cols := tex_size.x / ts_px.x
	var rows := tex_size.y / ts_px.y
	if cols < 1 or rows < 1:
		return t._err(L.t("image %dx%d is smaller than one tile %dx%d") % [tex_size.x, tex_size.y, ts_px.x, ts_px.y])

	var tileset := TileSet.new()
	tileset.tile_size = ts_px
	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = ts_px
	var sid := tileset.add_source(src)
	for y in rows:
		for x in cols:
			src.create_tile(Vector2i(x, y))
	var collision := bool(args.get("collision", false))
	if collision:
		tileset.add_physics_layer()
		var hx := ts_px.x / 2.0
		var hy := ts_px.y / 2.0
		var square := PackedVector2Array([Vector2(-hx, -hy), Vector2(hx, -hy), Vector2(hx, hy), Vector2(-hx, hy)])
		for y in rows:
			for x in cols:
				var td := src.get_tile_data(Vector2i(x, y), 0)
				td.add_collision_polygon(0)
				td.set_collision_polygon_points(0, 0, square)

	var ur: EditorUndoRedoManager = t._ur()
	var f: Dictionary = t._find(args.path)
	var node: Node
	var created := false
	if f.has("node"):
		node = f.node
		if not _is_map(node):
			return t._err(L.t("%s is %s, not a TileMapLayer") % [t._rel(node), node.get_class()])
	else:
		var p := str(args.path).strip_edges().trim_prefix("./")
		var parent: Node = root
		if p.contains("/"):
			var pf: Dictionary = t._find(p.get_base_dir())
			if pf.has("error"):
				return t._err(pf.error)
			parent = pf.node
		node = ClassDB.instantiate("TileMapLayer") if ClassDB.class_exists("TileMapLayer") else TileMap.new()
		node.name = p.get_file().validate_node_name()
		created = true
		ur.create_action(L.t("MCP: tilemap ") + str(node.name), UndoRedo.MERGE_DISABLE, root)
		ur.add_do_method(parent, "add_child", node, true)
		ur.add_do_method(node, "set_owner", root)
		ur.add_do_reference(node)
		ur.add_undo_method(parent, "remove_child", node)
		ur.commit_action()
	ur.create_action(L.t("MCP: tileset ") + str(node.name), UndoRedo.MERGE_DISABLE, root)
	ur.add_do_property(node, "tile_set", tileset)
	ur.add_undo_property(node, "tile_set", node.tile_set)
	ur.add_do_reference(tileset)
	ur.commit_action()
	return t._ok(L.t("%s %s: tileset %dx%d px from %s, %d tiles (%d columns, %d rows, atlas coords from [0, 0] to [%d, %d])%s, source %d") % [
		L.t("Created") if created else L.t("Set up"), t._rel(node), ts_px.x, ts_px.y, tex_path.path, cols * rows, cols, rows,
		cols - 1, rows - 1, L.t(", with collision") if collision else "", sid])


func _t_tilemap_info(args: Dictionary) -> Dictionary:
	var f := _map(args.path)
	if f.has("error"):
		return t._err(f.error)
	var n: Node = f.node
	var ts: TileSet = n.tile_set
	var lines: Array = ["%s (%s)" % [t._rel(n), n.get_class()]]
	if ts == null:
		lines.append(L.t("No tileset. Create one with tilemap_setup"))
		return t._ok("\n".join(lines))
	lines.append(L.t("Tile size: %dx%d, physics layers: %d") % [ts.tile_size.x, ts.tile_size.y, ts.get_physics_layers_count()])
	for i in ts.get_source_count():
		var sid := ts.get_source_id(i)
		var src := ts.get_source(sid)
		if src is TileSetAtlasSource:
			var a: TileSetAtlasSource = src
			var coords: Array = []
			for k in a.get_tiles_count():
				var c := a.get_tile_id(k)
				coords.append("[%d, %d]" % [c.x, c.y])
			var tex_path: String = a.texture.resource_path if a.texture else "?"
			lines.append(L.t("Source %d: atlas %s, %d tiles: %s%s") % [sid, tex_path, coords.size(), ", ".join(coords.slice(0, 64)),
				" …" if coords.size() > 64 else ""])
		else:
			lines.append("Source %d: %s" % [sid, src.get_class()])
	var used := _used_cells(n)
	if used.is_empty():
		lines.append(L.t("No painted cells"))
	else:
		var r := _bounds(used)
		lines.append(L.t("Painted cells: %d, area [%d, %d] .. [%d, %d]") % [used.size(), r.position.x, r.position.y, r.end.x - 1, r.end.y - 1])
	return t._ok("\n".join(lines))


static func _bounds(cells: Array) -> Rect2i:
	var minp := Vector2i(cells[0])
	var maxp := Vector2i(cells[0])
	for c in cells:
		minp = Vector2i(mini(minp.x, c.x), mini(minp.y, c.y))
		maxp = Vector2i(maxi(maxp.x, c.x), maxi(maxp.y, c.y))
	return Rect2i(minp, maxp - minp + Vector2i.ONE)


func _collect_cells(args: Dictionary) -> Dictionary:
	var cells: Array = []
	var raw_cells = _json(args.get("cells"))
	if raw_cells != null:
		if raw_cells is Array and raw_cells.size() >= 2 and (raw_cells[0] is float or raw_cells[0] is int):
			raw_cells = [raw_cells]  # a single cell [x, y]
		if not raw_cells is Array:
			return {"error": L.t("cells must be a list [[x, y], ...]")}
		for c in raw_cells:
			var v := _vec2i(c, "cells")
			if v.has("error"):
				return v
			cells.append(v.value)
	var raw_rect = _json(args.get("rect"))
	if raw_rect != null:
		var nums: Array = []
		if raw_rect is Array and raw_rect.size() == 2 and raw_rect[0] is Array:
			nums = raw_rect[0] + raw_rect[1]  # [[x1, y1], [x2, y2]]
		elif raw_rect is Array:
			nums = raw_rect
		elif raw_rect is Dictionary:
			nums = [raw_rect.get("x1", raw_rect.get("x", 0)), raw_rect.get("y1", raw_rect.get("y", 0)),
				raw_rect.get("x2", 0), raw_rect.get("y2", 0)]
		if nums.size() != 4:
			return {"error": L.t("rect must be [x1, y1, x2, y2]")}
		var x1 := int(nums[0])
		var y1 := int(nums[1])
		var x2 := int(nums[2])
		var y2 := int(nums[3])
		if (absi(x2 - x1) + 1) * (absi(y2 - y1) + 1) > MAX_CELLS:
			return {"error": L.t("area too large, at most %d cells per call") % MAX_CELLS}
		for y in range(mini(y1, y2), maxi(y1, y2) + 1):
			for x in range(mini(x1, x2), maxi(x1, x2) + 1):
				cells.append(Vector2i(x, y))
	if cells.is_empty():
		return {"error": L.t("give cells [[x, y], ...] or rect [x1, y1, x2, y2]")}
	if cells.size() > MAX_CELLS:
		return {"error": L.t("too many cells, at most %d per call") % MAX_CELLS}
	return {"cells": cells}


func _t_tilemap_paint(args: Dictionary) -> Dictionary:
	var f := _map(args.path)
	if f.has("error"):
		return t._err(f.error)
	var n: Node = f.node
	var ts: TileSet = n.tile_set
	var erase := bool(args.get("erase", false))
	if ts == null and not erase:
		return t._err(L.t("%s has no tileset. Run tilemap_setup first") % t._rel(n))
	var cc := _collect_cells(args)
	if cc.has("error"):
		return t._err(cc.error)
	var sid := int(args.get("source", _first_source(ts)))
	var atlas := Vector2i(-1, -1)
	if not erase:
		var tv := _vec2i(_json(args.get("tile", [0, 0])), "tile")
		if tv.has("error"):
			return t._err(tv.error)
		atlas = tv.value
		var src := ts.get_source(sid) if ts.has_source(sid) else null
		if src == null:
			return t._err(L.t("no source %d in the tileset") % sid)
		if src is TileSetAtlasSource and not (src as TileSetAtlasSource).has_tile(atlas):
			var a: TileSetAtlasSource = src
			var size := a.get_atlas_grid_size()
			return t._err(L.t("the atlas has no tile [%d, %d]. Available from [0, 0] to [%d, %d] (see tilemap_info)") % [atlas.x, atlas.y, size.x - 1, size.y - 1])
	var do_data: Array = []
	var undo_data: Array = []
	for c in cc.cells:
		var old := _get_cell(n, c)
		undo_data.append([c, old[0], old[1], old[2]])
		do_data.append([c, -1 if erase else sid, atlas, 0])
	var ur: EditorUndoRedoManager = t._ur()
	ur.create_action(L.t("MCP: tiles ") + str(n.name), UndoRedo.MERGE_DISABLE, t._root())
	ur.add_do_method(self, "apply_cells", n, do_data)
	ur.add_undo_method(self, "apply_cells", n, undo_data)
	ur.commit_action()
	var r := _bounds(cc.cells)
	return t._ok(L.t("%s %d cells in %s (area [%d, %d] .. [%d, %d])%s") % [
		L.t("Erased") if erase else L.t("Painted"), cc.cells.size(), t._rel(n), r.position.x, r.position.y, r.end.x - 1, r.end.y - 1,
		"" if erase else L.t(", tile [%d, %d]") % [atlas.x, atlas.y]])


func _t_tilemap_read(args: Dictionary) -> Dictionary:
	var f := _map(args.path)
	if f.has("error"):
		return t._err(f.error)
	var n: Node = f.node
	var used := _used_cells(n)
	var area: Rect2i
	var raw_rect = _json(args.get("rect"))
	if raw_rect is Array and raw_rect.size() == 4:
		var x1 := int(raw_rect[0])
		var y1 := int(raw_rect[1])
		area = Rect2i(Vector2i(mini(x1, int(raw_rect[2])), mini(y1, int(raw_rect[3]))),
			Vector2i(absi(int(raw_rect[2]) - x1) + 1, absi(int(raw_rect[3]) - y1) + 1))
	elif used.is_empty():
		return t._ok(L.t("%s: no painted cells") % t._rel(n))
	else:
		area = _bounds(used)
	var cut := ""
	if area.size.x > MAX_READ_W or area.size.y > MAX_READ_H:
		cut = L.t("\n(showing the %dx%d corner of %dx%d, narrow it with rect)") % [mini(area.size.x, MAX_READ_W), mini(area.size.y, MAX_READ_H), area.size.x, area.size.y]
		area.size = Vector2i(mini(area.size.x, MAX_READ_W), mini(area.size.y, MAX_READ_H))
	var legend := {}
	var rows: Array = []
	for y in range(area.position.y, area.end.y):
		var row := ""
		for x in range(area.position.x, area.end.x):
			var cell := _get_cell(n, Vector2i(x, y))
			if int(cell[0]) < 0:
				row += "."
				continue
			var key := "%d:%d,%d" % [cell[0], cell[1].x, cell[1].y]
			if not legend.has(key):
				legend[key] = CHARS[mini(legend.size(), CHARS.length() - 1)]
			row += legend[key]
		rows.append("%4d %s" % [y, row])
	var leg: Array = []
	for k in legend:
		var parts: PackedStringArray = k.split(":")
		var xy: PackedStringArray = parts[1].split(",")
		leg.append(L.t("%s = tile [%s, %s]%s") % [legend[k], xy[0], xy[1], (" (source %s)" % parts[0]) if parts[0] != str(_first_source(n.tile_set)) else ""])
	var header := L.t("%s: x from %d to %d, y from %d to %d. \".\" is empty") % [t._rel(n), area.position.x, area.end.x - 1, area.position.y, area.end.y - 1]
	return t._ok(header + "\n" + "\n".join(rows) + "\n" + ", ".join(leg) + cut)
