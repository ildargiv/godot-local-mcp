"""Bench tasks.

Each task has:
  setup(g, ctx)  - prepares the scene with direct MCP calls (the model does not see this);
  prompt         - what we ask the model, per language ({"en": ..., "ru": ...}), the way a person would ask;
  check(g, ctx, answer) -> list[str] - failed checks (empty = solved);
  golden         - reference call sequence used to verify the bench itself: (tool, args) or
                   (tool, args, expect), where expect may hold "error": bool (the reply must or must not
                   be an error) and "text": regex the reply must match. A mismatch fails the task.

ctx["scene"] is this run's scene path, ctx["dir"] the folder for this run's files.
Setup and checks run with plugin replies forced to English (see GodotMcp.lang), so they work
whatever language the editor uses.
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
    """The script exists and compiles (rewrite it with the same text; the plugin checks it)."""
    text, err = g.call("script_read", path=path, start_line=1, end_line=100000)
    if err:
        return False, ""
    body = "\n".join(l.split("| ", 1)[1] if "| " in l else "" for l in text.split("\n")[1:])
    t2, err2 = g.call("script_write", path=path, content=body)
    return (not err2 and "Check: no errors" in t2), body


# ─────────────────────────────────────────────────────────────────────────────

def t_player_setup(g, ctx):
    new_scene(g, ctx)


def c_player(g, ctx, answer):
    fails = []
    p = info(g, "Player")
    if p is None or "(CharacterBody2D)" not in p:
        return ["no Player node of type CharacterBody2D"]
    if not has_prop(p, "position", r"\[200, 300\]"):
        fails.append("Player.position != [200, 300]")
    s = info(g, "Player/Sprite2D") or ""
    if "(Sprite2D)" not in s:
        fails.append("no Player/Sprite2D")
    elif not has_prop(s, "texture", r"icon\.svg"):
        fails.append("Sprite2D has no res://icon.svg texture")
    c = info(g, "Player/CollisionShape2D") or ""
    if not has_prop(c, "shape", r"RectangleShape2D"):
        fails.append("CollisionShape2D has no RectangleShape2D")
    return fails


def t_ui_setup(g, ctx):
    new_scene(g, ctx, "Control", "Menu")


def c_ui(g, ctx, answer):
    fails = []
    b = info(g, "StartButton")
    if b is None or "(Button)" not in b:
        fails.append("no Button StartButton")
    elif not has_prop(b, "text", r'"Start"'):
        fails.append("button text is not Start")
    l = info(g, "ScoreLabel")
    if l is None or "(Label)" not in l:
        fails.append("no Label ScoreLabel")
    elif not has_prop(l, "text", r'"Score: 0"'):
        fails.append("label text is not 'Score: 0'")
    elif not (has_prop(l, "modulate", r"#ffff00") or has_prop(l, "self_modulate", r"#ffff00")
              or has_prop(l, "theme_override_colors/font_color", r"#ffff00")):
        fails.append("label is not yellow (no modulate, self_modulate or font_color)")
    return fails


def t_script_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="CharacterBody2D", name="Player")


def c_script(g, ctx, answer):
    path = ctx["dir"] + "/player.gd"
    ok, body = script_ok(g, path)
    if not body:
        return [f"no file {path}"]
    fails = []
    if not ok:
        fails.append("script does not compile")
    if "move_and_slide" not in body:
        fails.append("no move_and_slide in the script")
    if "200" not in body:
        fails.append("speed 200 not set")
    p = info(g, "Player") or ""
    if path not in p:
        fails.append("script not attached to Player")
    return fails


def t_signal_setup(g, ctx):
    new_scene(g, ctx, "Control", "Menu")
    g.call("script_write", path=ctx["dir"] + "/menu.gd", content="extends Control\n\nfunc _ready():\n\tpass\n", attach_to=".")
    g.call("node_add", type="Button", name="StartButton", properties={"text": "Start"})


def c_signal(g, ctx, answer):
    fails = []
    b = info(g, "StartButton") or ""
    if not re.search(r"pressed -> (\.|Menu)\._on_start_button_pressed", b):
        fails.append("pressed is not connected to Menu._on_start_button_pressed")
    ok, body = script_ok(g, ctx["dir"] + "/menu.gd")
    if "func _on_start_button_pressed" not in body:
        fails.append("menu.gd has no _on_start_button_pressed method")
    elif "Game started" not in body:
        fails.append("the method does not print 'Game started'")
    if not ok:
        fails.append("menu.gd does not compile")
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
        fails.append("broken.gd still has errors")
    if "position.x = 0" not in body or "speed * delta" not in body:
        fails.append("script logic was lost")
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
        fails.append("no Level/GoldCoin")
    if info(g, "Coin") is not None:
        fails.append("Coin is still at the root")
    for e in ["Enemy1", "Enemy2", "Level/Enemy3"]:
        if info(g, e) is not None:
            fails.append(f"{e} not deleted")
    if info(g, "Level") is None:
        fails.append("Level was deleted by mistake")
    return fails


def t_props_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="CharacterBody2D", name="Player")
    g.call("node_add", type="Camera2D", name="Camera")


def c_props(g, ctx, answer):
    fails = []
    p = info(g, "Player") or ""
    if not has_prop(p, "motion_mode", r"Floating|^1"):
        fails.append("motion_mode is not Floating")
    if not has_prop(p, "z_index", r"^5$"):
        fails.append("z_index != 5")
    c = info(g, "Camera") or ""
    if not has_prop(c, "zoom", r"\[2, 2\]"):
        fails.append("camera zoom != [2, 2]")
    if info(g, "Player/Camera") is None:
        fails.append("camera not moved under Player")
    return fails


def t_run_setup(g, ctx):
    new_scene(g, ctx)
    code = ctx["secret"]
    g.call("script_write", path=ctx["dir"] + "/main.gd",
           content=f'extends Node2D\n\nfunc _ready():\n\tvar parts = [{code // 1000}, {code % 1000}]\n\tprint("CODE=", parts[0] * 1000 + parts[1])\n',
           attach_to=".")
    g.call("scene_save")


def c_run(g, ctx, answer):
    return [] if str(ctx["secret"]) in (answer or "") else [f"the answer does not contain {ctx['secret']}"]


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
        fails.append("array out-of-bounds error not fixed")
    if not ok:
        fails.append("main.gd does not compile")
    return fails


def t_class_setup(g, ctx):
    new_scene(g, ctx)


def c_class(g, ctx, answer):
    fails = []
    a = info(g, "Pickup")
    if a is None or "(Area2D)" not in a:
        return ["no Area2D Pickup"]
    if not re.search(r"body_entered -> (\.|Main)\._on_pickup_body_entered", a):
        fails.append("body_entered is not connected to Main._on_pickup_body_entered")
    c = info(g, "Pickup/CollisionShape2D") or ""
    if not has_prop(c, "shape", r"CircleShape2D"):
        fails.append("no CollisionShape2D with CircleShape2D")
    return fails


def t_tilemap_setup(g, ctx):
    new_scene(g, ctx)


def c_tilemap(g, ctx, answer):
    text, err = g.call("tilemap_read", path="Ground")
    if err:
        return ["no TileMapLayer Ground: " + text]
    info, _ = g.call("tilemap_info", path="Ground")
    fails = []
    if "32x32" not in info:
        fails.append("tile size is not 32x32")
    if "physics layers: 1" not in info:
        fails.append("tiles have no collision")
    rows = {int(l.split()[0]): l.split()[1] for l in text.split("\n")[1:] if l.strip() and l.strip().split()[0].lstrip("-").isdigit()}
    header = text.split("\n")[0]
    m = re.search(r"x from (-?\d+)", header)
    x0 = int(m.group(1)) if m else 0
    legend = dict(re.findall(r"(\S) = tile \[(\d+, \d+)\]", text))
    def tile_at(x, y):
        row = rows.get(y)
        if row is None or not (0 <= x - x0 < len(row)) or row[x - x0] == ".":
            return None
        return legend.get(row[x - x0])
    if any(tile_at(x, 6) != "0, 0" for x in range(0, 12)):
        fails.append("floor y=6, x=0..11 not filled with tile [0, 0]")
    if any(tile_at(x, 3) != "1, 0" for x in range(4, 8)):
        fails.append("platform y=3, x=4..7 is not tile [1, 0]")
    return fails


def t_anim_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="Sprite2D", name="Coin", properties={"texture": "res://icon.svg", "position": [100, 100]})


def c_anim(g, ctx, answer):
    text, err = g.call("anim_info", animation="spin")
    if err:
        return ["no animation spin: " + text]
    fails = []
    if re.search(r"\bno loop\b|^(?!.*\bloop)", text.split("\n")[1]):
        fails.append("spin is not looped")
    if 'autoplay "spin"' not in text:
        fails.append("spin is not autoplay")
    if not re.search(r"Coin:rotation: 0: 0; 1: 6\.28", text):
        fails.append("no Coin:rotation track 0 -> 6.28 over 1 s")
    if not re.search(r"Coin:position: 0: \[100, 100\]; 0\.5: \[100, 90\]; 1: \[100, 100\]", text):
        fails.append("no Coin:position track 100 -> 90 -> 100")
    return fails


def read_text(g, path):
    """Text of a project file as saved on disk (script_read works for any text file)."""
    text, err = g.call("script_read", path=path, start_line=1, end_line=100000)
    if err:
        return ""
    return "\n".join(l.split("| ", 1)[1] if "| " in l else "" for l in text.split("\n")[1:])


def tscn_section(text, header_re):
    """Body of the first [...] section of a .tscn whose header matches header_re, or None."""
    lines = text.split("\n")
    for i, l in enumerate(lines):
        if l.startswith("[") and re.search(header_re, l):
            body = []
            for b in lines[i + 1:]:
                if b.startswith("["):
                    break
                body.append(b)
            return "\n".join(body)
    return None


# Regressions for replies that used to say "success" when nothing (or not everything) happened.

ENEMY_CODE = ("@tool\nclass_name Enemy{secret}\nextends Node2D\n\nsignal died(enemy: Enemy{secret})\n\n"
              "var hp = 3\n")


def t_classname_setup(g, ctx):
    new_scene(g, ctx)


def c_classname(g, ctx, answer):
    path = ctx["dir"] + "/enemy.gd"
    ok, body = script_ok(g, path)
    if not body:
        return [f"no file {path}"]
    fails = []
    if not ok:
        fails.append("enemy.gd does not compile")
    if f"class_name Enemy{ctx['secret']}" not in body:
        fails.append("enemy.gd has no class_name Enemy" + str(ctx["secret"]))
    b = info(g, "Boss")
    if b is None:
        fails.append("no Boss node")
    elif path not in b:
        fails.append("Boss does not have the enemy.gd script")
    return fails


def t_instance_setup(g, ctx):
    child = ctx["dir"] + "/child.tscn"
    text, err = g.call("scene_new", path=child, type="Node2D", name="Child")
    if err:
        raise RuntimeError(text)
    g.call("node_add", type="Sprite2D", name="Pic", properties={"texture": "res://icon.svg"})
    g.call("scene_save")
    new_scene(g, ctx)
    g.call("node_add", type=child, name="Sub")
    g.call("scene_save")


def c_instance(g, ctx, answer):
    fails = []
    scene = read_text(g, ctx["scene"])
    pic = tscn_section(scene, r'name="Pic" parent="Sub"')
    if pic is None or not re.search(r"^visible = false", pic, re.M):
        fails.append("Sub/Pic is not hidden in the saved scene")
    tag = tscn_section(scene, r'name="Tag" type="Label" parent="Sub"')
    if tag is None:
        fails.append("no Label Tag under Sub in the saved scene")
    elif 'text = "boss"' not in tag:
        fails.append("Tag text is not boss")
    child = read_text(g, ctx["dir"] + "/child.tscn")
    if 'name="Pic" type="Sprite2D"' not in child or "visible = false" in child or "Tag" in child:
        fails.append("child.tscn was changed")
    return fails


def t_hitbox_setup(g, ctx):
    new_scene(g, ctx)
    g.call("node_add", type="CharacterBody2D", name="Player")


def c_hitbox(g, ctx, answer):
    fails = []
    scene = read_text(g, ctx["scene"])
    hb = tscn_section(scene, r'name="Hitbox" type="CollisionShape2D" parent="Player"')
    if hb is None:
        return ["no Player/Hitbox CollisionShape2D in the saved scene"]
    if not re.search(r"^position = Vector2\(0, -8\)", hb, re.M):
        fails.append("Hitbox is not at (0, -8)")
    m = re.search(r'^shape = SubResource\("([^"]+)"\)', hb, re.M)
    shape = tscn_section(scene, rf'type="RectangleShape2D" id="{re.escape(m.group(1))}"') if m else None
    if shape is None:
        fails.append("Hitbox has no RectangleShape2D")
    elif not re.search(r"^size = Vector2\(40, 20\)", shape, re.M):
        fails.append("the rectangle is not 40x20")
    if re.search(r'name="Hitbox\d+"', scene):
        fails.append("a duplicate Hitbox node was created")
    return fails


# ─────────────────────────────────────────────────────────────────────────────

TASKS = [
    {
        "id": "player",
        "setup": t_player_setup,
        "prompt": {
            "en": "In the open scene create a player: a CharacterBody2D node named Player at position (200, 300). Inside it add a Sprite2D with the texture res://icon.svg and a CollisionShape2D with a 64x64 rectangle shape. Save the scene.",
            "ru": "В открытой сцене создай игрока: узел CharacterBody2D с именем Player в позиции (200, 300). "
                  "Внутри него Sprite2D с текстурой res://icon.svg и CollisionShape2D с прямоугольной формой 64x64. Сохрани сцену.",
        },
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
        "prompt": {
            "en": "Add to the menu a button StartButton with the text Start and a yellow label ScoreLabel with the text \"Score: 0\". Save.",
            "ru": "Добавь в меню кнопку StartButton с текстом Start и метку ScoreLabel с текстом \"Score: 0\" жёлтого цвета. Сохрани.",
        },
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
        "prompt": {
            "en": "Write a script {dir}/player.gd for the Player node (CharacterBody2D): arrow-key movement (ui_left, ui_right, ui_up, ui_down) at speed 200 using move_and_slide. Attach it to Player and save the scene.",
            "ru": "Напиши скрипт {dir}/player.gd для узла Player (CharacterBody2D): движение стрелками "
                  "(ui_left, ui_right, ui_up, ui_down) со скоростью 200 через move_and_slide. Прикрепи его к Player и сохрани сцену.",
        },
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
        "prompt": {
            "en": "Make the StartButton button print \"Game started\" to the console when pressed. Name the handler _on_start_button_pressed and put it in the root node script. Save the scene.",
            "ru": "Сделай так, чтобы по нажатию кнопки StartButton в консоль печаталось \"Game started\". "
                  "Обработчик назови _on_start_button_pressed и положи в скрипт корневого узла. Сохрани сцену.",
        },
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
        "prompt": {
            "en": "The file {dir}/broken.gd has syntax errors. Find and fix them without changing the logic.",
            "ru": "В файле {dir}/broken.gd есть синтаксические ошибки. Найди и исправь их, не меняя логику.",
        },
        "check": c_fix,
        "golden": [
            ("script_edit", {"path": "{dir}/broken.gd", "old_text": "func _ready()", "new_text": "func _ready():"}),
            ("script_edit", {"path": "{dir}/broken.gd", "old_text": "if position.x > 500", "new_text": "if position.x > 500:"}),
        ],
    },
    {
        "id": "move",
        "setup": t_move_setup,
        "prompt": {
            "en": "Move the Coin node into Level and rename it to GoldCoin. Delete all enemies (Enemy... nodes) wherever they are. Save.",
            "ru": "Перенеси узел Coin внутрь Level и переименуй его в GoldCoin. Удали всех врагов (узлы Enemy...), где бы они ни были. Сохрани.",
        },
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
        "prompt": {
            "en": "Switch Player to the Floating motion mode (for a top-down view) and set its z_index to 5. Move the Camera node inside Player and zoom it in 2x. Save.",
            "ru": "Переключи Player в режим движения Floating (для вида сверху) и поставь ему z_index 5. "
                  "Камеру Camera перенеси внутрь Player и приблизь в 2 раза. Сохрани.",
        },
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
        "prompt": {
            "en": "Run the current scene and tell me which number the game prints after CODE=. Then stop the game.",
            "ru": "Запусти текущую сцену и скажи, какое число игра печатает после CODE=. Потом останови игру.",
        },
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
        "prompt": {
            "en": "Run the current scene, see what error happens in the game, fix it in the script and stop the game.",
            "ru": "Запусти текущую сцену, посмотри, какая ошибка возникает в игре, исправь её в скрипте и останови игру.",
        },
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
        "prompt": {
            "en": "Add a pickup item: an Area2D named Pickup with a circular collision shape. Connect its signal that fires when a physics body enters to the root node method _on_pickup_body_entered. Save.",
            "ru": "Добавь подбираемый предмет: Area2D с именем Pickup с круглой формой коллизии. "
                  "Подключи его сигнал, который срабатывает при входе физического тела, к методу _on_pickup_body_entered корневого узла. Сохрани.",
        },
        "check": c_class,
        "golden": [
            ("node_add", {"type": "Area2D", "name": "Pickup"}),
            ("node_add", {"parent": "Pickup", "type": "CollisionShape2D", "properties": {"shape": {"type": "CircleShape2D", "radius": 16}}}),
            ("signal_connect", {"from": "Pickup", "signal": "body_entered", "to": ".", "method": "_on_pickup_body_entered"}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "classname",
        "setup": t_classname_setup,
        "prompt": {
            "en": "Create a script {dir}/enemy.gd: a Node2D class with class_name Enemy{secret}, a variable hp = 3 and a signal died(enemy: Enemy{secret}). Then add a node of the class Enemy{secret} named Boss to the scene. Save.",
            "ru": "Создай скрипт {dir}/enemy.gd: класс на Node2D с class_name Enemy{secret}, переменной hp = 3 и сигналом "
                  "died(enemy: Enemy{secret}). Затем добавь в сцену узел класса Enemy{secret} с именем Boss. Сохрани.",
        },
        "check": c_classname,
        "golden": [
            # A self-reference in a class_name script used to fail the check, and a new class_name
            # was unknown to node_add until the editor rescanned the files.
            ("script_write", {"path": "{dir}/enemy.gd", "content": ENEMY_CODE}, {"error": False, "text": "Check: no errors"}),
            ("node_add", {"type": "Enemy{secret}", "name": "Boss"}, {"error": False}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "instance",
        "setup": t_instance_setup,
        "prompt": {
            "en": "The Sub node in the open scene is an instance of {dir}/child.tscn. In this scene only (do not change child.tscn) hide its Pic sprite and add to Sub a Label named Tag with the text boss. Save.",
            "ru": "Узел Sub в открытой сцене это инстанс {dir}/child.tscn. Только в этой сцене (child.tscn не меняй) "
                  "скрой его спрайт Pic и добавь в Sub метку Label с именем Tag и текстом boss. Сохрани.",
        },
        "check": c_instance,
        "golden": [
            # Deleting a node inside an instance is not saved by Godot: it must be an error, not "Deleted".
            ("node_delete", {"path": "Sub/Pic"}, {"error": True}),
            ("node_set", {"path": "Sub/Pic", "properties": {"visible": False}}, {"error": False}),
            ("node_add", {"parent": "Sub", "type": "Label", "name": "Tag", "properties": {"text": "boss"}}, {"error": False}),
            ("scene_tree", {}, {"text": r"Tag \(Label\)"}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "hitbox",
        "setup": t_hitbox_setup,
        "prompt": {
            "en": "Give Player a CollisionShape2D named Hitbox with a 40x20 rectangle shape, raised 8 pixels (position y = -8). Save.",
            "ru": "Добавь Player узел CollisionShape2D с именем Hitbox и прямоугольной формой 40x20, поднятый на 8 пикселей (position y = -8). Сохрани.",
        },
        "check": c_hitbox,
        "golden": [
            # Godot 3 property name: the node is created, but the reply must be an error.
            ("node_add", {"parent": "Player", "type": "CollisionShape2D", "name": "Hitbox",
                          "properties": {"shape": {"type": "RectangleShape2D", "extents": [20, 10]}}}, {"error": True}),
            # A Vector2 has no z: used to reply "position:z=null" as a success.
            ("node_set", {"path": "Player/Hitbox", "properties": {"position:z": -8}}, {"error": True}),
            ("node_set", {"path": "Player/Hitbox", "properties": {"shape": {"type": "RectangleShape2D", "size": [40, 20]},
                                                                   "position:y": -8}}, {"error": False}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "tilemap",
        "group": "tilemap",
        "setup": t_tilemap_setup,
        "prompt": {
            "en": "Make a tile level: a TileMapLayer named Ground with a tileset from res://icon.svg, 32x32 tiles with collision. Fill the floor with tile [0, 0] at y=6 from x=0 to x=11 and make a platform with tile [1, 0] at y=3 from x=4 to x=7. Save.",
            "ru": "Сделай уровень на тайлах: TileMapLayer с именем Ground, тайлсет из res://icon.svg с тайлами 32x32 и коллизией. "
                  "Залей пол тайлом [0, 0] по y=6 от x=0 до x=11 и сделай платформу тайлом [1, 0] по y=3 от x=4 до x=7. Сохрани.",
        },
        "check": c_tilemap,
        "golden": [
            ("tilemap_setup", {"path": "Ground", "texture": "res://icon.svg", "tile_size": [32, 32], "collision": True}),
            ("tilemap_paint", {"path": "Ground", "rect": [0, 6, 11, 6], "tile": [0, 0]}),
            ("tilemap_paint", {"path": "Ground", "rect": [4, 3, 7, 3], "tile": [1, 0]}),
            ("scene_save", {}),
        ],
    },
    {
        "id": "anim",
        "group": "animation",
        "setup": t_anim_setup,
        "prompt": {
            "en": "Give the Coin a 1-second animation spin, looped and autoplaying: rotation from 0 to 6.28 over the second, and at the same time position bounces from [100, 100] to [100, 90] at 0.5 s and back by 1 s. Save.",
            "ru": "Сделай монетке Coin анимацию spin длиной 1 секунда, зацикленную и с автозапуском: "
                  "rotation от 0 до 6.28 за секунду, и одновременно position подпрыгивает с [100, 100] до [100, 90] на 0.5 с и обратно к 1 с. Сохрани.",
        },
        "check": c_anim,
        "golden": [
            ("anim_create", {"name": "spin", "length": 1, "loop": True, "autoplay": True}),
            ("anim_key", {"animation": "spin", "target": "Coin", "property": "rotation",
                          "keys": [{"time": 0, "value": 0}, {"time": 1, "value": 6.28}]}),
            ("anim_key", {"animation": "spin", "target": "Coin", "property": "position",
                          "keys": [{"time": 0, "value": [100, 100]}, {"time": 0.5, "value": [100, 90]}, {"time": 1, "value": [100, 100]}]}),
            ("scene_save", {}),
        ],
    },
]
