## Headless checks of the pure client (LucidaCore). Run from sdks/godot:
##   godot --headless -s tests/test_lucida.gd
## Exits 0 when every check passes, 1 otherwise.
extends SceneTree

const Core := preload("res://addons/lucida/lucida_core.gd")

var failures := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", what)


func _init() -> void:
	test_event_shape()
	test_opt_in_gates_capture_and_storage()
	test_identify_links_anon_id()
	test_batching_and_retry()
	test_serialization_round_trip()
	test_flags()
	test_scripts_compile()
	print("lucida godot tests: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)


func test_event_shape() -> void:
	var c = Core.new("lc_pk_test", "https://example.test/")
	check(c.host == "https://example.test", "trailing slash trimmed")
	var e: Dictionary = c.capture("level_complete", {"level": 3, "$lc_project": "spoof"})
	check(e["event"] == "level_complete", "event name")
	check(e["uuid"].length() == 36 and e["uuid"][14] == "7", "uuid v7")
	check(e["distinct_id"] == c.anon_id, "anonymous distinct id")
	check(e["properties"]["$lib"] == "lucida-godot", "$lib")
	check(not e["properties"].has("$lc_project"), "reserved $lc_ props stripped")
	check(e["properties"]["$session_id"] != "", "session id")
	check(e["timestamp"].ends_with("Z"), "ISO timestamp")


func test_opt_in_gates_capture_and_storage() -> void:
	var c = Core.new("k", "https://example.test", "opt_in")
	check(c.capture("early").is_empty(), "no capture before consent")
	check(c.queue.is_empty(), "nothing queued before consent")
	check(not c.may_persist(), "no storage write before consent")
	c.set_consent(true)
	check(c.may_persist(), "storage allowed after consent")
	check(c.queue.size() == 1 and c.queue[0]["event"] == "$opt_in", "$opt_in captured")
	c.set_consent(false)
	check(c.queue[-1]["event"] == "$opt_out", "$opt_out captured on revoke")
	check(c.capture("after").is_empty(), "no capture after opt out")
	check(not c.may_persist(), "no storage after opt out")
	var d = Core.new("k")
	check(d.has_consent(), "opt_out mode captures by default")


func test_identify_links_anon_id() -> void:
	var c = Core.new("k")
	var anon: String = c.distinct_id
	c.identify("user-42", {"plan": "pro"})
	var e: Dictionary = c.queue[-1]
	check(e["event"] == "$identify" and e["distinct_id"] == "user-42", "identify event")
	check(e["properties"]["$anon_distinct_id"] == anon, "anon id linked")
	check(e["$set"]["plan"] == "pro", "$set")
	c.identify("user-43")
	check(not c.queue[-1]["properties"].has("$anon_distinct_id"), "no merge of two identified ids")
	check(c.flags_body().contains("anon_distinct_id"), "flags carry the prior anon id")
	c.group("company", "acme")
	check(c.queue[-1]["$groups"]["company"] == "acme", "groups attached")
	c.reset()
	check(c.distinct_id != "user-43" and not c.identified and c.groups.is_empty(), "reset")


func test_batching_and_retry() -> void:
	var c = Core.new("k")
	c.flush_at = 3
	c.max_queue_size = 150
	for i in 160:
		c.capture("e%d" % i)
	check(c.queue.size() == 150 and c.dropped == 10, "queue capped, oldest dropped")
	check(c.should_flush(), "flush threshold")
	var b: Dictionary = c.next_batch()
	check(b["count"] == 100, "batch capped at 100")
	var body = JSON.parse_string(b["body"])
	check(body["api_key"] == "k" and body["batch"].size() == 100 and body.has("sent_at"), "batch body")
	var delay: int = c.settle(b["count"], 503)
	check(delay >= 1000 and delay <= 2000 and c.queue.size() == 150, "5xx retried with backoff, kept")
	check(c.settle(b["count"], 200) == 0 and c.queue.size() == 50, "2xx removes the batch")
	check(c.settle(50, 400) == 0 and c.queue.is_empty(), "4xx drops the batch")
	check(Core.retryable(0) and Core.retryable(429) and not Core.retryable(404), "retryable statuses")


func test_serialization_round_trip() -> void:
	var c = Core.new("k", "https://example.test", "opt_in")
	c.set_consent(true)
	c.identify("u1")
	c.super_props["tier"] = "gold"
	var d = Core.new("k", "https://example.test", "opt_in")
	d.restore(c.serialize())
	check(d.distinct_id == "u1" and d.identified, "identity restored")
	check(d.has_consent(), "consent restored")
	check(d.queue.size() == c.queue.size(), "offline queue restored")
	check(d.super_props["tier"] == "gold", "super props restored")
	d.restore("not json")
	check(d.distinct_id == "u1", "bad state file ignored")


func test_flags() -> void:
	var r: Array = Core.parse_flags('{"flags":{"a":{"enabled":true},"b":{"variant":"blue","payload":{"x":1}},"c":{"enabled":false},"d":3}}')
	check(r[0]["a"] == true and r[0]["b"] == "blue" and r[0]["c"] == false and r[0]["d"] == 3, "flag values")
	check(r[1]["b"]["x"] == 1, "flag payload")
	check(Core.parse_flags("oops")[0].is_empty(), "bad flags body")


func test_scripts_compile() -> void:
	for path in ["res://addons/lucida/lucida.gd", "res://addons/lucida/plugin.gd"]:
		var s: GDScript = load(path)
		check(s != null and s.can_instantiate(), "%s compiles" % path)
