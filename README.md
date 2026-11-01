# Lucida for Godot 4

Tests: `cd sdks/godot && godot --headless -s tests/test_lucida.gd` (exits 0 when every check passes; run on
Godot 4.7). They cover the pure client (LucidaCore) and check that the autoload and plugin scripts compile.

Copy `addons/lucida` into your project and enable **Lucida** under Project Settings > Plugins. That registers
the `Lucida` autoload.

```gdscript
func _ready():
    Lucida.setup("lc_pk_...", {"api_host": "https://app.lucida.dev", "consent": "opt_in"})
    Lucida.opt_in()                       # opt_in mode: nothing is captured or written before this
    Lucida.capture("level_complete", {"level": 3})
    Lucida.screen("Shop")
    Lucida.identify("user-42", {"plan": "pro"})
    if Lucida.is_feature_enabled("new-shop"):
        pass
```

- Events go to `POST /v1/batch` in batches (20 events or 5 s, at most 100 per request), each with a uuid so a
  retried batch is deduplicated. 408, 429, 5xx and network errors retry with backoff (5 tries).
- `$app_opened`, `$app_backgrounded` (flushes) and `$app_closed` are captured from window and app notifications.
- Identity, consent, super properties and unsent events live in `user://lucida_state.json`, written only once
  analytics consent is held; `opt_out()` deletes it. `$lc_*` properties are dropped before sending.
- Flags come from `POST /v1/flags`; `get_flag` sends `$feature_flag_called` once per value, and flag values ride
  on events as `$feature/<key>`.

---

This repository is a read-only mirror of the Lucida monorepo (synced by a script, never edited by hand); releases and provenance attestations are built here by GitHub Actions. Issues are welcome, changes land upstream.
