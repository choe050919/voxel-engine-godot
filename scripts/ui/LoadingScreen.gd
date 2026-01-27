class_name LoadingScreen
extends CanvasLayer
## LoadingScreen.gd - Phase 2-8
## 월드 로딩 중 표시되는 UI

var _background: ColorRect
var _label: Label
var _progress_label: Label

var _current: int = 0
var _total: int = 1

var _time_label: Label
var _start_time: int = 0

func _ready() -> void:
	# 가장 위에 표시
	layer = 100

	_create_ui()
	
	_start_time = Time.get_ticks_msec()


func _create_ui() -> void:
	# 배경 (검은색 전체 화면)
	_background = ColorRect.new()
	_background.color = Color(0.05, 0.05, 0.08, 1.0)
	_background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_background)

	# 메인 컨테이너 (중앙 정렬)
	var container := VBoxContainer.new()
	container.set_anchors_preset(Control.PRESET_CENTER)
	container.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(container)

	# 메인 타이틀
	_label = Label.new()
	_label.text = "Generating Terrain..."
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 32)
	_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	container.add_child(_label)

	# 진행률 표시
	_progress_label = Label.new()
	_progress_label.text = "0 / 0"
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.add_theme_font_size_override("font_size", 18)
	_progress_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	container.add_child(_progress_label)

	_time_label = Label.new()
	_time_label.text = "0.0s"
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_label.add_theme_font_size_override("font_size", 16)
	_time_label.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	container.add_child(_time_label)

## 진행 상황 업데이트
func update_progress(current: int, total: int) -> void:
	_current = current
	_total = total

	if _progress_label:
		_progress_label.text = "%d / %d chunks" % [current, total]

		# 퍼센트 계산
		var percent: float = 0.0
		if total > 0:
			percent = (float(current) / float(total)) * 100.0

		_label.text = "Generating Terrain... %.0f%%" % percent


func _process(_delta: float) -> void:
	if _time_label:
		var elapsed: float = (Time.get_ticks_msec() - _start_time) / 1000.0
		_time_label.text = "%.1fs" % elapsed


## 로딩 완료 - 페이드 아웃 후 삭제
func finish_loading() -> void:
	# 간단한 페이드 아웃 애니메이션
	var tween := create_tween()
	tween.tween_property(_background, "modulate:a", 0.0, 0.5)
	tween.parallel().tween_property(_label, "modulate:a", 0.0, 0.3)
	tween.parallel().tween_property(_progress_label, "modulate:a", 0.0, 0.3)
	tween.tween_callback(queue_free)
