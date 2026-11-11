#!/usr/bin/env python3
"""Стенд: гоняет типовые задачи Godot через любую OpenAI-совместимую модель и считает, где она ошибается.

Нужно: редактор Godot с включённым плагином Local MCP и открытым проектом, в корне которого лежит icon.svg
(есть в любом новом проекте). Только стандартная библиотека Python 3.10+.

Примеры:
  # LM Studio / llama.cpp / vLLM (в т.ч. через Tailscale)
  python bench/run_bench.py --project C:/Games/MyProj --base-url http://100.64.0.5:1234/v1 --model qwen3-next
  # Ollama
  python bench/run_bench.py --project . --base-url http://localhost:11434/v1 --model qwen3-next
  # DeepSeek API (ключ в переменной DEEPSEEK_API_KEY)
  python bench/run_bench.py --project . --base-url https://api.deepseek.com/v1 --model deepseek-chat --api-key-env DEEPSEEK_API_KEY
  # Проверить сам стенд без модели: эталонные решения
  python bench/run_bench.py --project . --golden

Отчёт: таблица в консоли и bench/results/<модель>-<время>.json с полной перепиской по каждой задаче.
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


# ───────────────────────────── модель ─────────────────────────────

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
    """Достаёт вызовы инструментов. Если сервер модели не распарсил их и они пришли текстом
    (<tool_call>{...}</tool_call>, частая беда Qwen), тоже подбираем, но считаем как ошибку формата."""
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


# ───────────────────────────── прогон задачи ─────────────────────────────

def fill(value, ctx):
    if isinstance(value, str):
        return value.replace("{dir}", ctx["dir"]).replace("{secret}", str(ctx["secret"]))
    if isinstance(value, dict):
        return {k: fill(v, ctx) for k, v in value.items()}
    if isinstance(value, list):
        return [fill(v, ctx) for v in value]
    return value


def run_task(g: GodotMcp, task: dict, ctx: dict, model: Model | None, tools: list, max_steps: int) -> dict:
    stats = {"steps": 0, "tool_calls": 0, "tool_errors": 0, "bad_json": 0, "text_calls": 0,
             "unknown_tool": 0, "prompt_tokens": 0, "completion_tokens": 0}
    transcript = []
    answer = ""
    t0 = time.time()
    task["setup"](g, ctx)

    if model is None:  # эталон
        for name, args in task["golden"]:
            if name == "__sleep":
                time.sleep(args)
                continue
            text, err = g.call(name, **fill(args, ctx))
            stats["tool_calls"] += 1
            stats["tool_errors"] += int(err)
            transcript.append({"tool": name, "args": fill(args, ctx), "result": text, "error": err})
        answer = fill(task.get("golden_answer", "готово"), ctx)
    else:
        messages = [{"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": fill(task["prompt"], ctx)}]
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
            # Рассуждения в <think> не возвращаем в историю: они съедают контекст.
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
                    text, err = "Ошибка: аргументы не являются корректным JSON-объектом", True
                elif c["name"] not in names:
                    stats["unknown_tool"] += 1
                    text, err = g.call(c["name"], **c["args"])  # плагин сам перечислит доступные
                else:
                    text, err = g.call(c["name"], **c["args"])
                stats["tool_errors"] += int(err)
                transcript.append({"tool": c["name"], "args": c["args"], "result": text, "error": err,
                                   "from_text": c.get("from_text", False)})
                messages.append({"role": "tool", "tool_call_id": c["id"], "content": text})
        else:
            transcript.append({"note": f"достигнут предел шагов {max_steps}"})

    g.call("game_stop")
    fails = task["check"](g, ctx, answer)
    stats["seconds"] = round(time.time() - t0, 1)
    return {"id": task["id"], "ok": not fails, "fails": fails, "answer": answer, "stats": stats, "transcript": transcript}


# ───────────────────────────── main ─────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", required=True, help="папка проекта Godot, открытого в редакторе")
    ap.add_argument("--base-url", default="http://localhost:1234/v1", help="OpenAI-совместимый адрес модели")
    ap.add_argument("--model", default="", help="имя модели (по умолчанию первая из /models)")
    ap.add_argument("--api-key", default="")
    ap.add_argument("--api-key-env", default="", help="имя переменной окружения с ключом")
    ap.add_argument("--tasks", default="", help="через запятую, например player,fix")
    ap.add_argument("--repeat", type=int, default=1, help="сколько раз гонять каждую задачу")
    ap.add_argument("--max-steps", type=int, default=25)
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--golden", action="store_true", help="прогнать эталонные решения вместо модели")
    args = ap.parse_args()

    g = GodotMcp(project=args.project)
    try:
        g.initialize()
    except Exception as e:  # noqa: BLE001
        sys.exit(f"Godot не отвечает ({e}). Откройте проект в редакторе и включите плагин Local MCP.")
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
                sys.exit(f"Не удалось получить список моделей с {args.base_url} ({e}). Укажите --model.")
        model = Model(args.base_url, model_name, key, args.temperature, args.timeout)

    selected = [t for t in TASKS if not args.tasks or t["id"] in args.tasks.split(",")]
    tool_names = {t["name"] for t in mcp_tools}
    skipped = [t["id"] for t in selected if t.get("group") and not any(n.startswith(
        {"tilemap": "tilemap_", "animation": "anim_"}.get(t["group"], t["group"])) for n in tool_names)]
    if skipped:
        print(f"Пропускаю {', '.join(skipped)}: их группы выключены (local_mcp/groups/... в настройках проекта "
              "или LOCAL_MCP_GROUPS=all у редактора)")
        selected = [t for t in selected if t["id"] not in skipped]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    print(f"Модель: {model_name} | инструментов: {len(tools)}, схемы ~{schema_tokens} токенов | задач: {len(selected)} x {args.repeat}\n")

    results = []
    for rep in range(args.repeat):
        for task in selected:
            ctx = {"dir": f"res://bench_runs/{stamp}/{task['id']}_{rep}", "secret": random.randint(10000, 99999)}
            ctx["scene"] = ctx["dir"] + "/scene.tscn"
            try:
                r = run_task(g, task, ctx, model, tools, args.max_steps)
            except Exception as e:  # noqa: BLE001
                r = {"id": task["id"], "ok": False, "fails": [f"сбой стенда: {e}"], "answer": "", "stats": {}, "transcript": []}
            results.append(r)
            s = r["stats"]
            mark = "OK  " if r["ok"] else "FAIL"
            print(f"{mark} {task['id']:<8} вызовов {s.get('tool_calls', 0):>2}, ошибок {s.get('tool_errors', 0):>2}, "
                  f"JSON {s.get('bad_json', 0)}, текстом {s.get('text_calls', 0)}, {s.get('seconds', 0)} c"
                  + ("" if r["ok"] else "  ← " + "; ".join(r["fails"])))

    ok = sum(r["ok"] for r in results)
    tot = {k: sum(r["stats"].get(k, 0) for r in results) for k in
           ["tool_calls", "tool_errors", "bad_json", "text_calls", "unknown_tool", "prompt_tokens", "completion_tokens"]}
    print(f"\nИтого: {ok}/{len(results)} задач решено. Вызовов {tot['tool_calls']}, из них с ошибкой {tot['tool_errors']}"
          f" ({(100 * tot['tool_errors'] // max(tot['tool_calls'], 1))}%), битый JSON {tot['bad_json']}, "
          f"вызовы текстом {tot['text_calls']}, неизвестный инструмент {tot['unknown_tool']}. "
          f"Токены: {tot['prompt_tokens']} вход / {tot['completion_tokens']} выход.")

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
    os.makedirs(out_dir, exist_ok=True)
    safe = re.sub(r"[^\w.-]+", "_", model_name)
    path = os.path.join(out_dir, f"{safe}-{stamp}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"model": model_name, "base_url": None if args.golden else args.base_url, "schema_tokens": schema_tokens,
                   "solved": ok, "total": len(results), "totals": tot, "results": results}, f, ensure_ascii=False, indent=1)
    print(f"Подробный отчёт: {path}")


if __name__ == "__main__":
    main()
