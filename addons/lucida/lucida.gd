## Lucida autoload (registered as `Lucida` by plugin.gd). Call Lucida.setup("lc_pk_...") once,
## then Lucida.capture(...). Owns the network (HTTPRequest), the flush Timer and the `user://`
## state file; LucidaCore holds everything else. Nothing is written to disk before analytics
## consent (opt_in mode), and opting out deletes the state file.
extends Node

signal flags_loaded(values: Dictionary)

const STATE_PATH := "user://lucida_state.json"

var core: LucidaCore
var flag_values: Dictionary = {}
var flag_payloads: Dictionary = {}
var _called: Dictionary = {}
var _timer: Timer
var _http: HTTPRequest
var _flags_http: HTTPRequest
var _in_flight := 0
var _retry_at := 0


## opts: api_host, consent ("opt_out" default | "opt_in"), flush_at, flush_interval_ms,
## max_queue_size, preload_flags (default true).
func setup(api_key: String, opts: Dictionary = {}) -> void:
	core = LucidaCore.new(api_key, opts.get("api_host", "https://app.lucida.dev"), opts.get("consent", "opt_out"))
	core.flush_at = opts.get("flush_at", core.flush_at)
	core.flush_interval_ms = opts.get("flush_interval_ms", core.flush_interval_ms)
	core.max_queue_size = opts.get("max_queue_size", core.max_queue_size)
	if FileAccess.file_exists(STATE_PATH):
		var f := FileAccess.open(STATE_PATH, FileAccess.READ)
		if f:
			core.restore(f.get_as_text())
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_batch_done)
	add_child(_http)
	_flags_http = HTTPRequest.new()
	_flags_http.request_completed.connect(_on_flags_done)
	add_child(_flags_http)
	_timer = Timer.new()
	_timer.wait_time = core.flush_interval_ms / 1000.0
	_timer.timeout.connect(flush)
	add_child(_timer)
	_timer.start()
	capture("$app_opened")
	if opts.get("preload_flags", true):
		reload_flags()


func _notification(what: int) -> void:
	if core == null:
		return
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			capture("$app_backgrounded")
			flush()
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			capture("$app_opened", {"from_background": true})
		NOTIFICATION_WM_CLOSE_REQUEST:
			capture("$app_closed")
			_persist() # unsent events stay in the state file and go out on the next launch


func capture(event: String, props: Dictionary = {}) -> void:
	if core == null:
		return
	core.capture(event, _with_flags(props))
	_after_change()


func screen(name: String, props: Dictionary = {}) -> void:
	core.screen(name, props)
	_after_change()


func identify(id: String, set_props: Dictionary = {}, set_once: Dictionary = {}) -> void:
	core.identify(id, set_props, set_once)
	_after_change()
	reload_flags()


func alias(new_alias: String) -> void:
	core.alias(new_alias)
	_after_change()


func group(type: String, key: String, props: Dictionary = {}) -> void:
	core.group(type, key, props)
	_after_change()
	reload_flags()


func register(props: Dictionary) -> void:
	core.super_props.merge(LucidaCore.strip_reserved(props), true)
	_persist()


func reset() -> void:
	core.reset()
	flag_values.clear()
	_persist()
	reload_flags()


func opt_in() -> void:
	core.set_consent(true)
	_after_change()
	reload_flags()


func opt_out() -> void:
	core.set_consent(false)
	flush() # the $opt_out event goes out with what was queued
	if FileAccess.file_exists(STATE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE_PATH))


func is_opted_out() -> bool:
	return not core.has_consent("analytics")


func get_flag(key: String):
	var v = flag_values.get(key)
	var mark := "%s=%s" % [key, str(v)]
	if not _called.has(mark):
		_called[mark] = true
		core.capture("$feature_flag_called", {"$feature_flag": key, "$feature_flag_response": v if v != null else false})
	return v


func is_feature_enabled(key: String) -> bool:
	var v = get_flag(key)
	return v != null and v != false


func get_flag_payload(key: String):
	return flag_payloads.get(key)


func reload_flags() -> void:
	if core == null or not core.has_consent("analytics") or _flags_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	_flags_http.request(core.host + "/v1/flags", ["Content-Type: application/json"], HTTPClient.METHOD_POST, core.flags_body())


func flush() -> void:
	if core == null or _in_flight > 0 or LucidaCore.now_ms() < _retry_at:
		return
	var b := core.next_batch()
	if b.is_empty():
		return
	_in_flight = b["count"]
	var err := _http.request(core.host + "/v1/batch", ["Content-Type: application/json"], HTTPClient.METHOD_POST, b["body"])
	if err != OK:
		_on_batch_done(HTTPRequest.RESULT_CANT_CONNECT, 0, [], PackedByteArray())


func _with_flags(props: Dictionary) -> Dictionary:
	var p := props.duplicate()
	for k in flag_values:
		p["$feature/" + str(k)] = flag_values[k]
	return p


func _after_change() -> void:
	_persist()
	if core.should_flush():
		flush()


func _persist() -> void:
	if core == null or not core.may_persist():
		return # consent first: no disk write before analytics consent
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(core.serialize())


func _on_batch_done(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var status := code if result == HTTPRequest.RESULT_SUCCESS else 0
	var delay := core.settle(_in_flight, status)
	_in_flight = 0
	_retry_at = LucidaCore.now_ms() + delay if delay > 0 else 0
	_persist()


func _on_flags_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code > 299:
		return # keep cached values
	var parsed := LucidaCore.parse_flags(body.get_string_from_utf8())
	flag_values = parsed[0]
	flag_payloads = parsed[1]
	flags_loaded.emit(flag_values)
