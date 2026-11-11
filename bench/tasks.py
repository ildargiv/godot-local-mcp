"""Типовые задачи стенда.

У каждой задачи:
  setup(g, ctx)  — готовит сцену прямыми вызовами MCP (модель этого не видит);
  prompt         — что просим у модели (по-русски, как просил бы человек);
  check(g, ctx, answer) -> list[str] — список провалившихся проверок (пусто = задача решена);
  golden         — эталонная последовательность вызовов, на которой проверяется сам стенд.

ctx["scene"] — путь сцены этого прогона, ctx["dir"] — папка для файлов прогона.
"""
import re


def new_scene(g, ctx, root_type="Node2D", name="Main"):
    text, err = g.call("scene_new", path=ctx["scene"], type=root_type, name=name)
    if err:
        raise RuntimeError(text)


def info(g, path):
    text, err = g.call("node_info", path=path)
    return None if err else text


def has_prop(text, prop, pattern):
    if text is None:
        return False
    m = re.search(rf"^\s*{re.escape(prop)} = (.+)$", text, re.M)
    return bool(m and re.search(pattern, m.group(1)))


def script_ok(g, path):
    """Скрипт существует и компилируется (перезаписываем тем же текстом, плагин его проверит)."""
    text, err = g.call("script_read", path=path, start_line=1, end_line=100000)
    if err:
        return False, ""
    body = "\n".join(l.split("| ", 1)[1] if "| " in l else "" for l in text.split("\n")[1:])
    t2, err2 = g.call("script_write", path=path, content=body)
    return (not err2 and "ошибок нет" in t2), body


# ─────────────────────────────────────────────────────────────────────────────

def t_player_setup(g, ctx):
    new_scene(g, ctx)


def c_player(g, ctx, answer):
    fails = []
    p = info(g, "Player")
    if p is None or "(CharacterBody2D)" not in p:
        return ["нет узла Player типа CharacterBody2D"]
    if not has_prop(p, "position", r"\[200, 300\]"):
        fails.append("Player.position != [200, 300]")
    s = info(g, "Player/Sprite2D") or ""
    if "(Sprite2D)" not in s:
        fails.append("нет Player/Sprite2D")
    elif not has_prop(s, "texture", r"icon\.svg"):
        fails.append("у Sprite2D нет текстуры res://icon.svg")
    c = info(g, "Player/CollisionShape2D") or ""
    if not has_prop(c, "shape", r"RectangleShape2D"):
        fails.append("у CollisionShape2D нет RectangleShape2D")
    return fails


def t_ui_setup(g, ctx):
    new_scene(g, ctx, "Control", "Menu")


def c_ui(g, ctx, answer):
    fails = []
    b = info(g, "StartButton")
    if b is None or "(Button)" not in b:
        fails.append("нет Button StartButton")
    elif not has_prop(b, "text", r'"Start"'):
        fails.append("у кнопки текст не Start")
    l = info(g, "ScoreLabel")
    if l is None or "(Label)" not in l:
        fails.append("нет Label ScoreLabel")
    elif not has_prop(l, "text", r'"Score: 0"'):
        fails.append("у метки текст не 'Score: 0'")
    elif not has_prop(l, "modulate", r"#ffff00|#ff0"):
        fails.append("метка не жёлтая (modulate)")
    return fails


def t_script_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="CharacterBody2D", name="Player")


def c_script(g, ctx, answer):
    path = ctx["dir"] + "/player.gd"
    ok, body = script_ok(g, path)
    if not body:
        return [f"нет файла {path}"]
    fails = []
    if not ok:
        fails.append("скрипт не компилируется")
    if "move_and_slide" not in body:
        fails.append("в скрипте нет move_and_slide")
    if "200" not in body:
        fails.append("скорость 200 не задана")
    p = info(g, "Player") or ""
    if path not in p:
        fails.append("скрипт не прикреплён к Player")
    return fails


def t_signal_setup(g, ctx):
    new_scene(g, ctx, "Control", "Menu")
    g.call("script_write", path=ctx["dir"] + "/menu.gd", content="extends Control\n\nfunc _ready():\n\tpass\n", attach_to=".")
    g.call("node_add", type="Button", name="StartButton", properties={"text": "Start"})


def c_signal(g, ctx, answer):
    fails = []
    b = info(g, "StartButton") or ""
    if not re.search(r"pressed -> (\.|Menu)\._on_start_button_pressed", b):
        fails.append("pressed не подключён к Menu._on_start_button_pressed")
    ok, body = script_ok(g, ctx["dir"] + "/menu.gd")
    if "func _on_start_button_pressed" not in body:
        fails.append("в menu.gd нет метода _on_start_button_pressed")
    elif "Game started" not in body:
        fails.append("метод не печатает 'Game started'")
    if not ok:
        fails.append("menu.gd не компилируется")
    return fails


BROKEN = """extends Node2D

var speed = 100

func _ready()
\tprint("ready")

func _process(delta):
\tposition.x += speed * delta
\tif position.x > 500
\t\tposition.x = 0
"""


def t_fix_setup(g, ctx):
    new_scene(g, ctx)
    g.call("script_write", path=ctx["dir"] + "/broken.gd", content=BROKEN)


def c_fix(g, ctx, answer):
    ok, body = script_ok(g, ctx["dir"] + "/broken.gd")
    fails = []
    if not ok:
        fails.append("broken.gd всё ещё с ошибками")
    if "position.x = 0" not in body or "speed * delta" not in body:
        fails.append("логика скрипта потеряна")
    return fails


def t_move_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="Node2D", name="Level")
    g.call("node_add", type="Area2D", name="Coin", properties={"position": [50, 50]})
    g.call("node_add", type="Node2D", name="Enemy1")
    g.call("node_add", type="Node2D", name="Enemy2")
    g.call("node_add", parent="Level", type="Node2D", name="Enemy3")


def c_move(g, ctx, answer):
    fails = []
    if info(g, "Level/GoldCoin") is None:
        fails.append("нет Level/GoldCoin")
    if info(g, "Coin") is not None:
        fails.append("Coin остался в корне")
    for e in ["Enemy1", "Enemy2", "Level/Enemy3"]:
        if info(g, e) is not None:
            fails.append(f"{e} не удалён")
    if info(g, "Level") is None:
        fails.append("Level удалён по ошибке")
    return fails


def t_props_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="CharacterBody2D", name="Player")
    g.call("node_add", type="Camera2D", name="Camera")


def c_props(g, ctx, answer):
    fails = []
    p = info(g, "Player") or ""
    if not has_prop(p, "motion_mode", r"Floating|^1"):
        fails.append("motion_mode не Floating")
    if not has_prop(p, "z_index", r"^5$"):
        fails.append("z_index != 5")
    c = info(g, "Camera") or ""
    if not has_prop(c, "zoom", r"\[2, 2\]"):
        fails.append("zoom камеры != [2, 2]")
    if info(g, "Player/Camera") is None:
        fails.append("камера не перенесена под Player")
    return fails


def t_run_setup(g, ctx):
    new_scene(g, ctx)
    code = ctx["secret"]
    g.call("script_write", path=ctx["dir"] + "/main.gd",
           content=f'extends Node2D\n\nfunc _ready():\n\tvar parts = [{code // 1000}, {code % 1000}]\n\tprint("CODE=", parts[0] * 1000 + parts[1])\n',
           attach_to=".")
    g.call("scene_save")


def c_run(g, ctx, answer):
    return [] if str(ctx["secret"]) in (answer or "") else [f"в ответе нет числа {ctx['secret']}"]


def t_debug_setup(g, ctx):
    new_scene(g, ctx)
    g.call("script_write", path=ctx["dir"] + "/main.gd",
           content='extends Node2D\n\nvar items = [1, 2, 3]\n\nfunc _ready():\n\tprint("sum=", items[0] + items[1] + items[3])\n',
           attach_to=".")
    g.call("scene_save")


def c_debug(g, ctx, answer):
    ok, body = script_ok(g, ctx["dir"] + "/main.gd")
    fails = []
    if "items[3]" in body:
        fails.append("ошибка выхода за границы массива не исправлена")
    if not ok:
        fails.append("main.gd не компилируется")
    return fails


def t_class_setup(g, ctx):
    new_scene(g, ctx)


def c_class(g, ctx, answer):
    fails = []
    a = info(g, "Pickup")
    if a is None or "(Area2D)" not in a:
        return ["нет Area2D Pickup"]
    if not re.search(r"body_entered -> (\.|Main)\._on_pickup_body_entered", a):
        fails.append("body_entered не подключён к Main._on_pickup_body_entered")
    c = info(g, "Pickup/CollisionShape2D") or ""
    if not has_prop(c, "shape", r"CircleShape2D"):
        fails.append("нет CollisionShape2D с CircleShape2D")
    return fails


# ─────────────────────────────────────────────────────────────────────────────

TASKS = [
    {
        "id": "player",
        "setup": t_player_setup,
        "prompt": "В открытой сцене создай игрока: узел CharacterBody2D с именем Player в позиции (200, 300). "
                  "Внутри него Sprite2D с текстурой res://icon.svg и CollisionShape2D с прямоугольной формой 64x64. Сохрани сцену.",
        "check": c_player,
        "golden": [
            ("node_add", {"type": "CharacterBody2D", "name": "Player", "properties": {"position": [200, 300]}}),
            ("node_add", {"parent": "Player", "type": "Sprite2D", "properties": {"texture": "res://icon.svg"}}),
            ("node_add", {"parent": "Player", "type": "CollisionShape2D",
                          "properties": {"shape": {"type": "RectangleShape2D", "size": [64, 64]}}}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "ui",
        "setup": t_ui_setup,
        "prompt": "Добавь в меню кнопку StartButton с текстом Start и метку ScoreLabel с текстом \"Score: 0\" жёлтого цвета. Сохрани.",
        "check": c_ui,
        "golden": [
            ("node_add", {"type": "Button", "name": "StartButton", "properties": {"text": "Start"}}),
            ("node_add", {"type": "Label", "name": "ScoreLabel", "properties": {"text": "Score: 0", "modulate": "yellow"}}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "script",
        "setup": t_script_setup,
        "prompt": "Напиши скрипт {dir}/player.gd для узла Player (CharacterBody2D): движение стрелками "
                  "(ui_left, ui_right, ui_up, ui_down) со скоростью 200 через move_and_slide. Прикрепи его к Player и сохрани сцену.",
        "check": c_script,
        "golden": [
            ("script_write", {"path": "{dir}/player.gd", "attach_to": "Player", "content":
                "extends CharacterBody2D\n\nconst SPEED = 200.0\n\nfunc _physics_process(_delta):\n"
                "\tvar dir = Input.get_vector(\"ui_left\", \"ui_right\", \"ui_up\", \"ui_down\")\n"
                "\tvelocity = dir * SPEED\n\tmove_and_slide()\n"}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "signal",
        "setup": t_signal_setup,
        "prompt": "Сделай так, чтобы по нажатию кнопки StartButton в консоль печаталось \"Game started\". "
                  "Обработчик назови _on_start_button_pressed и положи в скрипт корневого узла. Сохрани сцену.",
        "check": c_signal,
        "golden": [
            ("signal_connect", {"from": "StartButton", "signal": "pressed", "to": ".", "method": "_on_start_button_pressed"}),
            ("script_edit", {"path": "{dir}/menu.gd", "old_text": "func _ready():\n\tpass",
                             "new_text": "func _ready():\n\tpass\n\nfunc _on_start_button_pressed():\n\tprint(\"Game started\")"}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "fix",
        "setup": t_fix_setup,
        "prompt": "В файле {dir}/broken.gd есть синтаксические ошибки. Найди и исправь их, не меняя логику.",
        "check": c_fix,
        "golden": [
            ("script_edit", {"path": "{dir}/broken.gd", "old_text": "func _ready()", "new_text": "func _ready():"}),
            ("script_edit", {"path": "{dir}/broken.gd", "old_text": "if position.x > 500", "new_text": "if position.x > 500:"}),
        ],
    },
    {
        "id": "move",
        "setup": t_move_setup,
        "prompt": "Перенеси узел Coin внутрь Level и переименуй его в GoldCoin. Удали всех врагов (узлы Enemy...), где бы они ни были. Сохрани.",
        "check": c_move,
        "golden": [
            ("node_move", {"path": "Coin", "new_parent": "Level", "new_name": "GoldCoin"}),
            ("node_delete", {"path": "Enemy1"}),
            ("node_delete", {"path": "Enemy2"}),
            ("node_delete", {"path": "Level/Enemy3"}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "props",
        "setup": t_props_setup,
        "prompt": "Переключи Player в режим движения Floating (для вида сверху) и поставь ему z_index 5. "
                  "Камеру Camera перенеси внутрь Player и приблизь в 2 раза. Сохрани.",
        "check": c_props,
        "golden": [
            ("node_set", {"path": "Player", "properties": {"motion_mode": "Floating", "z_index": 5}}),
            ("node_move", {"path": "Camera", "new_parent": "Player"}),
            ("node_set", {"path": "Player/Camera", "properties": {"zoom": [2, 2]}}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "run",
        "setup": t_run_setup,
        "prompt": "Запусти текущую сцену и скажи, какое число игра печатает после CODE=. Потом останови игру.",
        "check": c_run,
        "golden": [
            ("game_run", {"scene": "current"}),
            ("__sleep", 6),
            ("game_output", {}),
            ("game_stop", {}),
        ],
        "golden_answer": "CODE={secret}",
    },
    {
        "id": "debug",
        "setup": t_debug_setup,
        "prompt": "Запусти текущую сцену, посмотри, какая ошибка возникает в игре, исправь её в скрипте и останови игру.",
        "check": c_debug,
        "golden": [
            ("game_run", {"scene": "current"}),
            ("__sleep", 6),
            ("game_output", {"errors_only": True}),
            ("game_stop", {}),
            ("script_edit", {"path": "{dir}/main.gd", "old_text": "items[3]", "new_text": "items[2]"}),
        ],
    },
    {
        "id": "class",
        "setup": t_class_setup,
        "prompt": "Добавь подбираемый предмет: Area2D с именем Pickup с круглой формой коллизии. "
                  "Подключи его сигнал, который срабатывает при входе физического тела, к методу _on_pickup_body_entered корневого узла. Сохрани.",
        "check": c_class,
        "golden": [
            ("node_add", {"type": "Area2D", "name": "Pickup"}),
            ("node_add", {"parent": "Pickup", "type": "CollisionShape2D", "properties": {"shape": {"type": "CircleShape2D", "radius": 16}}}),
            ("signal_connect", {"from": "Pickup", "signal": "body_entered", "to": ".", "method": "_on_pickup_body_entered"}),
            ("scene_save", {}),
        ],
    },
]
