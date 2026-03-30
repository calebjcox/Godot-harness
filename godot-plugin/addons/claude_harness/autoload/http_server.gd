## Pure GDScript HTTP/1.0 server built on Godot's TCPServer.
## Accepts one connection at a time per poll cycle.
## Emits request_received when a complete HTTP request is parsed.
## Callers send responses via the static send_json / send_error helpers,
## which close the connection after writing (HTTP/1.0 style).
extends Node

signal request_received(conn: StreamPeerTCP, method: String, path: String,
		params: Dictionary, body: String)

var _server := TCPServer.new()
var _connections: Array = []        # active StreamPeerTCP objects
var _buffers: Dictionary = {}       # instance_id -> accumulated String

func start(port: int) -> bool:
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("ClaudeHarness: Failed to listen on port %d (error %d)" % [port, err])
	return err == OK

func stop() -> void:
	_server.stop()
	for conn in _connections:
		conn.disconnect_from_host()
	_connections.clear()
	_buffers.clear()

func _process(_delta: float) -> void:
	# Accept new connections
	while _server.is_connection_available():
		var conn: StreamPeerTCP = _server.take_connection()
		_connections.append(conn)
		_buffers[conn.get_instance_id()] = ""

	# Service existing connections
	for conn in _connections.duplicate():
		var status := conn.get_status()
		if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			_drop_connection(conn)
			continue

		var available := conn.get_available_bytes()
		if available > 0:
			var chunk := conn.get_utf8_string(available)
			var iid := conn.get_instance_id()
			_buffers[iid] = _buffers.get(iid, "") + chunk
			_try_parse(_buffers[iid], conn)

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

func _try_parse(buf: String, conn: StreamPeerTCP) -> void:
	var header_end := buf.find("\r\n\r\n")
	if header_end == -1:
		return  # incomplete headers — wait for more data

	var header_section := buf.left(header_end)
	var body_offset := header_end + 4

	var lines := header_section.split("\r\n")
	if lines.is_empty():
		_send_error_static(conn, 400, "Bad Request")
		_drop_connection(conn)
		return

	# Request line
	var req_parts := lines[0].split(" ")
	if req_parts.size() < 2:
		_send_error_static(conn, 400, "Bad Request")
		_drop_connection(conn)
		return

	var method := req_parts[0].to_upper()
	var raw_path := req_parts[1]

	# Query string
	var path := raw_path
	var params: Dictionary = {}
	if "?" in raw_path:
		var qparts := raw_path.split("?", true, 1)
		path = qparts[0]
		for pair in qparts[1].split("&"):
			var kv := pair.split("=", true, 1)
			if kv.size() == 2:
				params[kv[0].uri_decode()] = kv[1].uri_decode()
			elif kv.size() == 1 and kv[0] != "":
				params[kv[0].uri_decode()] = ""

	# Headers
	var headers: Dictionary = {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0:
			var key := lines[i].left(colon).strip_edges().to_lower()
			var val := lines[i].substr(colon + 1).strip_edges()
			headers[key] = val

	# Body
	var content_length := int(headers.get("content-length", "0"))
	var body := ""
	if content_length > 0:
		var remaining := buf.substr(body_offset)
		if remaining.length() < content_length:
			return  # incomplete body — wait for more data
		body = remaining.left(content_length)

	# Request is complete — remove from tracking before emitting
	# (the handler takes ownership of the connection for the async response)
	_drop_connection(conn)

	request_received.emit(conn, method, path, params, body)

func _drop_connection(conn: StreamPeerTCP) -> void:
	_connections.erase(conn)
	_buffers.erase(conn.get_instance_id())

# ---------------------------------------------------------------------------
# Static response helpers — call these from anywhere with a conn reference
# ---------------------------------------------------------------------------

static func send_json(conn: StreamPeerTCP, data: Variant, status: int = 200) -> void:
	var body := JSON.stringify(data)
	var body_bytes := body.to_utf8_buffer()
	var status_text := "OK" if status == 200 else "Error"
	var header := (
		"HTTP/1.0 %d %s\r\n" % [status, status_text]
		+ "Content-Type: application/json\r\n"
		+ "Content-Length: %d\r\n" % body_bytes.size()
		+ "Access-Control-Allow-Origin: *\r\n"
		+ "Connection: close\r\n"
		+ "\r\n"
	)
	conn.put_data(header.to_utf8_buffer())
	conn.put_data(body_bytes)
	# Flush and close
	conn.disconnect_from_host()

static func _send_error_static(conn: StreamPeerTCP, status: int, message: String) -> void:
	send_json(conn, {"error": message}, status)
