extends Logger
## Перехват сообщений редактора (Godot 4.5+, класс Logger).
## Грузится только если ClassDB.class_exists("Logger"), иначе этот файл не используется.
## Колбэки могут приходить из других потоков, поэтому доступ под мьютексом.

const MAX_LINES := 300

var _lines: PackedStringArray = []
var _total := 0  # сколько строк пришло за всё время (не сбрасывается при обрезке)
var _mutex := Mutex.new()


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
	var kind := "WARNING" if error_type == 1 else ("SCRIPT ERROR" if error_type == 2 else "ERROR")
	var text := rationale if rationale != "" else code
	var where := ""
	if file != "":
		where = " (%s:%d)" % [file, line]
	_push("%s: %s%s" % [kind, text, where])


func _log_message(message: String, error: bool) -> void:
	if error:
		_push("ERROR: " + message.strip_edges())


func _push(s: String) -> void:
	_mutex.lock()
	_lines.append(s)
	_total += 1
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
	_mutex.unlock()


## Номер "отметки", чтобы потом забрать только новые строки.
func mark() -> int:
	_mutex.lock()
	var n := _total
	_mutex.unlock()
	return n


func since(mark_value: int) -> PackedStringArray:
	_mutex.lock()
	var fresh := clampi(_total - mark_value, 0, _lines.size())
	var out := _lines.slice(_lines.size() - fresh)
	_mutex.unlock()
	return out


func clear() -> void:
	_mutex.lock()
	_lines.clear()
	_mutex.unlock()
