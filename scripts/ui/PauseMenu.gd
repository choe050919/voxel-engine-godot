extends CanvasLayer
## PauseMenu.gd - 인게임 ESC 메뉴
## Phase 5-2: 일시정지 메뉴 로직

# ============================================
# Node References
# ============================================
@onready var menu_container: Control = $Control
@onready var btn_resume: Button = $Control/Panel/VBoxContainer/BtnResume
@onready var btn_save_quit: Button = $Control/Panel/VBoxContainer/BtnSaveQuit

# ============================================
# State
# ============================================
var is_paused: bool = false


func _ready() -> void:
	# 초기 상태: 숨김
	menu_container.visible = false
	is_paused = false

	# 버튼 연결
	btn_resume.pressed.connect(_on_resume_pressed)
	btn_save_quit.pressed.connect(_on_save_quit_pressed)

	# 이 노드는 일시정지 중에도 처리되어야 함
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_pause()
		get_viewport().set_input_as_handled()


func _toggle_pause() -> void:
	if is_paused:
		_resume_game()
	else:
		_pause_game()


func _pause_game() -> void:
	is_paused = true
	menu_container.visible = true
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _resume_game() -> void:
	is_paused = false
	menu_container.visible = false
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# ============================================
# Button Callbacks
# ============================================

func _on_resume_pressed() -> void:
	_resume_game()


func _on_save_quit_pressed() -> void:
	# Phase 5-3: 플레이어 위치 저장
	if WorldGenerator.instance and WorldGenerator.instance.player:
		var p = WorldGenerator.instance.player
		var save_data: Dictionary = p.get_save_data() if p.has_method("get_save_data") else {}
		if not save_data.is_empty():
			SaveManager.save_player_to_world_meta(
				save_data.get("position", Vector3(8, 50, 8)),
				save_data.get("rotation_y", 0.0),
				save_data.get("head_rotation_x", 0.0)
			)

	# 동기 저장 (모든 Dirty 청크)
	if WorldGenerator.instance:
		SaveManager.flush_dirty_chunks_sync(WorldGenerator.instance.active_chunks)
		print("[PauseMenu] Game saved (chunks + player position)")

	# 일시정지 해제 (씬 전환 전 필수)
	get_tree().paused = false
	is_paused = false

	# 메인 메뉴로 이동
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
