#!/usr/bin/env python3
"""Bench: runs typical Godot tasks through any OpenAI-compatible model and counts where it goes wrong.

Needs: the Godot editor with the Local MCP plugin enabled and a project open that has icon.svg in its root
(every new project does). Standard library only, Python 3.10+.

Examples:
  # LM Studio / llama.cpp / vLLM (also over Tailscale)
  python bench/run_bench.py --project C:/Games/MyProj --base-url http://100.64.0.5:1234/v1 --model qwen3-next
  # Ollama
  python bench/run_bench.py --project . --base-url http://localhost:11434/v1 --model qwen3-next
  # DeepSeek API (key in the DEEPSEEK_API_KEY variable)
  python bench/run_bench.py --project . --base-url https://api.deepseek.com/v1 --model deepseek-chat --api-key-env DEEPSEEK_API_KEY
  # Check the bench itself without a model: reference solutions
  python bench/run_bench.py --project . --golden

  # Task prompts in Russian, plugin replies to the model in Russian
  python bench/run_bench.py --project . --model qwen3-next --lang ru --reply-lang ru

Report: a table in the console and bench/results/<model>-<time>.json with the full transcript of every task.
"""
import argparse
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp_client import GodotMcp  # noqa: E402
from tasks import TASKS  # noqa: E402

SYSTEM_PROMPT = (
    "You control the Godot editor through tools. Work step by step: look at the scene with scene_tree, "
    "then make changes with tools. Node paths are relative to the scene root (\".\" is the root). "
    "If a tool returns an error, read it and fix the call. When the task is done, reply with a short summary. "
    "Answer in the user's language."
)


# ───────────────────────────── model ─────────────────────────────

class Model:
    def __init__(self, base_url: str, model: str, api_key: str, temperature: float, timeout: float):
        self.url = base_url.rstrip("/") + "/chat/completions"
        self.model = model
        self.api_key = api_key
        self.temperature = temperature
        self.timeout = timeout
        local = re.match(r"https?://(localhost|127\.|10\.|192\.168\.|100\.|[^/]*\.ts\.net)", base_url)
        handlers = [urllib.request.ProxyHandler({})] if local else []
        self._opener = urllib.request.build_opener(*handlers)

    def chat(self, messages: list, tools: list) -> dict:
        body = {"model": self.model, "messages": messages, "tools": tools, "tool_choice": "auto",
                "temperature": self.temperature, "stream": False}
        req = urllib.request.Request(self.url, data=json.dumps(body).encode("utf-8"), method="POST")
        req.add_header("Content-Type", "application/json")
        if self.api_key:
            req.add_header("Authorization", "Bearer " + self.api_key)
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:500]}") from e


def mcp_to_openai(tools: list) -> list:
    return [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                              "parameters": t["inputSchema"]}} for t in tools]


TEXT_CALL_RE = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.S)


def extract_calls(msg: dict, stats: dict) -> list:
    """Extracts tool calls. If the model server did not parse them and they came as text
    (<tool_call>{...}</tool_call>, a common Qwen issue), pick them up too but count a format error."""
    calls = []
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function", {})
        raw = fn.get("arguments") or "{}"
        try:
            args = json.loads(raw) if isinstance(raw, str) else raw
            if not isinstance(args, dict):
                raise ValueError
        except (json.JSONDecodeError, ValueError):
            stats["bad_json"] += 1
            args = None
        calls.append({"id": tc.get("id") or f"call_{len(calls)}", "name": fn.get("name", ""), "args": args, "raw": raw})
    if not calls and msg.get("content"):
        for m in TEXT_CALL_RE.finditer(msg["content"]):
            stats["text_calls"] += 1
            try:
                obj = json.loads(m.group(1))
                calls.append({"id": f"text_{len(calls)}", "name": obj.get("name", ""),
                              "args": obj.get("arguments", {}), "raw": m.group(1), "from_text": True})
            except json.JSONDecodeError:
                stats["bad_json"] += 1
    return calls


# ───────────────────────────── running a task ─────────────────────────────

def _not_applied_markers() -> list:
    """The "Not applied:" label in every reply language: a success reply containing it is a silent failure."""
    out = {"Not applied:"}
    lang_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "addons", "local_mcp", "lang")
    if os.path.isdir(lang_dir):
        for f in os.listdir(lang_dir):
            if f.endswith(".json"):
                with open(os.path.join(lang_dir, f), encoding="utf-8") as fh:
                    v = json.load(fh).get("Not applied: ", "").strip()
                if v:
                    out.add(v)
    return sorted(out)


NOT_APPLIED = _not_applied_markers()


def is_semantic_error(text: str, err: bool) -> bool:
    return not err and any(m in text for m in NOT_APPLIED)


def fill(value, ctx):
    if isinstance(value, str):
        return value.replace("{dir}", ctx["dir"]).replace("{secret}", str(ctx["secret"]))
    if isinstance(value, dict):
        return {k: fill(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [fill(v, ctx) for v in value]
    return value


def run_task(g: GodotMcp, task: dict, ctx: dict, model: Model | None, tools: list, max_steps: int,
             lang: str = "en", reply_lang: str = "") -> dict:
    stats = {"steps": 0, "tool_calls": 0, "tool_errors": 0, "semantic_errors": 0, "bad_json": 0, "text_calls": 0,
             "unknown_tool": 0, "prompt_tokens": 0, "completion_tokens": 0}
    transcript = []
    golden_fails = []
    answer = ""
    t0 = time.time()
    task["setup"](g, ctx)

    if model is None:  # reference solution
        for step in task["golden"]:
            name, args = step[0], step[1]
            expect = step[2] if len(step) > 2 else {}
            if name == "__sleep":
                time.sleep(args)
                continue
            text, err = g.call(name, **fill(args, ctx))
            stats["tool_calls"] += 1
            stats["tool_errors"] += int(err)
            stats["semantic_errors"] += int(is_semantic_error(text, err))
            transcript.append({"tool": name, "args": fill(args, ctx), "result": text, "error": err})
            if "error" in expect and err != expect["error"]:
                golden_fails.append(f"{name} replied {'an error' if err else 'success'}, expected "
                                    f"{'an error' if expect['error'] else 'success'}: {text[:200]}")
            if "text" in expect and not re.search(expect["text"], text):
                golden_fails.append(f"{name} reply does not match {expect['text']!r}: {text[:200]}")
        answer = fill(task.get("golden_answer", "done"), ctx)
    else:
        messages = [{"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": fill(task["prompt"].get(lang) or task["prompt"]["en"], ctx)}]
        names = {t["function"]["name"] for t in tools}
        for _ in range(max_steps):
            stats["steps"] += 1
            resp = model.chat(messages, tools)
            usage = resp.get("usage") or {}
            stats["prompt_tokens"] += usage.get("prompt_tokens", 0)
            stats["completion_tokens"] += usage.get("completion_tokens", 0)
            msg = resp["choices"][0]["message"]
            calls = extract_calls(msg, stats)
            content = msg.get("content") or ""
            # Do not keep <think> reasoning in the history: it eats context.
            clean = re.sub(r"<think>.*?</think>", "", content, flags=re.S).strip()
            if not calls:
                answer = clean
                messages.append({"role": "assistant", "content": clean})
                transcript.append({"assistant": clean})
                break
            messages.append({"role": "assistant", "content": clean or None, "tool_calls": [
                {"id": c["id"], "type": "function",
                 "function": {"name": c["name"], "arguments": c["raw"] if isinstance(c["raw"], str) else json.dumps(c["raw"])}}
                for c in calls]})
            for c in calls:
                stats["tool_calls"] += 1
                if c["args"] is None:
                    text, err = "Error: the arguments are not a valid JSON object", True
                elif c["name"] not in names:
                    stats["unknown_tool"] += 1
                    text, err = g.call_lang(c["name"], c["args"], reply_lang)  # the plugin lists the available ones
                else:
                    text, err = g.call_lang(c["name"], c["args"], reply_lang)
                stats["tool_errors"] += int(err)
                stats["semantic_errors"] += int(is_semantic_error(text, err))
                transcript.append({"tool": c["name"], "args": c["args"], "result": text, "error": err,
                                   "from_text": c.get("from_text", False)})
                messages.append({"role": "tool", "tool_call_id": c["id"], "content": text})
        else:
            transcript.append({"note": f"step limit {max_steps} reached"})

    g.call("game_stop")
    fails = golden_fails + task["check"](g, ctx, answer)
    stats["seconds"] = round(time.time() - t0, 1)
    return {"id": task["id"], "ok": not fails, "fails": fails, "answer": answer, "stats": stats, "transcript": transcript}


# ───────────────────────────── main ─────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", required=True, help="folder of the Godot project open in the editor")
    ap.add_argument("--base-url", default="http://localhost:1234/v1", help="OpenAI-compatible model endpoint")
    ap.add_argument("--model", default="", help="model name (default: the first one from /models)")
    ap.add_argument("--api-key", default="")
    ap.add_argument("--api-key-env", default="", help="name of the env variable holding the key")
    ap.add_argument("--tasks", default="", help="comma-separated, e.g. player,fix")
    ap.add_argument("--repeat", type=int, default=1, help="how many times to run each task")
    ap.add_argument("--max-steps", type=int, default=25)
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--golden", action="store_true", help="run the reference solutions instead of a model")
    ap.add_argument("--lang", default="en", help="task prompt language: en or ru")
    ap.add_argument("--reply-lang", default="", help="plugin reply language for the model (en, ru, zh...); default: plugin setting")
    args = ap.parse_args()

    g = GodotMcp(project=args.project)
    try:
        g.initialize()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"Godot is not answering ({e}). Open the project in the editor and enable the Local MCP plugin.")
    mcp_tools = g.tools()
    tools = mcp_to_openai(mcp_tools)
    schema_tokens = len(json.dumps(tools)) // 4

    model = None
    model_name = "golden"
    if not args.golden:
        key = args.api_key or (os.environ.get(args.api_key_env, "") if args.api_key_env else "")
        model_name = args.model
        if not model_name:
            try:
                m = Model(args.base_url, "", key, 0, 30)
                req = urllib.request.Request(args.base_url.rstrip("/") + "/models")
                if key:
                    req.add_header("Authorization", "Bearer " + key)
                with m._opener.open(req, timeout=30) as resp:
                    model_name = json.loads(resp.read())["data"][0]["id"]
            except Exception as e:  # noqa: BLE001
                sys.exit(f"Could not get the model list from {args.base_url} ({e}). Pass --model.")
        model = Model(args.base_url, model_name, key, args.temperature, args.timeout)

    selected = [t for t in TASKS if not args.tasks or t["id"] in args.tasks.split(",")]
    tool_names = {t["name"] for t in mcp_tools}
    skipped = [t["id"] for t in selected if t.get("group") and not any(n.startswith(
        {"tilemap": "tilemap_", "animation": "anim_"}.get(t["group"], t["group"])) for n in tool_names)]
    if skipped:
        print(f"Skipping {', '.join(skipped)}: their groups are disabled (local_mcp/groups/... in Project Settings "
              "or LOCAL_MCP_GROUPS=all for the editor)")
        selected = [t for t in selected if t["id"] not in skipped]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    print(f"Model: {model_name} | tools: {len(tools)}, schemas ~{schema_tokens} tokens | tasks: {len(selected)} x {args.repeat}"
          f" | prompts: {args.lang}, replies: {args.reply_lang or 'plugin setting'}\n")

    results = []
    for rep in range(args.repeat):
        for task in selected:
            ctx = {"dir": f"res://bench_runs/{stamp}/{task['id']}_{rep}", "secret": random.randint(10000, 99999)}
            ctx["scene"] = ctx["dir"] + "/scene.tscn"
            try:
                r = run_task(g, task, ctx, model, tools, args.max_steps, args.lang, args.reply_lang)
            except Exception as e:  # noqa: BLE001
                r = {"id": task["id"], "ok": False, "fails": [f"bench failure: {e}"], "answer": "", "stats": {}, "transcript": []}
            results.append(r)
            s = r["stats"]
            mark = "OK  " if r["ok"] else "FAIL"
            print(f"{mark} {task['id']:<9} calls {s.get('tool_calls', 0):>2}, errors {s.get('tool_errors', 0):>2}, "
                  f"silent {s.get('semantic_errors', 0)}, "
                  f"JSON {s.get('bad_json', 0)}, as text {s.get('text_calls', 0)}, {s.get('seconds', 0)} s"
                  + ("" if r["ok"] else "  ← " + "; ".join(r["fails"])))

    ok = sum(r["ok"] for r in results)
    tot = {k: sum(r["stats"].get(k, 0) for r in results) for k in
           ["tool_calls", "tool_errors", "semantic_errors", "bad_json", "text_calls", "unknown_tool", "prompt_tokens", "completion_tokens"]}
    print(f"\nTotal: {ok}/{len(results)} tasks solved. Calls {tot['tool_calls']}, with errors {tot['tool_errors']}"
          f" ({(100 * tot['tool_errors'] // max(tot['tool_calls'], 1))}%), silent failures {tot['semantic_errors']}"
          f" (success replies with \"Not applied\"), broken JSON {tot['bad_json']}, "
          f"calls as text {tot['text_calls']}, unknown tool {tot['unknown_tool']}. "
          f"Tokens: {tot['prompt_tokens']} in / {tot['completion_tokens']} out.")

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    safe = re.sub(r"[^\w.-]+", "_", model_name)
    path = os.path.join(out_dir, f"{safe}-{stamp}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"model": model_name, "base_url": None if args.golden else args.base_url, "schema_tokens": schema_tokens,
                   "lang": args.lang, "reply_lang": args.reply_lang, "solved": ok, "total": len(results), "totals": tot, "results": results}, f, ensure_ascii=False, indent=1)
    print(f"Full report: {path}")


if __name__ == "__main__":
    main()
