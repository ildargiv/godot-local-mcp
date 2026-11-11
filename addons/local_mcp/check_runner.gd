extends SceneTree
## Run by the project_check tool in a separate headless Godot process:
##   godot --headless --no-header --path <project> --script res://addons/local_mcp/check_runner.gd -- [res://path] [addons]
## Compiles every .gd file and prints markers around it. The engine prints the errors itself
## ("SCRIPT ERROR: Parse Error: ... at: GDScript::reload (res://x.gd:3)") and the editor parses them.
## This way error text with line numbers works on every 4.x version, not only with Logger (4.5+).

const SKIP_DIRS := ["res://.godot", "res://addons/local_mcp"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var root := "res://"
	var include_addons := false
	for a in args:
		if a == "addons":
			include_addons = true
		elif a.begins_with("res://"):
			root = a
	var files: Array = []
	if root.ends_with(".gd"):
		files.append(root)
	else:
		# A path given explicitly inside addons/ is checked anyway.
		_collect(root, files, include_addons or root.begins_with("res://addons"))
	files.sort()
	for p in files:
		print("@@FILE ", p)
		var s := GDScript.new()
		s.source_code = FileAccess.get_file_as_string(p)
		s.resource_path = p
		var err := s.reload()
		print("@@RESULT ", p, " ", err)
	print("@@DONE ", files.size())
	quit()


func _collect(dir: String, out: Array, include_addons: bool) -> void:
	if dir in SKIP_DIRS or (not include_addons and dir == "res://addons"):
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	if FileAccess.file_exists(dir.path_join(".gdignore")):
		return
	for f in d.get_files():
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if not sub.begins_with("."):
			_collect(dir.path_join(sub), out, include_addons)
