# Godot Local MCP

**English** | [Русский](README.ru.md)

A compact MCP server for the Godot 4.2+ editor, built for local models (Qwen, DeepSeek and others).
The server lives inside an editor plugin and speaks HTTP. No Node.js, no npm, no separate process.

## What makes it different

- **18 tools, about 1.8k tokens for all schemas.** Flat schemas with no modes, one-line descriptions.
- **Forgiving with model mistakes.** The value type comes from the property itself, so a vector can be passed as
  `[100, 50]`, `"100, 50"`, `"Vector2(100, 50)"` or `{"x": 100, "y": 50}`, a color as `"red"`, `"#ff8800"` or
  `[1, 0.5, 0]`, an enum by name (`"Floating"`), a resource as `"res://icon.png"` or `{"type": "CircleShape2D", "radius": 16}`.
  Argument aliases are accepted (`node_path` for `path`, `class_name` for `type` and so on), `camelCase` instead of
  `snake_case`, booleans and numbers sent as strings (`"True"`, `"32"`), and a ```` ```gdscript ```` fence around code.
- **Script edits without a byte-exact match.** `script_edit` finds the fragment ignoring indentation and re-indents it
  itself, or replaces lines by number. GDScript is checked for errors right after writing (with line numbers on 4.5+).
- **Short text replies.** An error always says what to fix: `node "Plyer" not found; children of ".": Player, Camera2D`,
  `no such property positon (similar: position)`.
- **Everything goes through Undo.** Any edit made by the model can be reverted with Ctrl+Z in the editor.
- **Clean game output.** `game_output` shows your scripts' `print` lines and errors and hides engine service messages
  (drivers, audio). If the debugger paused the game on an error, the reply says so and points to the line.
- **Replies in your language.** They follow the editor language, with English as the fallback; English, Russian,
  Chinese, Spanish, German, French, Portuguese and Japanese are built in (see [Languages](#languages)).

## Tools

| Group | Tools |
|---|---|
| Project and scene | `project_info`, `scene_tree`, `scene_open`, `scene_new`, `scene_save` |
| Nodes | `node_add`, `node_info`, `node_set`, `node_delete`, `node_move`, `signal_connect` |
| Scripts | `script_read`, `script_write`, `script_edit` |
| Game | `game_run`, `game_stop`, `game_output` |
| Reference | `class_info` |

### Optional groups

Off by default so the tool list stays small. Enable them with a checkbox in Project Settings →
`local_mcp/groups/<group>` (then reconnect the client) or with the editor environment variable
`LOCAL_MCP_GROUPS=tilemap,animation` (`all` enables every group).

| Group | Tools | What it does |
|---|---|---|
| `tilemap` | `tilemap_setup`, `tilemap_info`, `tilemap_paint`, `tilemap_read` | A tileset from an image in one call (with collision), painting by cells and rectangles, erasing, the map as text with a legend |
| `animation` | `anim_create`, `anim_key`, `anim_info` | AnimationPlayer and animations, keys for any property in a free value format, loop and autoplay |

With every group enabled there are 25 tools, about 2.5k tokens of schemas.

## Installation

1. Copy the `addons/local_mcp` folder into your project's `addons/`.
2. Project → Project Settings → Plugins → **Local MCP** → Enable.
3. The Output panel shows `[LocalMCP] listening on http://127.0.0.1:6600/mcp`, and a `local_mcp.json` file with a
   ready-made config and token appears in the project root.

## Connecting a client

**Clients with HTTP support (Streamable HTTP)**, such as LM Studio: copy the `mcpServers` block from `local_mcp.json`:

```json
{
  "mcpServers": {
    "godot": {
      "url": "http://127.0.0.1:6600/mcp",
      "headers": { "Authorization": "Bearer <token from local_mcp.json>" }
    }
  }
}
```

The token changes every time the editor starts. If that is inconvenient, turn off `local_mcp/require_token` in Project
Settings (the server still listens on 127.0.0.1 only).

**Clients that only speak stdio**: use the Python bridge (standard library only, Python 3.10+).
It picks up the port and the fresh token from the project by itself:

```json
{
  "mcpServers": {
    "godot": {
      "command": "python3",
      "args": ["/path/to/project/addons/local_mcp/bridge/stdio_bridge.py", "--project", "/path/to/project"]
    }
  }
}
```

On Windows use `python` or `py` instead of `python3`.

### LM Studio

In LM Studio open Program → Install → Edit `mcp.json` (the file `%USERPROFILE%\.lmstudio\mcp.json`) and add the
`godot` server from `local_mcp.json`. Enable tool calling for the model and use a context of 16k or more.

## Languages

Plugin replies (results, errors, hints) are translated; tool names, schemas and descriptions stay in English, which
every model understands.

| Setting | Value |
|---|---|
| Project Settings → `local_mcp/language` | `auto` (default) follows the editor language; or `en`, `ru`, `zh`, `es`, `de`, `fr`, `pt`, `ja` |
| Editor environment variable `LOCAL_MCP_LANG` | Overrides the setting, e.g. `LOCAL_MCP_LANG=en` |
| Per request: `params._meta.lang` in `tools/call` | For clients and scripts that want a specific language for one call |

An unknown language falls back to English. Small models usually do best with English replies, so set `en` if a model
struggles in your language.

**Adding a language** takes one file: copy `addons/local_mcp/lang/ru.json` to `lang/<code>.json` (for example `it.json`)
and translate the values. Keys are the English source strings; keep `%s`/`%d` in the same order. The new code shows up in
the setting automatically. Pull requests are welcome.

The plugin does not rely on the editor's translated UI: it finds the Output panel and the debugger's Errors tab by
their content, so game errors are read the same way in an English, Russian, German, Chinese or Japanese editor.

## Model bench

`bench/run_bench.py` runs 15 typical tasks through any OpenAI-compatible model and checks the result in the scene:
build a player, a UI, write a script, connect a signal, fix syntax, move and delete nodes, set properties, run the game
and read its output, find and fix a runtime error, find the right signal from a description, write a `class_name`
script and add a node of that class, edit a scene instance, recover from a wrong property name, and (with the groups
enabled) a tile level and an animation.

Setup: open any project with `icon.svg` in its root in the editor (a new empty one will do) and enable the plugin.
The bench creates its scenes in `res://bench_runs/` and does not touch your work.

```bash
# LM Studio, llama.cpp, vLLM, also over Tailscale
python bench/run_bench.py --project "C:/Games/BenchProj" --base-url http://100.x.x.x:1234/v1 --model qwen3-next
# Ollama
python bench/run_bench.py --project "C:/Games/BenchProj" --base-url http://localhost:11434/v1 --model qwen3-next
# DeepSeek API
set DEEPSEEK_API_KEY=sk-...
python bench/run_bench.py --project "C:/Games/BenchProj" --base-url https://api.deepseek.com/v1 --model deepseek-chat --api-key-env DEEPSEEK_API_KEY
# Check the bench itself without a model (reference solutions, should be 15/15 with the groups enabled)
python bench/run_bench.py --project "C:/Games/BenchProj" --golden
```

Useful flags: `--tasks player,fix` (only these tasks), `--repeat 3` (each task three times, for statistics),
`--max-steps 25`, `--temperature 0.2`, `--lang ru` (task prompts in Russian), `--reply-lang en` (plugin replies to the
model in this language; by default the plugin setting).

What is counted: whether the task is solved, how many calls and how many of them failed, silent failures (a success
reply that still says "Not applied"), broken JSON in arguments,
calls that came as `<tool_call>` text instead of the `tool_calls` field (the model server did not recognise the
format), calls to tools that do not exist, tokens. The full transcript of every task is saved in `bench/results/*.json`.

Result on Qwen 3.8 Next (local, IQ3_XXS, Windows, Russian editor): 36/36 (12 tasks × 3), 3 failed calls out of 320,
no broken JSON.

## Project settings

| Setting | Default | What it does |
|---|---|---|
| `local_mcp/port` | 6600 | First port; if taken, the next one up to +9 is used |
| `local_mcp/require_token` | true | Require the token in the `Authorization` header |
| `local_mcp/language` | auto | Reply language, see [Languages](#languages) |
| `local_mcp/groups/<group>` | false | Enable an optional tool group |

## Security

- Listens on `127.0.0.1` only; requests with a foreign `Origin` are rejected (DNS rebinding protection).
- Files only inside `res://`; the `addons/local_mcp` and `.godot` folders are closed for writing.
- No arbitrary code execution: the model writes scripts to files that you can see.

## Limitations of version 0.1

- Compile error details reach the model on Godot 4.5+ (the `Logger` class). On 4.2–4.4 the model learns that there is
  an error, and the text is visible in the Output panel.
- After the game stops, `game_output` reads `user://logs/godot.log`, so the project needs
  `debug/file_logging/enable_file_logging` (on by default on desktop).
- Not yet: screenshots, reading live nodes and input into the running game. These are the next groups.

## Tested

Godot 4.5.1 on Linux (editor under a virtual display) and Windows (model bench): all 25 tools, the stdio bridge, running the game
and reading its errors; the bench on reference solutions 12/12 with replies in English, Russian and Chinese; reading
game errors with the editor UI in English, Russian, German, Chinese and Japanese. Other 4.2+ versions have not been
tested yet.
