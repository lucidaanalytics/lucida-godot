## Pure Lucida client state: identity, consent gate, event building and the batch queue.
## No nodes, no network, no files: the autoload (lucida.gd) owns HTTP and persistence, so this
## part runs in headless tests. Wire format matches the other Lucida SDKs: POST /v1/batch with
## {api_key, batch, sent_at}; each event carries a uuid (v7) for at-least-once dedupe.
class_name LucidaCore
extends RefCounted

const LIB := "lucida-godot"
const LIB_VERSION := "0.1.0"
const MAX_BATCH := 100
const CATEGORIES := ["analytics", "replay", "flags"]

var api_key: String
var host: String
var flush_at := 20
var flush_interval_ms := 5000
var max_queue_size := 1000
var max_retries := 5
## "opt_out" (default, like every Lucida SDK): capture until the user opts out.
## "opt_in": nothing is captured or written to disk before opt_in().
var consent_mode := "opt_out"

var distinct_id := ""
var anon_id := ""
var identified := false
var session_id := ""
var session_last_ms := 0
var super_props: Dictionary = {}
var groups: Dictionary = {}
var consent: Dictionary = {}
var queue: Array = []
var attempt := 0
var dropped := 0

const SESSION_IDLE_MS := 30 * 60 * 1000


func _init(key: String, api_host: String = "https://app.lucida.dev", mode: String = "opt_out") -> void:
	api_key = key
	host = api_host.rstrip("/")
	consent_mode = mode
	for c in CATEGORIES:
		consent[c] = mode == "opt_out"
	anon_id = uuid_v7(now_ms())
	distinct_id = anon_id


static func now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


## UUID v7: 48-bit ms timestamp, version and variant bits, random rest.
static func uuid_v7(ms: int) -> String:
	var b := PackedByteArray()
	b.resize(16)
	for i in 6:
		b[i] = (ms >> (8 * (5 - i))) & 0xff
	for i in range(6, 16):
		b[i] = randi() & 0xff
	b[6] = (b[6] & 0x0f) | 0x70
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]


static func iso(ms: int) -> String:
	var s := Time.get_datetime_string_from_unix_time(ms / 1000, false)
	return "%s.%03dZ" % [s, ms % 1000]


func has_consent(category: String = "analytics") -> bool:
	return consent.get(category, false)


## Storage may be written only when analytics consent is held.
func may_persist() -> bool:
	return has_consent("analytics")


## Drops caller-supplied `$lc_*` keys: they are reserved for the gateway.
static func strip_reserved(props: Dictionary) -> Dictionary:
	var out := {}
	for k in props:
		if not str(k).begins_with("$lc_"):
			out[k] = props[k]
	return out


func touch_session(ms: int) -> String:
	if session_id == "" or ms - session_last_ms > SESSION_IDLE_MS:
		session_id = uuid_v7(ms)
	session_last_ms = ms
	return session_id


## Builds and queues one event; returns it, or {} when consent blocks capture.
func capture(event: String, props: Dictionary = {}, set_props: Dictionary = {}, set_once: Dictionary = {}) -> Dictionary:
	if not has_consent("analytics"):
		return {}
	var ms := now_ms()
	var p := strip_reserved(super_props)
	p.merge(strip_reserved(props), true)
	p["$lib"] = LIB
	p["$lib_version"] = LIB_VERSION
	p["$session_id"] = touch_session(ms)
	p["$os"] = OS.get_name()
	var e := {"uuid": uuid_v7(ms), "event": event, "distinct_id": distinct_id, "timestamp": iso(ms), "properties": p}
	if not set_props.is_empty():
		e["$set"] = strip_reserved(set_props)
	if not set_once.is_empty():
		e["$set_once"] = strip_reserved(set_once)
	if not groups.is_empty():
		e["$groups"] = groups.duplicate()
	enqueue(e)
	return e


func enqueue(e: Dictionary) -> void:
	queue.append(e)
	if queue.size() > max_queue_size:
		var n := queue.size() - max_queue_size
		queue = queue.slice(n)
		dropped += n


func identify(id: String, set_props: Dictionary = {}, set_once: Dictionary = {}) -> void:
	if id == "" or not has_consent("analytics"):
		return
	var props := {}
	if not identified and distinct_id != id:
		props["$anon_distinct_id"] = distinct_id
	distinct_id = id
	identified = true
	capture("$identify", props, set_props, set_once)


func alias(new_alias: String) -> void:
	capture("$create_alias", {"alias": new_alias, "distinct_id": distinct_id})


func group(type: String, key: String, props: Dictionary = {}) -> void:
	groups[type] = key
	capture("$groupidentify", {"$group_type": type, "$group_key": key, "$group_set": strip_reserved(props)})


func screen(name: String, props: Dictionary = {}) -> void:
	var p := props.duplicate()
	p["$screen_name"] = name
	capture("$screen", p)


func reset() -> void:
	anon_id = uuid_v7(now_ms())
	distinct_id = anon_id
	identified = false
	session_id = ""
	groups.clear()
	super_props.clear()


## Records a consent decision. Granting captures $opt_in; revoking captures $opt_out (sent with
## what is queued) and then nothing more is captured or stored.
func set_consent(granted: bool) -> void:
	var was := has_consent("analytics")
	if was and not granted:
		capture("$opt_out")
	for c in CATEGORIES:
		consent[c] = granted
	if not was and granted:
		capture("$opt_in")


func should_flush() -> bool:
	return queue.size() >= flush_at


## The next request body ({} when empty) and how many events it holds.
func next_batch() -> Dictionary:
	if queue.is_empty():
		return {}
	var batch := queue.slice(0, mini(queue.size(), MAX_BATCH))
	return {"count": batch.size(), "body": JSON.stringify({"api_key": api_key, "batch": batch, "sent_at": iso(now_ms())})}


static func retryable(status: int) -> bool:
	return status == 0 or status == 408 or status == 429 or status >= 500


## Settles a sent batch; returns the retry delay in ms (0 = no retry needed).
func settle(count: int, status: int) -> int:
	if status >= 200 and status <= 299:
		queue = queue.slice(count)
		attempt = 0
		return 0
	if not retryable(status) or attempt >= max_retries:
		queue = queue.slice(count)
		dropped += count
		attempt = 0
		return 0
	attempt += 1
	var cap := mini(1000 * (1 << attempt), 30000)
	return int(cap * randf_range(0.5, 1.0))


## Persisted state (identity, consent, queue) as JSON; restored by restore().
func serialize() -> String:
	return JSON.stringify({"distinct_id": distinct_id, "anon_id": anon_id, "identified": identified, "consent": consent,
		"groups": groups, "super_props": super_props, "queue": queue})


func restore(text: String) -> void:
	var d = _parse_json(text)
	if typeof(d) != TYPE_DICTIONARY:
		return
	distinct_id = str(d.get("distinct_id", distinct_id))
	anon_id = str(d.get("anon_id", anon_id))
	identified = bool(d.get("identified", false))
	if typeof(d.get("consent")) == TYPE_DICTIONARY:
		consent.merge(d["consent"], true)
	if typeof(d.get("groups")) == TYPE_DICTIONARY:
		groups = d["groups"]
	if typeof(d.get("super_props")) == TYPE_DICTIONARY:
		super_props = d["super_props"]
	if typeof(d.get("queue")) == TYPE_ARRAY:
		queue = d["queue"]


## Body for POST /v1/flags.
func flags_body() -> String:
	var b := {"api_key": api_key, "distinct_id": distinct_id, "groups": groups, "person_properties": {}}
	if identified and anon_id != distinct_id:
		b["anon_distinct_id"] = anon_id
	return JSON.stringify(b)


## Parses a /v1/flags response into {key: value} and {key: payload}.
static func parse_flags(text: String) -> Array:
	var values := {}
	var payloads := {}
	var j = _parse_json(text)
	if typeof(j) != TYPE_DICTIONARY or typeof(j.get("flags")) != TYPE_DICTIONARY:
		return [values, payloads]
	for k in j["flags"]:
		var m = j["flags"][k]
		if typeof(m) != TYPE_DICTIONARY:
			values[k] = m
			continue
		if m.get("value") != null:
			values[k] = m["value"]
		elif m.get("variant") != null:
			values[k] = m["variant"]
		else:
			values[k] = m.get("enabled", false) == true
		if m.get("payload") != null:
			payloads[k] = m["payload"]
	return [values, payloads]


## JSON.parse_string logs an engine error on bad input; a JSON instance fails quietly (null).
static func _parse_json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
