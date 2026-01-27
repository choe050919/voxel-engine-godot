# scripts/utils/DebugMonitor.gd
extends Control

@export var update_interval := 0.5    # 갱신 주기
@export var show_peak_memory := true  # 피크 메모리도 보는 게 좋습니다 (메모리 누수 체크용)

var _accum := 0.0
var _label: Label
var _panel: PanelContainer

func _ready() -> void:
	# 릴리즈 빌드에서도 디버그 정보를 보고 싶다면 이 줄을 주석 처리하세요.
	if not OS.is_debug_build():
		queue_free()
		return
	
	# 항상 최상단에 그려지도록 설정
	z_index = 4096 
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	
	# UI 구성
	_panel = PanelContainer.new()
	add_child(_panel)
	_panel.add_theme_constant_override("margin_left", 10)
	_panel.add_theme_constant_override("margin_top", 10)
	_panel.add_theme_constant_override("margin_right", 10)
	_panel.add_theme_constant_override("margin_bottom", 10)
	
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.text = "Initializing..."
	_panel.add_child(_label)

func _input(event: InputEvent) -> void:
	# F3 키로 모니터 켜고 끄기
	if event.is_action_pressed("debug_toggle"): 
		visible = not visible

func _process(delta: float) -> void:
	if not visible:
		return

	_accum += delta
	if _accum < update_interval:
		return
	_accum = 0.0

	var fps := Engine.get_frames_per_second()
	var mem_mb := OS.get_static_memory_usage() / (1024.0 * 1024.0)
	var text := "FPS: %d\nMEM: %.2f MB" % [fps, mem_mb]

	if show_peak_memory:
		var peak_mb := OS.get_static_memory_peak_usage() / (1024.0 * 1024.0)
		text += "\nPEAK: %.2f MB" % peak_mb
		
	# 청크 개수 같은 것도 나중에 여기 추가하면 좋습니다.
	# text += "\nChunks: %d" % Global.chunk_count 

	_label.text = text
