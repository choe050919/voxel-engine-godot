class_name WorldGenerator
extends Node3D
## WorldGenerator.gd - 무한 청크 로딩 시스템
## Phase 2-7: WorkerThreadPool 멀티스레딩 + LOD

# ================================
# Debug Logging (Inspector에서 토글)
# ================================
@export_group("Debug Logging")
@export var log_mesh: bool = false       ## [MESH], [THREAD]
@export var log_collision: bool = false  ## [DIAG] collision, [LAG SPIKE]
@export var log_perf: bool = true        ## [PERF]
@export var log_physics: bool = false    ## [Physics]
@export var log_debug: bool = false      ## [DEBUG]
@export var log_diag: bool = false       ## [DIAG] 기타

# ================================
# Singleton Instance
# ================================
static var instance: WorldGenerator = null

# ================================
# Noise Settings
# ================================
var noise_base: FastNoiseLite
var noise_mountain: FastNoiseLite

# ================================
# Chunk Management
# ================================
var active_chunks: Dictionary = {}     # Vector2i -> VoxelChunk
var chunk_load_queue: Array = []       # 생성 대기 큐
var chunk_unload_queue: Array = []     # 삭제 대기 큐

var _chunk_cache: Dictionary = {}  # Vector2i -> VoxelChunk (삭제 대기)
const MAX_CACHED_CHUNKS: int = 50

# ================================
# Mesh Update Queue (Phase 2-7 WorkerThreadPool)
# ================================
var _mesh_update_queue: Array[VoxelChunk] = []  # 메쉬 갱신 대기 큐
var _is_mesh_updating: bool = false             # 현재 스레드 작업 진행 중 여부

# ================================
# Phase 2-Optimization: Main Thread Throttling Queues
# ================================
var _chunk_apply_queue: Array[VoxelChunk] = []      # 메쉬+충돌체 적용 대기 큐
var _collision_request_queue: Array[VoxelChunk] = []  # 충돌체만 생성 대기 큐
const CHUNK_APPLIES_PER_FRAME: int = 1              # 프레임당 적용할 청크 수
const COLLISION_CREATES_PER_FRAME: int = 1          # 프레임당 충돌체 생성 수

# ================================
# Thread Pool Saturation Prevention (스레드 기아 방지)
# ================================
const MAX_CONCURRENT_BACKGROUND_TASKS: int = 6      # 배경 작업 최대 동시 실행 수
var _current_background_tasks: int = 0              # 현재 실행 중인 배경 작업 수

# ================================
# Player Tracking
# ================================
var player: Node3D = null
var last_player_chunk: Vector2i = Vector2i(999999, 999999)

# ================================
# Phase 2-9: Dynamic Physics Bubble
# ================================
var _physics_bubble_center: Vector2i = Vector2i(999999, 999999)  # 물리 버블 중심

# ================================
# Debug: Fall Trap
# ================================
var _has_reported_fall: bool = false  # 낙하 보고 여부 (1회만)

# ================================
# Performance
# ================================
var chunks_generated_this_frame: int = 0
var _fps_log_timer: float = 0.0  # FPS 로깅 타이머

# ================================
# Benchmark System
# ================================
var _benchmark_time: float = 0.0
var _benchmark_duration: float = 30.0  # 30초 후 통계 출력
var _benchmark_done: bool = false
var _stats_fps: Array[float] = []
var _stats_finalize_ms: Array[float] = []
var _stats_collision_ms: Array[float] = []

# ================================
# Phase 2-8: Initial Loading State
# ================================
var _is_initial_loading: bool = true              # 초기 로딩 중 여부
var _initial_chunks_to_load: int = 0              # 로딩해야 할 총 청크 수
var _initial_chunks_finalized: int = 0            # finalize_build 완료된 청크 수
var _loading_screen: LoadingScreen = null         # 로딩 UI 참조
const INITIAL_LOAD_RADIUS: int = 3                # 초기 로딩 반경 (Physics Distance 기반)

# ㅇㅇ
var _priority_apply_queue: Array[VoxelChunk] = []

# 인접 청크 방향 (4방향)
const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(1, 0),   # +X
	Vector2i(-1, 0),  # -X
	Vector2i(0, 1),   # +Z
	Vector2i(0, -1),  # -Z
]


func _ready() -> void:
	# Phase 5-2: 안전장치 - 메인 메뉴를 거치지 않고 실행되었을 경우 방어
	if SaveManager.current_world_id == "":
		push_warning("[WorldGenerator] No world loaded. Returning to MainMenu.")
		get_tree().call_deferred("change_scene_to_file", "res://scenes/MainMenu.tscn")
		return

	instance = self
	_setup_noise()
	_setup_initial_loading()
	call_deferred("_find_player")

	# 로깅 설정 상태 출력
	print("[CONFIG] Logging: mesh=%s, collision=%s, perf=%s, physics=%s, debug=%s, diag=%s" % [
		log_mesh, log_collision, log_perf, log_physics, log_debug, log_diag
	])

func _exit_tree() -> void:
	if instance == self:
		# Phase 5: 종료 시 모든 Dirty 청크 동기 저장
		SaveManager.flush_dirty_chunks_sync(active_chunks)
		instance = null


func _process(_delta: float) -> void:
	if player == null:
		return

	_update_player_chunk()

	# 청크 생성/삭제 처리
	chunks_generated_this_frame = 0
	_process_load_queue()
	_process_unload_queue()

	# ★ 메쉬 업데이트 큐 처리 (프레임당 제한)
	_process_mesh_update_queue()

	# ★ [Critical Optimization] 청크 적용 큐 처리 (프레임당 1개)
	_process_chunk_apply_queue()

	# ★ Phase 2-9: Dynamic Physics Bubble (실시간 물리 영역 갱신)
	_update_physics_bubble()

	# ★ [Critical Optimization] 충돌체 생성 큐 처리 (프레임당 1개)
	_process_collision_request_queue()

	_cleanup_chunk_cache()

	# ★ [Fall Trap] 플레이어가 땅(Y=0) 아래로 떨어지면 상태 덤프
	if player and player.global_position.y < -10.0 and not _has_reported_fall:
		_has_reported_fall = true
		print("\n!!!!!!!!!! PLAYER FELL THROUGH WORLD !!!!!!!!!!")
		print("[FALL TRAP] Player Position: %s" % player.global_position)
		print("[FALL TRAP] Player Velocity: %s" % player.velocity)
		print("[FALL TRAP] is_locked: %s" % player.is_locked)
		print("[FALL TRAP] is_on_floor: %s" % player.is_on_floor())

		# 플레이어 주변 청크 상태 덤프
		var player_chunk: Vector2i = Global.world_to_chunk(player.global_position)
		print("[FALL TRAP] Player Chunk: %s" % player_chunk)
		print("[FALL TRAP] Physics Bubble Center: %s" % _physics_bubble_center)

		print("\n[FALL TRAP] === Nearby Chunks Status ===")
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				var check_pos: Vector2i = player_chunk + Vector2i(dx, dz)
				if active_chunks.has(check_pos):
					var chunk: VoxelChunk = active_chunks[check_pos]
					var dist: float = Vector2(player_chunk - check_pos).length()
					print("[FALL TRAP] Chunk %s (dist=%.1f): has_collision=%s, has_physics_body=%s, is_thread_running=%s" % [
						check_pos, dist,
						chunk.has_collision(),
						chunk.has_physics_body(),
						chunk.is_thread_running()
					])
				else:
					print("[FALL TRAP] Chunk %s: NOT LOADED" % check_pos)

		print("\n[FALL TRAP] === Queue Status ===")
		print("[FALL TRAP] Mesh Update Queue: %d" % _mesh_update_queue.size())
		print("[FALL TRAP] Chunk Apply Queue: %d" % _chunk_apply_queue.size())
		print("[FALL TRAP] Collision Request Queue: %d" % _collision_request_queue.size())
		print("[FALL TRAP] Is Mesh Updating: %s" % _is_mesh_updating)
		print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n")

	# ★ [PERF] 1초마다 FPS 및 큐 상태 출력
	_fps_log_timer += _delta
	if _fps_log_timer >= 1.0:
		_fps_log_timer = 0.0
		if log_perf:
			print("[PERF] FPS: %d | MeshQ: %d | ApplyQ: %d | ColQ: %d | Chunks: %d" % [
				Engine.get_frames_per_second(),
				_mesh_update_queue.size(),
				_chunk_apply_queue.size(),
				_collision_request_queue.size(),
				active_chunks.size()
			])

	# ★ [BENCHMARK] 30초간 성능 데이터 수집
	if not _benchmark_done:
		_benchmark_time += _delta
		_stats_fps.append(Engine.get_frames_per_second())

		if _benchmark_time >= _benchmark_duration:
			_print_benchmark()
			_benchmark_done = true


## 벤치마크 기록 함수
func record_finalize_time(ms: float) -> void:
	if not _benchmark_done:
		_stats_finalize_ms.append(ms)


func record_collision_time(ms: float) -> void:
	if not _benchmark_done:
		_stats_collision_ms.append(ms)


## 벤치마크 결과 출력
func _print_benchmark() -> void:
	if not log_perf:
		return

	print("\n" + "=".repeat(60))
	print("📊 BENCHMARK RESULTS (%.0f seconds)" % _benchmark_duration)
	print("=".repeat(60))

	# FPS 통계
	if _stats_fps.size() > 0:
		var fps_min: int = _stats_fps.min()
		var fps_max: int = _stats_fps.max()
		var fps_sum: int = 0
		for fps in _stats_fps:
			fps_sum += fps
		var fps_avg: float = float(fps_sum) / float(_stats_fps.size())
		print("FPS: min=%d, max=%d, avg=%.1f" % [fps_min, fps_max, fps_avg])
	else:
		print("FPS: no data")

	# finalize_build 통계
	if _stats_finalize_ms.size() > 0:
		var fin_min: float = _stats_finalize_ms.min()
		var fin_max: float = _stats_finalize_ms.max()
		var fin_sum: float = 0.0
		for ms in _stats_finalize_ms:
			fin_sum += ms
		var fin_avg: float = fin_sum / float(_stats_finalize_ms.size())
		print("finalize_build: min=%.1fms, max=%.1fms, avg=%.1fms, count=%d" % [fin_min, fin_max, fin_avg, _stats_finalize_ms.size()])
	else:
		print("finalize_build: no data")

	# collision_create 통계
	if _stats_collision_ms.size() > 0:
		var col_min: float = _stats_collision_ms.min()
		var col_max: float = _stats_collision_ms.max()
		var col_sum: float = 0.0
		for ms in _stats_collision_ms:
			col_sum += ms
		var col_avg: float = col_sum / float(_stats_collision_ms.size())
		print("collision_create: min=%.1fms, max=%.1fms, avg=%.1fms, count=%d" % [col_min, col_max, col_avg, _stats_collision_ms.size()])
	else:
		print("collision_create: no data")

	print("Total chunks: %d" % active_chunks.size())
	print("=".repeat(60) + "\n")


## Phase 2-8: 초기 로딩 설정
func _setup_initial_loading() -> void:
	_is_initial_loading = true
	_initial_chunks_finalized = 0  # finalize_build 완료 카운터

	# 초기 로딩할 청크 수 계산 (원형 반경)
	var count: int = 0
	for x in range(-INITIAL_LOAD_RADIUS, INITIAL_LOAD_RADIUS + 1):
		for z in range(-INITIAL_LOAD_RADIUS, INITIAL_LOAD_RADIUS + 1):
			var dist: float = Vector2(x, z).length()
			if dist <= INITIAL_LOAD_RADIUS:
				count += 1

	_initial_chunks_to_load = count

	# 로딩 UI 생성
	_loading_screen = LoadingScreen.new()
	add_child(_loading_screen)
	_loading_screen.update_progress(0, _initial_chunks_to_load)


## 플레이어 노드 찾기
func _find_player() -> void:
	player = get_parent().get_node_or_null("Player")
	if player:
		# Phase 2-8: 초기 로딩 중이면 플레이어 잠금
		if _is_initial_loading and player.has_method("lock"):
			player.lock()

		last_player_chunk = Vector2i(999999, 999999)
		_update_player_chunk()


## 노이즈 설정
func _setup_noise() -> void:
	noise_base = FastNoiseLite.new()
	
	# 저장 매니저에서 현재 월드의 시드를 가져옴
	var saved_seed = SaveManager.get_current_seed()
	if saved_seed != 0:
		noise_base.seed = saved_seed
		print("[WorldGenerator] Applied saved seed: %d" % saved_seed)
	else:
		noise_base.seed = randi() # 비상용
	
	noise_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_base.frequency = 0.01
	noise_base.fractal_octaves = 4
	noise_base.fractal_lacunarity = 2.0
	noise_base.fractal_gain = 0.5

	noise_mountain = FastNoiseLite.new()
	noise_mountain.seed = noise_base.seed + 1000
	noise_mountain.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_mountain.frequency = 0.02
	noise_mountain.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	noise_mountain.fractal_octaves = 5
	noise_mountain.fractal_lacunarity = 2.0
	noise_mountain.fractal_gain = 0.5


# ================================
# Mesh Update Queue System (Phase 2-7 WorkerThreadPool)
# ================================

## 메쉬 업데이트 요청 (큐에 추가)
func request_mesh_update(chunk: VoxelChunk) -> void:
	# null 체크
	if chunk == null:
		return

	# 이미 삭제 예정인 청크는 무시
	if not is_instance_valid(chunk):
		return

	# 중복 체크 (이미 큐에 있으면 추가하지 않음)
	if chunk in _mesh_update_queue:
		return

	_mesh_update_queue.append(chunk)


## 메쉬 업데이트 큐 처리 (Phase 2-7: WorkerThreadPool)
func _process_mesh_update_queue() -> void:
	# 이미 스레드 작업 진행 중이면 스킵
	if _is_mesh_updating:
		return

	# 큐가 비어있으면 스킵
	if _mesh_update_queue.is_empty():
		return

	# 다음 청크 가져오기
	var chunk: VoxelChunk = _mesh_update_queue.pop_front()

	# 유효성 검사 (청크가 삭제되었을 수 있음)
	if not is_instance_valid(chunk):
		return

	# 청크가 아직 active_chunks에 있는지 확인
	if not active_chunks.has(chunk.chunk_position):
		return

	# 이미 스레드 작업 중인 청크는 스킵
	if chunk.is_thread_running():
		_mesh_update_queue.append(chunk)  # 다시 큐에 넣기
		return

	# 스레드 기반 메쉬 업데이트 시작
	_start_threaded_mesh_update(chunk)


## Phase 2-7: 스레드 기반 메쉬 업데이트 시작
func _start_threaded_mesh_update(chunk: VoxelChunk) -> void:
	_is_mesh_updating = true

	# 물리 거리 체크하여 충돌체 필요 여부 결정
	var dist: float = Vector2(last_player_chunk - chunk.chunk_position).length()
	var needs_collision: bool = dist <= Global.PHYSICS_DISTANCE

	# 완료 시그널 연결 (일회성)
	if not chunk.mesh_thread_completed.is_connected(_on_chunk_mesh_thread_completed):
		chunk.mesh_thread_completed.connect(_on_chunk_mesh_thread_completed.bind(chunk), CONNECT_ONE_SHOT)

	# 스레드 작업 시작
	chunk.start_threaded_mesh_update(needs_collision)


## 청크 메쉬 스레드 완료 콜백
func _on_chunk_mesh_thread_completed(chunk: VoxelChunk) -> void:
	_is_mesh_updating = false

	# 유효성 검사
	if not is_instance_valid(chunk):
		return

	# 물리 거리 밖이면 충돌체 제거 (상태 변경 대응)
	if active_chunks.has(chunk.chunk_position):
		var dist: float = Vector2(last_player_chunk - chunk.chunk_position).length()
		if dist > Global.PHYSICS_DISTANCE:
			chunk.disable_collision()

	# Note: 초기 로딩 카운트는 _create_chunk에서만 증가
	# (메쉬 업데이트는 기존 청크 갱신이므로 카운트하지 않음)


## ★ 배경 작업 완료 콜백 (스레드 풀 여유 확보)
func _on_background_task_completed() -> void:
	if _current_background_tasks > 0:
		_current_background_tasks -= 1
	
	# 대기 중인 작업이 있으면 즉시 처리 시도
	if chunk_load_queue.size() > 0:
		_process_load_queue()


# ================================
# Phase 2-Optimization: Chunk Apply Queue (Main Thread Throttling)
# ================================

## VoxelChunk가 스레드 완료 후 호출하는 적용 요청 함수
func request_chunk_apply(chunk: VoxelChunk) -> void:
	if not is_instance_valid(chunk):
		return

	# 중복 방지
	if chunk in _chunk_apply_queue:
		return

	_chunk_apply_queue.append(chunk)

## 청크 적용 큐 처리
func _process_chunk_apply_queue() -> void:
	var frame_start: int = Time.get_ticks_usec()

	# ★ 우선순위 큐: 무조건 모두 처리 (타임 버짓 무시)
	while not _priority_apply_queue.is_empty():
		var chunk = _priority_apply_queue.pop_front()
		if is_instance_valid(chunk) and chunk.is_inside_tree() and active_chunks.has(chunk.chunk_position):
			if chunk.has_method("finalize_build"):
				chunk.finalize_build()

	if _chunk_apply_queue.is_empty():
		return

	# ★ 초기 로딩: 큐 전체를 한 프레임에 처리 (타임 버짓 무시)
	# ★ 일반 상태: 프레임당 1개, 8ms 타임 버짓 적용
	var process_count: int = _chunk_apply_queue.size() if _is_initial_loading else 1

	for i in range(process_count):
		# ★ 타임 버짓 체크 - 초기 로딩 시 건너뜀
		if not _is_initial_loading:
			if Time.get_ticks_usec() - frame_start > 8000:
				if log_perf:
					print("[TIME_BUDGET] Chunk apply paused at %d µs" % (Time.get_ticks_usec() - frame_start))
				break
		if _chunk_apply_queue.is_empty():
			break
		var chunk = _chunk_apply_queue.pop_front()
		if not is_instance_valid(chunk):
			continue
		if not chunk.is_inside_tree():
			continue
		if not active_chunks.has(chunk.chunk_position):
			continue
		if chunk.has_method("finalize_build"):
			chunk.finalize_build()
		if _is_initial_loading:
			_initial_chunks_finalized += 1
	
	if _is_initial_loading:
		# 로딩 진행률 업데이트
		if _loading_screen and is_instance_valid(_loading_screen):
			_loading_screen.update_progress(_initial_chunks_finalized, _initial_chunks_to_load)

		# ★ 초기 청크 수만큼 finalize 완료되면 즉시 로딩 종료
		# 나머지 청크는 게임 중 배경에서 로드
		if _initial_chunks_finalized >= _initial_chunks_to_load:
			if log_diag:
				print("[DIAG] Initial chunks finalized: %d/%d. Starting game!" % [
					_initial_chunks_finalized, _initial_chunks_to_load
				])
			_finish_initial_loading()


## 충돌체 생성 요청 (큐에 추가)
func request_collision_create(chunk: VoxelChunk) -> void:
	if not is_instance_valid(chunk):
		return
	if chunk not in _collision_request_queue:
		_collision_request_queue.append(chunk)

## 충돌체 생성 요청 큐 처리 (프레임당 1개만 - Physics Bubble용)
func _process_collision_request_queue() -> void:
	if _collision_request_queue.is_empty():
		return

	# 프레임당 COLLISION_CREATES_PER_FRAME 개만 처리
	for i in range(COLLISION_CREATES_PER_FRAME):
		if _collision_request_queue.is_empty():
			break

		var chunk: VoxelChunk = _collision_request_queue.pop_front()

		# 유효성 검사
		if not is_instance_valid(chunk):
			continue

		if not chunk.is_inside_tree():
			continue

		if not active_chunks.has(chunk.chunk_position):
			continue

		# 충돌체 생성 (캐시된 쉐이프 사용)
		chunk.create_collision_robust()


# ================================
# Phase 2-9: Dynamic Physics Bubble
# ================================

## 플레이어 위치 기반 물리 버블 업데이트
func _update_physics_bubble() -> void:
	if not player:
		return

	# 초기 로딩 중에는 스킵 (별도 처리)
	if _is_initial_loading:
		return

	# 플레이어의 현재 청크 좌표 계산
	var current_player_chunk: Vector2i = Global.world_to_chunk(player.global_position)

	# 청크 경계를 넘었는지 확인 (Change Detection)
	if current_player_chunk == _physics_bubble_center:
		return  # 변화 없음

	if log_physics:
		print("[Physics] Player moved to chunk %s. Updating bubble..." % current_player_chunk)
	_physics_bubble_center = current_player_chunk

	# 모든 활성 청크의 물리 상태 재계산
	_recalculate_physics_states(current_player_chunk)


func _recalculate_physics_states(center: Vector2i) -> void:
	for chunk_pos in active_chunks.keys():
		var chunk: VoxelChunk = active_chunks[chunk_pos]
		
		# [핵심] 플레이어가 서 있는 청크는 무조건 활성화 상태 유지 
		if chunk_pos == center:
			chunk.enable_collision()
			continue
			
		var dist: float = Vector2(center - chunk_pos).length()
		var should_have_collision: bool = dist <= Global.PHYSICS_DISTANCE
		
		if should_have_collision:
			chunk.enable_collision()
		else:
			chunk.disable_collision()

# ================================
# Phase 2-8: Initial Loading Management
# ================================

## 초기 로딩 완료 처리
## 초기 로딩 완료 처리 (수정본)
func _finish_initial_loading() -> void:
	VoxelChunk.prewarm_pool(200)

	_is_initial_loading = false
	if log_diag:
		print("=" .repeat(60))
		print("[DIAG] ===== INITIAL LOADING FINISH SEQUENCE =====")

	# 1. [FIX] 플레이어 데이터 먼저 로드 (위치 파악을 위해)
	var target_chunk_pos := Vector2i(0, 0)
	var player_data := {}
	
	if SaveManager.current_world_id != "":
		player_data = SaveManager.get_player_data_from_world_meta()
		if not player_data.is_empty() and player_data.has("position"):
			var pos_dict = player_data["position"]
			var pos_vec = Vector3(pos_dict.x, pos_dict.y, pos_dict.z)
			# 플레이어가 로드될 청크 계산
			target_chunk_pos = Global.world_to_chunk(pos_vec)
			if log_diag:
				print("[DIAG] Save data found. Target chunk: %s" % target_chunk_pos)

	# 2. [FIX] 플레이어가 서 있을 '그 청크'가 준비될 때까지 대기
	# (기존에는 무조건 (0,0)만 기다렸음)
	await _wait_for_spawn_chunk_collision(target_chunk_pos)

	# 물리 엔진 안정화 대기
	await get_tree().physics_frame
	await get_tree().physics_frame

	# 3. 플레이어 위치 복원
	if player:
		if not player_data.is_empty() and player.has_method("apply_save_data"):
			player.apply_save_data(player_data)
			if log_diag:
				print("[DIAG] Player position restored from save")
		else:
			_snap_player_to_ground()

	await _verify_floor_with_raycast_retry()

	# 물리 버블 초기화
	if player:
		_physics_bubble_center = Global.world_to_chunk(player.global_position)
	
	# 로딩 화면 종료 및 잠금 해제
	if _loading_screen and is_instance_valid(_loading_screen):
		_loading_screen.finish_loading()
		_loading_screen = null

	if player and player.has_method("unlock"):
		player.unlock()
	
	if log_diag:
		print("[DIAG] Game starting!")

## Phase 2-8 Critical Fix: 스폰 청크 충돌체 대기 (실제 물리 노드 검증)
func _wait_for_spawn_chunk_collision(target_chunk: Vector2i = Vector2i(0, 0)) -> int:
	var start_chunk_key := target_chunk
	var total_wait_frames: int = 0

	if log_diag:
		print("[DIAG] Waiting for target chunk %s collision..." % target_chunk)

	# 1. 청크가 active_chunks에 존재할 때까지 대기
	while not active_chunks.has(start_chunk_key):
		await get_tree().process_frame
		total_wait_frames += 1
		if total_wait_frames % 10 == 0 and log_diag:
			print("[DIAG] Waiting for chunk (0,0) to exist... frame %d" % total_wait_frames)

	var start_chunk: VoxelChunk = active_chunks[start_chunk_key]
	if log_diag:
		print("[DIAG] Chunk (0,0) found after %d frames" % total_wait_frames)

	# 2. 스레드 작업 완료 대기
	var thread_wait: int = 0
	while start_chunk.is_thread_running():
		await get_tree().process_frame
		thread_wait += 1
		total_wait_frames += 1
		if thread_wait % 10 == 0 and log_diag:
			print("[DIAG] Waiting for thread to complete... frame %d" % thread_wait)

	if log_diag:
		print("[DIAG] Thread completed after %d frames" % thread_wait)

	# 3. 충돌체 강제 생성 (Robust 버전 사용)
	if not start_chunk.has_collision() or not start_chunk.has_physics_body():
		if log_diag:
			print("[DIAG] Forcing robust collision creation...")
		start_chunk.create_collision_robust()

		# deferred 호출이 완료될 때까지 대기
		await get_tree().process_frame
		await get_tree().process_frame

	# 4. 실제 물리 노드가 씬 트리에 존재하는지 확인
	var collision_wait_frames: int = 0
	const MAX_WAIT_FRAMES: int = 120  # 2초

	while not start_chunk.has_physics_body():
		await get_tree().process_frame
		collision_wait_frames += 1
		total_wait_frames += 1

		if collision_wait_frames % 10 == 0:
			if log_diag:
				print("[DIAG] Waiting for physics body... frame %d" % collision_wait_frames)
				print("[DIAG]   has_collision(): %s" % start_chunk.has_collision())
				print("[DIAG]   has_physics_body(): %s" % start_chunk.has_physics_body())

			# 10프레임마다 재시도
			start_chunk.create_collision_robust()
			await get_tree().process_frame

		if collision_wait_frames >= MAX_WAIT_FRAMES:
			if log_diag:
				print("[DIAG] WARNING: Physics body timeout! Emergency creation...")
			# 최후의 수단: 직접 생성
			_emergency_create_collision(start_chunk)
			await get_tree().physics_frame
			await get_tree().physics_frame
			break

	if log_diag:
		print("[DIAG] Physics body ready after %d collision-wait frames" % collision_wait_frames)
		print("[DIAG] Final has_physics_body(): %s" % start_chunk.has_physics_body())

	# 5. 물리 엔진에 등록될 시간 확보
	for i in range(3):
		await get_tree().physics_frame

	return total_wait_frames


## 긴급 충돌체 생성 (최후의 수단)
func _emergency_create_collision(chunk: VoxelChunk) -> void:
	if log_diag:
		print("[DIAG] _emergency_create_collision called")

	# MeshInstance3D 찾기
	var mi: MeshInstance3D = null
	for child in chunk.get_children():
		if child is MeshInstance3D:
			mi = child
			break

	if mi == null or mi.mesh == null:
		if log_diag:
			print("[DIAG] Emergency: No MeshInstance3D!")
		return

	# 기존 충돌 노드 제거
	for child in mi.get_children():
		if child is StaticBody3D or child.name.contains("col"):
			child.queue_free()

	# 강제로 충돌체 생성
	mi.create_trimesh_collision()
	if log_diag:
		print("[DIAG] Emergency collision created")


## Critical Fix: RayCast 검증 (실패 시 최대 10프레임 재시도)
func _verify_floor_with_raycast_retry() -> bool:
	const MAX_RETRIES: int = 10

	for attempt in range(MAX_RETRIES):
		var result: bool = _verify_floor_with_raycast()

		if result:
			if log_diag:
				print("[DIAG] RayCast SUCCESS on attempt %d" % (attempt + 1))
			return true

		if log_diag:
			print("[DIAG] RayCast attempt %d failed, waiting..." % (attempt + 1))
		await get_tree().physics_frame

	if log_diag:
		print("[DIAG] RayCast FAILED after %d attempts" % MAX_RETRIES)
	return false


## Phase 2-8 Diagnostic: RayCast로 실제 물리 바닥 검증
func _verify_floor_with_raycast() -> bool:
	if not player:
		if log_diag:
			print("[DIAG] RayCast verification skipped: No player")
		return false

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if not space_state:
		if log_diag:
			print("[DIAG] RayCast verification skipped: No space state")
		return false

	# 플레이어 위치에서 아래로 레이캐스트
	var ray_start: Vector3 = player.global_position + Vector3.UP * 0.5
	var ray_end: Vector3 = player.global_position + Vector3.DOWN * 10.0

	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.exclude = [player.get_rid()]

	var result: Dictionary = space_state.intersect_ray(query)

	if result:
		if log_diag:
			print("[DIAG] RayCast Floor Detected: TRUE at %s" % result.position)
			print("[DIAG] RayCast Hit Collider: %s" % result.collider)
			print("[DIAG] RayCast Distance from player: %.2f" % (player.global_position.y - result.position.y))
		return true
	else:
		if log_diag:
			print("[DIAG] RayCast Floor Detected: FALSE (NO COLLISION FOUND!)")
			print("[DIAG] RayCast was from %s to %s" % [ray_start, ray_end])

			# 추가 진단: 해당 위치의 청크 상태 확인
			var player_chunk_pos: Vector2i = Global.world_to_chunk(player.global_position)
			print("[DIAG] Player is in chunk: %s" % player_chunk_pos)

			if active_chunks.has(player_chunk_pos):
				var chunk: VoxelChunk = active_chunks[player_chunk_pos]
				print("[DIAG] That chunk has_collision: %s" % chunk.has_collision())
				print("[DIAG] That chunk has_physics_body: %s" % chunk.has_physics_body())
				print("[DIAG] That chunk is_thread_running: %s" % chunk.is_thread_running())

				# 해당 청크의 자식 노드 목록 출력
				print("[DIAG] Chunk children: %s" % chunk.get_children())

				# MeshInstance3D의 자식도 확인
				for child in chunk.get_children():
					if child is MeshInstance3D:
						print("[DIAG] MeshInstance3D children: %s" % child.get_children())
			else:
				print("[DIAG] WARNING: Player's chunk does not exist in active_chunks!")

		return false


## Phase 2-8 Hotfix: 플레이어를 지면에 강제 스냅
func _snap_player_to_ground() -> void:
	# 스폰 위치 (청크 0,0의 중앙)
	var spawn_x: float = float(VoxelChunk.CHUNK_SIZE) / 2.0
	var spawn_z: float = float(VoxelChunk.CHUNK_SIZE) / 2.0

	# 수학적 지형 높이 계산 (노이즈 역산)
	var ground_height: float = get_terrain_height(spawn_x, spawn_z)

	# 플레이어를 지면 위로 텔레포트 (+3.0 여유)
	player.global_position = Vector3(spawn_x, ground_height + 3.0, spawn_z)

	# 속도 초기화 (낙하 가속 제거)
	player.velocity = Vector3.ZERO

	# 바닥 착지 상태 갱신
	player.move_and_slide()

	print("[WorldGenerator] Player snapped to ground at height: %.1f" % ground_height)


## 노이즈 기반 지형 높이 계산 (VoxelChunk와 동일한 공식)
func get_terrain_height(world_x: float, world_z: float) -> float:
	if noise_base == null or noise_mountain == null:
		return 20.0  # 기본값

	var h1: float = noise_base.get_noise_2d(world_x, world_z)
	var h2: float = noise_mountain.get_noise_2d(world_x, world_z)

	# VoxelChunk._generate_voxel_data()와 동일한 공식
	var height: float = (h1 * 20.0 + 20.0) + (h2 * 4.0)
	height = clampf(height, 1.0, float(VoxelChunk.CHUNK_HEIGHT - 1))

	return height


## 초기 로딩 중인지 확인
func is_initial_loading() -> bool:
	return _is_initial_loading


# ================================
# Global Voxel Lookup
# ================================

## 글로벌 좌표에서 블록이 솔리드인지 확인
func is_block_solid_global(global_pos: Vector3i) -> bool:
	var chunk_pos := Vector2i(
		floori(float(global_pos.x) / VoxelChunk.CHUNK_SIZE),
		floori(float(global_pos.z) / VoxelChunk.CHUNK_SIZE)
	)

	if not active_chunks.has(chunk_pos):
		return false

	var local_x: int = global_pos.x - (chunk_pos.x * VoxelChunk.CHUNK_SIZE)
	var local_z: int = global_pos.z - (chunk_pos.y * VoxelChunk.CHUNK_SIZE)
	var local_pos := Vector3i(local_x, global_pos.y, local_z)

	var chunk: VoxelChunk = active_chunks[chunk_pos]
	return chunk.has_voxel(local_pos)


## 청크 좌표와 로컬 좌표를 글로벌 좌표로 변환
static func to_global_pos(chunk_pos: Vector2i, local_pos: Vector3i) -> Vector3i:
	return Vector3i(
		chunk_pos.x * VoxelChunk.CHUNK_SIZE + local_pos.x,
		local_pos.y,
		chunk_pos.y * VoxelChunk.CHUNK_SIZE + local_pos.z
	)


# ================================
# Player Tracking
# ================================

func _update_player_chunk() -> void:
	var current_chunk: Vector2i = Global.world_to_chunk(player.global_position)

	if current_chunk == last_player_chunk:
		return

	last_player_chunk = current_chunk
	_calculate_chunks_to_load(current_chunk)
	_calculate_chunks_to_unload(current_chunk)


func _calculate_chunks_to_load(center: Vector2i) -> void:
	var render_dist: int = Global.RENDER_DISTANCE

	for x in range(center.x - render_dist, center.x + render_dist + 1):
		for z in range(center.y - render_dist, center.y + render_dist + 1):
			var chunk_pos := Vector2i(x, z)
			var dist: float = Vector2(center - chunk_pos).length()

			if dist > render_dist:
				continue
			if active_chunks.has(chunk_pos):
				continue
			if chunk_pos in chunk_load_queue:
				continue

			_insert_to_load_queue(chunk_pos, dist)


func _insert_to_load_queue(chunk_pos: Vector2i, distance: float) -> void:
	var insert_idx: int = 0
	for i in range(chunk_load_queue.size()):
		var existing_pos: Vector2i = chunk_load_queue[i]
		var existing_dist: float = Vector2(last_player_chunk - existing_pos).length()
		if distance < existing_dist:
			break
		insert_idx = i + 1

	chunk_load_queue.insert(insert_idx, chunk_pos)


func _calculate_chunks_to_unload(center: Vector2i) -> void:
	var render_dist: int = Global.RENDER_DISTANCE
	var unload_dist: float = render_dist + 1.5

	for chunk_pos in active_chunks.keys():
		var dist: float = Vector2(center - chunk_pos).length()
		if dist > unload_dist:
			if chunk_pos not in chunk_unload_queue:
				chunk_unload_queue.append(chunk_pos)


# ================================
# Queue Processing
# ================================

## 현재 최대 동시 실행 작업 수 반환
## 초기 로딩 시 CPU 코어 최대 활용, 이후에는 배경 작업 제한
func _get_current_max_tasks() -> int:
	if _is_initial_loading:
		return maxi(1, OS.get_processor_count() - 1)
	return MAX_CONCURRENT_BACKGROUND_TASKS


func _process_load_queue() -> void:
	var max_tasks: int = _get_current_max_tasks()

	# ★ 스레드 풀 포화 시 생성 중단 (여유 스레드 확보)
	if _current_background_tasks >= max_tasks:
		return

	while chunk_load_queue.size() > 0 and chunks_generated_this_frame < Global.CHUNKS_PER_FRAME:
		# ★ 루프 내에서도 체크 (한 프레임에 여러 개 생성 시)
		if _current_background_tasks >= max_tasks:
			break
		
		var chunk_pos: Vector2i = chunk_load_queue.pop_front()

		if active_chunks.has(chunk_pos):
			continue

		var dist: float = Vector2(last_player_chunk - chunk_pos).length()
		if dist > Global.RENDER_DISTANCE:
			continue

		_create_chunk(chunk_pos)
		chunks_generated_this_frame += 1

		if not _is_initial_loading:
			_queue_neighbor_mesh_updates(chunk_pos)


func _process_unload_queue() -> void:
	var max_unloads: int = 4
	var unloaded: int = 0

	while chunk_unload_queue.size() > 0 and unloaded < max_unloads:
		var chunk_pos: Vector2i = chunk_unload_queue.pop_front()

		var dist: float = Vector2(last_player_chunk - chunk_pos).length()
		if dist <= Global.RENDER_DISTANCE:
			continue

		# 삭제 전에 메쉬 큐에서 제거
		_remove_from_mesh_queue(chunk_pos)

		_remove_chunk(chunk_pos)
		unloaded += 1

		# 인접 청크 메쉬 업데이트 요청
		_queue_neighbor_mesh_updates(chunk_pos)


# ================================
# Chunk Management
# ================================

func _create_chunk(chunk_pos: Vector2i) -> void:
	if active_chunks.has(chunk_pos):
		return

	# 1. 캐시에서 복원 시도
	if _chunk_cache.has(chunk_pos):
		var chunk: VoxelChunk = _chunk_cache[chunk_pos]
		_chunk_cache.erase(chunk_pos)
		active_chunks[chunk_pos] = chunk
		chunk.visible = true

		var dist: float = Vector2(last_player_chunk - chunk_pos).length()
		if dist <= Global.PHYSICS_DISTANCE:
			chunk.enable_collision()
		return

	# 2. Phase 5: 저장 파일 확인
	if SaveManager.has_saved_chunk(chunk_pos):
		_load_chunk_from_file(chunk_pos)
		return

	# 3. 노이즈 생성 (기존 로직)
	_generate_new_chunk(chunk_pos)


## Phase 5: 파일에서 청크 로드
func _load_chunk_from_file(chunk_pos: Vector2i) -> void:
	var voxel_data := SaveManager.load_chunk_sync(chunk_pos)
	if voxel_data.is_empty():
		# 파일 손상 시 노이즈 재생성
		if log_perf:
			print("[LOAD_FILE] Chunk %s file corrupted, regenerating" % chunk_pos)
		_generate_new_chunk(chunk_pos)
		return

	var chunk := VoxelChunk.new()
	add_child(chunk)

	chunk.chunk_position = chunk_pos
	chunk.position = Vector3(chunk_pos.x * VoxelChunk.CHUNK_SIZE, 0, chunk_pos.y * VoxelChunk.CHUNK_SIZE)
	chunk.set_voxel_data_from_file(voxel_data)

	# 배경 작업 카운트
	_current_background_tasks += 1
	if not chunk.mesh_thread_completed.is_connected(_on_background_task_completed):
		chunk.mesh_thread_completed.connect(_on_background_task_completed, CONNECT_ONE_SHOT)

	# 메쉬 빌드 (스레드)
	var needs_collision := _is_physics_distance(chunk_pos)
	chunk.start_threaded_mesh_update(needs_collision)

	active_chunks[chunk_pos] = chunk

	if log_perf:
		print("[LOAD_FILE] Chunk %s loaded from file" % chunk_pos)


## 노이즈 기반 새 청크 생성
func _generate_new_chunk(chunk_pos: Vector2i) -> void:
	var chunk := VoxelChunk.new()
	add_child(chunk)

	var needs_collision := _is_physics_distance(chunk_pos)

	_current_background_tasks += 1
	if not chunk.mesh_thread_completed.is_connected(_on_background_task_completed):
		chunk.mesh_thread_completed.connect(_on_background_task_completed, CONNECT_ONE_SHOT)

	chunk.generate_chunk_threaded(chunk_pos, noise_base, noise_mountain, needs_collision)
	active_chunks[chunk_pos] = chunk


## 물리 거리 내 확인 헬퍼
func _is_physics_distance(chunk_pos: Vector2i) -> bool:
	if player == null:
		return true  # 초기 로딩 시 안전하게 true
	var player_chunk := Global.world_to_chunk(player.global_position)
	var dist := Vector2(player_chunk - chunk_pos).length()
	return dist <= Global.PHYSICS_DISTANCE


func _remove_chunk(chunk_pos: Vector2i) -> void:
	if not active_chunks.has(chunk_pos):
		return

	var chunk: VoxelChunk = active_chunks[chunk_pos]

	# Phase 5: Dirty 청크는 저장
	if chunk.is_dirty():
		SaveManager.save_chunk_async(chunk_pos, chunk.get_voxel_data())
		chunk.mark_clean()
		if log_perf:
			print("[SAVE] Chunk %s queued for save (dirty)" % chunk_pos)

	active_chunks.erase(chunk_pos)

	# 스레드 돌아가는 중이거나 캐시 여유 있으면 캐시로
	if chunk.is_thread_running() or _chunk_cache.size() < MAX_CACHED_CHUNKS:
		_chunk_cache[chunk_pos] = chunk
		chunk.visible = false
		chunk.disable_collision()
	else:
		chunk.queue_free()


## ★ 인접 청크 메쉬 업데이트 요청 (큐 시스템)
func _queue_neighbor_mesh_updates(center_chunk: Vector2i) -> void:
	for offset in NEIGHBOR_OFFSETS:
		var neighbor_pos: Vector2i = center_chunk + offset

		if active_chunks.has(neighbor_pos):
			var neighbor: VoxelChunk = active_chunks[neighbor_pos]
			request_mesh_update(neighbor)


## 청크가 삭제될 때 메쉬 큐에서 제거
func _remove_from_mesh_queue(chunk_pos: Vector2i) -> void:
	if not active_chunks.has(chunk_pos):
		return

	var chunk: VoxelChunk = active_chunks[chunk_pos]
	var idx: int = _mesh_update_queue.find(chunk)
	if idx >= 0:
		_mesh_update_queue.remove_at(idx)


# ================================
# Utility
# ================================

func get_spawn_position() -> Vector3:
	var spawn_chunk := Vector2i(0, 0)
	if not active_chunks.has(spawn_chunk):
		_create_chunk(spawn_chunk)

	var center_x: int = VoxelChunk.CHUNK_SIZE / 2
	var center_z: int = VoxelChunk.CHUNK_SIZE / 2

	if active_chunks.has(spawn_chunk):
		var chunk: VoxelChunk = active_chunks[spawn_chunk]
		for y in range(VoxelChunk.CHUNK_HEIGHT - 1, -1, -1):
			if chunk.has_voxel(Vector3i(center_x, y, center_z)):
				return Vector3(center_x, y + 2, center_z)

	return Vector3(center_x, 50, center_z)


func get_active_chunk_count() -> int:
	return active_chunks.size()


func get_queue_sizes() -> Dictionary:
	return {
		"load": chunk_load_queue.size(),
		"unload": chunk_unload_queue.size(),
		"mesh_update": _mesh_update_queue.size(),
		"mesh_updating": _is_mesh_updating,
		"chunk_apply": _chunk_apply_queue.size(),
		"collision_request": _collision_request_queue.size(),
		"initial_loading": _is_initial_loading,
		"initial_progress": [_initial_chunks_finalized, _initial_chunks_to_load],
		"physics_bubble_center": _physics_bubble_center
	}


## Phase 2-9: 현재 물리 버블 상태 반환
func get_physics_bubble_info() -> Dictionary:
	var chunks_with_physics: int = 0
	var chunks_without_physics: int = 0

	for chunk in active_chunks.values():
		if chunk.has_physics_body():
			chunks_with_physics += 1
		else:
			chunks_without_physics += 1

	return {
		"center": _physics_bubble_center,
		"radius": Global.PHYSICS_DISTANCE,
		"with_physics": chunks_with_physics,
		"without_physics": chunks_without_physics
	}


## Phase 2-6: 충돌체 통계 반환
func get_collision_stats() -> Dictionary:
	var with_collision: int = 0
	var without_collision: int = 0

	for chunk in active_chunks.values():
		if chunk.has_collision():
			with_collision += 1
		else:
			without_collision += 1

	return {
		"with_collision": with_collision,
		"without_collision": without_collision,
		"total": active_chunks.size()
	}


## 캐시 정리: 스레드 완료된 청크 중 초과분 삭제
func _cleanup_chunk_cache() -> void:
	if _chunk_cache.size() <= MAX_CACHED_CHUNKS:
		return
	
	var to_remove: Array[Vector2i] = []
	for pos in _chunk_cache.keys():
		var chunk: VoxelChunk = _chunk_cache[pos]
		if not chunk.is_thread_running():
			to_remove.append(pos)
			if _chunk_cache.size() - to_remove.size() <= MAX_CACHED_CHUNKS:
				break
	
	for pos in to_remove:
		var chunk: VoxelChunk = _chunk_cache[pos]
		_chunk_cache.erase(pos)
		chunk.queue_free()

# ================================
# Block Modification
# ================================
func place_block(global_pos: Vector3i, block_type: int = 1) -> void:
	var t0 := Time.get_ticks_usec()  # 추가
	
	var chunk_pos := Vector2i(
		floori(float(global_pos.x) / VoxelChunk.CHUNK_SIZE),
		floori(float(global_pos.z) / VoxelChunk.CHUNK_SIZE)
	)
	
	if not active_chunks.has(chunk_pos):
		return
	
	var chunk: VoxelChunk = active_chunks[chunk_pos]
	var local_pos := _global_to_local(global_pos, chunk_pos)

	chunk.set_voxel(local_pos, block_type)
	var t1 := Time.get_ticks_usec()

	_refresh_chunk_and_neighbors(chunk_pos, local_pos)
	var t2 := Time.get_ticks_usec()  # 추가
	
	# 추가: 타이밍 로그
	print("[PLACE] setup: %d µs, refresh: %d µs, total: %d µs" % [t1 - t0, t2 - t1, t2 - t0])

func break_block(global_pos: Vector3i) -> void:
	var t0 := Time.get_ticks_usec()  # 추가
	
	var chunk_pos := Vector2i(
		floori(float(global_pos.x) / VoxelChunk.CHUNK_SIZE),
		floori(float(global_pos.z) / VoxelChunk.CHUNK_SIZE)
	)
	
	if not active_chunks.has(chunk_pos):
		if log_debug:
			print("[BLOCK] Chunk %s not in active_chunks" % chunk_pos)
		return
	
	var chunk: VoxelChunk = active_chunks[chunk_pos]
	var local_pos := _global_to_local(global_pos, chunk_pos)
	
	# 디버그: 스레드 상태 확인
	if log_debug:
		print("[BLOCK] Breaking at global: %s" % global_pos)
		print("[BLOCK] Chunk %s thread_running: %s" % [chunk_pos, chunk.is_thread_running()])

	if not chunk.has_voxel(local_pos):
		if log_debug:
			print("[BLOCK] Already empty at %s" % local_pos)
		return

	chunk.erase_voxel(local_pos)
	var t1 := Time.get_ticks_usec()
	
	if log_debug:
		print("[BLOCK] Refreshing chunk %s, local: %s" % [chunk_pos, local_pos])
	
	_refresh_chunk_and_neighbors(chunk_pos, local_pos)
	var t2 := Time.get_ticks_usec()  # 추가
	
	# 추가: 타이밍 로그
	print("[BREAK] setup: %d µs, refresh: %d µs, total: %d µs" % [t1 - t0, t2 - t1, t2 - t0])

func _global_to_local(global_pos: Vector3i, chunk_pos: Vector2i) -> Vector3i:
	return Vector3i(
		global_pos.x - chunk_pos.x * VoxelChunk.CHUNK_SIZE,
		global_pos.y,
		global_pos.z - chunk_pos.y * VoxelChunk.CHUNK_SIZE
	)


func _refresh_chunk_and_neighbors(chunk_pos: Vector2i, local_pos: Vector3i) -> void:
	if log_debug:
		print("[BLOCK] Refreshing chunk %s, local: %s" % [chunk_pos, local_pos])
	
	var chunk: VoxelChunk = active_chunks[chunk_pos]
	chunk.start_threaded_mesh_update(chunk.has_physics_body(), true)  # ★ priority=true
	
	# 경계 블록이면 인접 청크도 갱신 (이웃은 일반 우선순위)
	if local_pos.x == 0:
		_refresh_neighbor(chunk_pos + Vector2i(-1, 0))
	if local_pos.x == VoxelChunk.CHUNK_SIZE - 1:
		_refresh_neighbor(chunk_pos + Vector2i(1, 0))
	if local_pos.z == 0:
		_refresh_neighbor(chunk_pos + Vector2i(0, -1))
	if local_pos.z == VoxelChunk.CHUNK_SIZE - 1:
		_refresh_neighbor(chunk_pos + Vector2i(0, 1))


func _refresh_neighbor(neighbor_pos: Vector2i) -> void:
	if active_chunks.has(neighbor_pos):
		var neighbor: VoxelChunk = active_chunks[neighbor_pos]
		neighbor.start_threaded_mesh_update(neighbor.has_physics_body())

## Thread-safe 글로벌 좌표 블록 확인
func is_block_solid_threadsafe(global_pos: Vector3i) -> bool:
	var chunk_pos := Vector2i(
		floori(float(global_pos.x) / VoxelChunk.CHUNK_SIZE),
		floori(float(global_pos.z) / VoxelChunk.CHUNK_SIZE)
	)
	
	if not active_chunks.has(chunk_pos):
		return false
	
	var local_x: int = global_pos.x - (chunk_pos.x * VoxelChunk.CHUNK_SIZE)
	var local_z: int = global_pos.z - (chunk_pos.y * VoxelChunk.CHUNK_SIZE)
	var local_pos := Vector3i(local_x, global_pos.y, local_z)
	
	var chunk: VoxelChunk = active_chunks[chunk_pos]
	return chunk.has_voxel_threadsafe(local_pos)

func request_priority_chunk_apply(chunk: VoxelChunk) -> void:
	if chunk not in _priority_apply_queue:
		_priority_apply_queue.append(chunk)
