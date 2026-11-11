@tool
extends RefCounted
## Минимальный HTTP/1.1-сервер на TCPServer, только 127.0.0.1.
## Обслуживает POST /mcp (JSON-RPC). Каждое соединение закрывается после ответа.

const MAX_BODY := 4 * 1024 * 1024
const MAX_HEADER := 16 * 1024
const CONN_TIMEOUT_MS := 10000

## Callable(body: String) -> Dictionary {"status": int, "body": String}
var handler: Callable
## Пустая строка отключает проверку токена.
var token := ""

var _tcp := TCPServer.new()
var _conns: Array = []  # [{peer, buf, started}]
var _busy := false


## Пытается занять порт из диапазона [port, port+9]. Возвращает занятый порт или -1.
func start(port: int) -> int:
	for p in range(port, port + 10):
		if _tcp.listen(p, "127.0.0.1") == OK:
			return p
	return -1


func stop() -> void:
	for c in _conns:
		(c.peer as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	_tcp.stop()


func poll() -> void:
	# Сохранение сцены и запуск игры показывают прогресс-диалог, который крутит
	# главный цикл редактора изнутри обработчика. Без этой защиты _process
	# снова зайдёт сюда и обработает тот же запрос повторно.
	if _busy:
		return
	_busy = true
	_poll_inner()
	_busy = false


func _poll_inner() -> void:
	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		_conns.append({"peer": peer, "buf": PackedByteArray(), "started": Time.get_ticks_msec()})

	var still: Array = []
	for c in _conns:
		if _poll_conn(c):
			still.append(c)
	_conns = still


## true — соединение ещё живо и ждёт данных.
func _poll_conn(c: Dictionary) -> bool:
	var peer: StreamPeerTCP = c.peer
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	if Time.get_ticks_msec() - int(c.started) > CONN_TIMEOUT_MS:
		peer.disconnect_from_host()
		return false
	var avail := peer.get_available_bytes()
	if avail > 0:
		var res := peer.get_data(avail)
		if res[0] == OK:
			# PackedByteArray передаётся по значению, поэтому пишем обратно в словарь.
			var grown: PackedByteArray = c.buf
			grown.append_array(res[1])
			c.buf = grown

	var buf: PackedByteArray = c.buf
	var head_end := _find_header_end(buf)
	if head_end < 0:
		if buf.size() > MAX_HEADER:
			_send(peer, 431, "text/plain", "headers too large")
			return false
		return true

	var head := buf.slice(0, head_end).get_string_from_utf8()
	var lines := head.split("\r\n")
	var request_line := lines[0].split(" ")
	if request_line.size() < 2:
		_send(peer, 400, "text/plain", "bad request")
		return false
	var method := request_line[0]
	var path := request_line[1].split("?")[0]
	var headers := {}
	for i in range(1, lines.size()):
		var idx := lines[i].find(":")
		if idx > 0:
			headers[lines[i].substr(0, idx).strip_edges().to_lower()] = lines[i].substr(idx + 1).strip_edges()

	var length := int(headers.get("content-length", "0"))
	if length > MAX_BODY:
		_send(peer, 413, "text/plain", "body too large")
		return false
	var body_start := head_end + 4
	if buf.size() - body_start < length:
		return true  # ждём остаток тела

	var body := buf.slice(body_start, body_start + length).get_string_from_utf8()
	_dispatch(peer, method, path, headers, body)
	return false


func _dispatch(peer: StreamPeerTCP, method: String, path: String, headers: Dictionary, body: String) -> void:
	# Защита от DNS rebinding: браузерный Origin допускаем только локальный.
	var origin: String = headers.get("origin", "")
	if origin != "" and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost")):
		_send(peer, 403, "text/plain", "forbidden origin")
		return
	if path != "/mcp" and path != "/mcp/":
		_send(peer, 404, "text/plain", "use /mcp")
		return
	if token != "":
		var auth: String = headers.get("authorization", "")
		if auth != "Bearer " + token:
			_send(peer, 401, "text/plain", "missing or wrong token (см. local_mcp.json)")
			return
	match method:
		"POST":
			var res: Dictionary = handler.call(body)
			var status: int = res.get("status", 200)
			if status == 202:
				_send(peer, 202, "text/plain", "")
			else:
				_send(peer, status, "application/json", res.get("body", ""))
		"DELETE":
			_send(peer, 200, "text/plain", "")
		"GET":
			# Поток SSE не поддерживаем: сервер ничего не шлёт по своей инициативе.
			_send(peer, 405, "text/plain", "SSE not supported")
		_:
			_send(peer, 405, "text/plain", "method not allowed")


func _send(peer: StreamPeerTCP, status: int, ctype: String, body: String) -> void:
	var reason := {200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
		404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 431: "Request Header Fields Too Large",
		500: "Internal Server Error"}.get(status, "OK")
	var data := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [
		status, reason, ctype, data.size()]
	peer.put_data(head.to_utf8_buffer())
	if data.size() > 0:
		peer.put_data(data)
	peer.disconnect_from_host()


func _find_header_end(buf: PackedByteArray) -> int:
	var n := buf.size()
	for i in range(0, n - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1
