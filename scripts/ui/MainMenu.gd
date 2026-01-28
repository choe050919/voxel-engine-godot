extends Control
## MainMenu.gd - 게임 시작 진입점
## Phase 5-2: 메인 메뉴 UI 로직

# ============================================
# Node References
# ============================================
@onready var btn_new_game: Button = $VBoxContainer/BtnNewGame
@onready var btn_load_game: Button = $VBoxContainer/BtnLoadGame
@onready var btn_quit: Button = $VBoxContainer/BtnQuit

@onready var popup_new_game: Panel = $PopupNewGame
@onready var line_edit_name: LineEdit = $PopupNewGame/VBoxContainer/LineEditName
@onready var line_edit_seed: LineEdit = $PopupNewGame/VBoxContainer/LineEditSeed
@onready var btn_start_create: Button = $PopupNewGame/VBoxContainer/BtnStartCreate
@onready var btn_cancel_new: Button = $PopupNewGame/VBoxContainer/BtnCancelNew

@onready var popup_load_game: Panel = $PopupLoadGame
@onready var world_list: ItemList = $PopupLoadGame/VBoxContainer/WorldList
@onready var btn_start_load: Button = $PopupLoadGame/VBoxContainer/HBoxContainer/BtnStartLoad
@onready var btn_delete_world: Button = $PopupLoadGame/VBoxContainer/HBoxContainer/BtnDeleteWorld
@onready var btn_cancel_load: Button = $PopupLoadGame/VBoxContainer/BtnCancelLoad

# ============================================
# State
# ============================================
var _world_list_data: Array[Dictionary] = []


func _ready() -> void:
	# 마우스 표시
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# 팝업 숨김
	popup_new_game.visible = false
	popup_load_game.visible = false

	# 버튼 연결
	btn_new_game.pressed.connect(_on_new_game_pressed)
	btn_load_game.pressed.connect(_on_load_game_pressed)
	btn_quit.pressed.connect(_on_quit_pressed)

	btn_start_create.pressed.connect(_on_start_create_pressed)
	btn_cancel_new.pressed.connect(_on_cancel_new_pressed)

	btn_start_load.pressed.connect(_on_start_load_pressed)
	btn_delete_world.pressed.connect(_on_delete_world_pressed)
	btn_cancel_load.pressed.connect(_on_cancel_load_pressed)

	world_list.item_selected.connect(_on_world_list_item_selected)

	# 초기 상태
	btn_start_load.disabled = true
	btn_delete_world.disabled = true


# ============================================
# Main Menu Buttons
# ============================================

func _on_new_game_pressed() -> void:
	line_edit_name.text = "New World"
	line_edit_seed.text = ""
	popup_new_game.visible = true
	line_edit_name.grab_focus()


func _on_load_game_pressed() -> void:
	_refresh_world_list()
	popup_load_game.visible = true


func _on_quit_pressed() -> void:
	get_tree().quit()


# ============================================
# New Game Popup
# ============================================

func _on_start_create_pressed() -> void:
	var world_name := line_edit_name.text.strip_edges()
	if world_name.is_empty():
		world_name = "Unnamed World"

	var seed_text := line_edit_seed.text.strip_edges()
	var seed_value: int = -1
	if not seed_text.is_empty():
		if seed_text.is_valid_int():
			seed_value = seed_text.to_int()
		else:
			# 문자열을 해시로 변환
			seed_value = seed_text.hash()

	# 월드 생성
	var world_id := SaveManager.create_world(world_name, seed_value)

	# 생성된 월드 로드
	if SaveManager.set_current_world(world_id):
		_start_game()
	else:
		push_error("[MainMenu] Failed to load created world")


func _on_cancel_new_pressed() -> void:
	popup_new_game.visible = false


# ============================================
# Load Game Popup
# ============================================

func _refresh_world_list() -> void:
	world_list.clear()
	_world_list_data = SaveManager.get_world_list()

	for world_meta in _world_list_data:
		var display_name := "%s (Seed: %d)" % [world_meta.name, world_meta.seed]
		world_list.add_item(display_name)

	btn_start_load.disabled = true
	btn_delete_world.disabled = true


func _on_world_list_item_selected(index: int) -> void:
	btn_start_load.disabled = false
	btn_delete_world.disabled = false


func _on_start_load_pressed() -> void:
	var selected := world_list.get_selected_items()
	if selected.is_empty():
		return

	var index := selected[0]
	var world_id: String = _world_list_data[index].id

	if SaveManager.set_current_world(world_id):
		_start_game()
	else:
		push_error("[MainMenu] Failed to load world: %s" % world_id)


func _on_delete_world_pressed() -> void:
	var selected := world_list.get_selected_items()
	if selected.is_empty():
		return

	var index := selected[0]
	var world_id: String = _world_list_data[index].id

	if SaveManager.delete_world(world_id):
		_refresh_world_list()


func _on_cancel_load_pressed() -> void:
	popup_load_game.visible = false


# ============================================
# Game Start
# ============================================

func _start_game() -> void:
	print("[MainMenu] Starting game with world: %s" % SaveManager.current_world_id)
	get_tree().change_scene_to_file("res://scenes/world/World.tscn")
