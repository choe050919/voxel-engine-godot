extends Node
## SaveManager.gd - 청크 영속성 관리 시스템
## Phase 5-1: ZSTD 압축 기반 비동기 I/O

# ============================================
# Signals
# ============================================
signal world_created(world_id: String)
signal world_loaded(world_id: String)
signal chunk_saved(chunk_pos: Vector2i)
signal chunk_loaded(chunk_pos: Vector2i)
signal save_error(message: String)
signal all_chunks_saved

# ============================================
# Constants
# ============================================
const SAVE_BASE_DIR := "user://saves/"
const CHUNK_SUBDIR := "chunks/"
const CHUNK_EXTENSION := ".chunk"
const WORLD_META_FILE := "world.json"
const PLAYER_DATA_FILE := "player.json"

# Chunk File Format
const CHUNK_MAGIC: PackedByteArray = [0x4E, 0x4F, 0x4D, 0x44]  # "NOMD"
const CHUNK_VERSION: int = 1
const HEADER_SIZE: int = 16

# Auto Save
const AUTO_SAVE_INTERVAL: float = 300.0  # 5분

# ============================================
# State
# ============================================
var current_world_id: String = ""
var _auto_save_timer: float = 0.0
var _pending_saves: int = 0  # 진행 중인 비동기 저장 수

# ============================================
# Initialization
# ============================================
func _ready() -> void:
	# 저장 디렉토리 생성
	if not DirAccess.dir_exists_absolute(SAVE_BASE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_BASE_DIR)
	print("[SaveManager] Initialized. Save dir: %s" % SAVE_BASE_DIR)


func _process(delta: float) -> void:
	if current_world_id.is_empty():
		return

	# 자동 저장 타이머
	_auto_save_timer += delta
	if _auto_save_timer >= AUTO_SAVE_INTERVAL:
		_auto_save_timer = 0.0
		_trigger_auto_save()


# ============================================
# World Management
# ============================================

## 새 월드 생성
func create_world(world_name: String, seed: int = -1) -> String:
	if seed == -1:
		seed = randi()

	# world_{timestamp} 형식 ID
	var world_id := "world_%d" % Time.get_unix_time_from_system()
	var world_dir := SAVE_BASE_DIR + world_id + "/"
	var chunks_dir := world_dir + CHUNK_SUBDIR

	# 디렉토리 생성
	DirAccess.make_dir_recursive_absolute(chunks_dir)

	# 메타데이터 저장 (플레이어 초기 위치 포함)
	var meta := {
		"id": world_id,
		"name": world_name,
		"seed": seed,
		"created_at": Time.get_datetime_string_from_system(),
		"last_played": Time.get_datetime_string_from_system(),
		"playtime_seconds": 0,
		"version": CHUNK_VERSION,
		"player_data": {
			"position": {"x": 8.0, "y": 50.0, "z": 8.0},  # 기본 스폰 위치
			"rotation_y": 0.0,  # 플레이어 몸체 회전
			"head_rotation_x": 0.0  # 카메라 상하 회전
		}
	}
	_save_json(world_dir + WORLD_META_FILE, meta)

	print("[SaveManager] World created: %s (seed: %d)" % [world_id, seed])
	world_created.emit(world_id)
	return world_id


## 월드 목록 조회
func get_world_list() -> Array[Dictionary]:
	var worlds: Array[Dictionary] = []

	var dir := DirAccess.open(SAVE_BASE_DIR)
	if dir == null:
		return worlds

	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and folder_name.begins_with("world_"):
			var meta := load_world_meta(folder_name)
			if not meta.is_empty():
				worlds.append(meta)
		folder_name = dir.get_next()
	dir.list_dir_end()

	# 최근 플레이 순 정렬
	worlds.sort_custom(func(a, b): return a.last_played > b.last_played)
	return worlds


## 월드 메타데이터 로드
func load_world_meta(world_id: String) -> Dictionary:
	var path := SAVE_BASE_DIR + world_id + "/" + WORLD_META_FILE
	return _load_json(path)


## 월드 삭제
func delete_world(world_id: String) -> bool:
	var world_dir := SAVE_BASE_DIR + world_id
	if not DirAccess.dir_exists_absolute(world_dir):
		return false

	# 재귀 삭제
	var success := _delete_directory_recursive(world_dir)
	if success:
		print("[SaveManager] World deleted: %s" % world_id)
	return success


## 현재 월드 설정 (게임 시작 시 호출)
func set_current_world(world_id: String) -> bool:
	var meta := load_world_meta(world_id)
	if meta.is_empty():
		push_error("[SaveManager] World not found: %s" % world_id)
		return false

	current_world_id = world_id
	_auto_save_timer = 0.0

	# last_played 업데이트
	meta.last_played = Time.get_datetime_string_from_system()
	_save_json(_get_world_dir() + WORLD_META_FILE, meta)

	print("[SaveManager] World loaded: %s" % world_id)
	world_loaded.emit(world_id)
	return true


## 현재 월드의 시드 반환
func get_current_seed() -> int:
	var meta := load_world_meta(current_world_id)
	return meta.get("seed", 0)


# ============================================
# Chunk I/O - Core
# ============================================

## 저장된 청크 존재 여부 확인
func has_saved_chunk(chunk_pos: Vector2i) -> bool:
	if current_world_id.is_empty():
		return false
	var path := _get_chunk_path(chunk_pos)
	return FileAccess.file_exists(path)


## 청크 저장 (비동기) - Dirty 청크만 호출됨
func save_chunk_async(chunk_pos: Vector2i, voxel_data: PackedInt32Array) -> void:
	if current_world_id.is_empty():
		push_error("[SaveManager] No world loaded")
		return

	_pending_saves += 1

	# 메모리 경고
	if _pending_saves > 100:
		push_warning("[SaveManager] High pending saves count: %d" % _pending_saves)

	# WorkerThreadPool에서 실행
	WorkerThreadPool.add_task(
		_thread_save_chunk.bind(chunk_pos, voxel_data.duplicate())
	)


## [Worker Thread] 청크 저장 실행
func _thread_save_chunk(chunk_pos: Vector2i, voxel_data: PackedInt32Array) -> void:
	var path := _get_chunk_path(chunk_pos)
	var success := _write_chunk_file(path, voxel_data)

	# Main Thread로 완료 콜백
	call_deferred("_on_chunk_saved", chunk_pos, success)


## 청크 저장 완료 콜백
func _on_chunk_saved(chunk_pos: Vector2i, success: bool) -> void:
	_pending_saves -= 1

	if success:
		chunk_saved.emit(chunk_pos)
	else:
		save_error.emit("Failed to save chunk %s" % chunk_pos)

	if _pending_saves == 0:
		all_chunks_saved.emit()


## 청크 로드 (동기) - 게임 로딩 시 사용
func load_chunk_sync(chunk_pos: Vector2i) -> PackedInt32Array:
	if current_world_id.is_empty():
		return PackedInt32Array()

	var path := _get_chunk_path(chunk_pos)
	if not FileAccess.file_exists(path):
		return PackedInt32Array()

	var data := _read_chunk_file(path)
	if data.size() > 0:
		chunk_loaded.emit(chunk_pos)
	return data


## 청크 로드 (비동기) - 스트리밍 시 사용
func load_chunk_async(chunk_pos: Vector2i, callback: Callable) -> void:
	if current_world_id.is_empty():
		callback.call(PackedInt32Array())
		return

	WorkerThreadPool.add_task(
		_thread_load_chunk.bind(chunk_pos, callback)
	)


## [Worker Thread] 청크 로드 실행
func _thread_load_chunk(chunk_pos: Vector2i, callback: Callable) -> void:
	var path := _get_chunk_path(chunk_pos)
	var data := _read_chunk_file(path)

	# Main Thread로 콜백
	call_deferred("_on_chunk_loaded", chunk_pos, data, callback)


## 청크 로드 완료 콜백
func _on_chunk_loaded(chunk_pos: Vector2i, data: PackedInt32Array, callback: Callable) -> void:
	if data.size() > 0:
		chunk_loaded.emit(chunk_pos)
	callback.call(data)


# ============================================
# Chunk File Format (ZSTD 압축)
# ============================================

## 청크 파일 쓰기
func _write_chunk_file(path: String, voxel_data: PackedInt32Array) -> bool:
	# 1. PackedInt32Array -> PackedByteArray
	var raw_bytes := voxel_data.to_byte_array()

	# 2. ZSTD 압축
	var compressed := raw_bytes.compress(FileAccess.COMPRESSION_ZSTD)

	# 3. CRC32 계산
	var checksum := _crc32(compressed)

	# 4. 파일 쓰기
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] Failed to open file for writing: %s" % path)
		return false

	# Header (16 bytes)
	file.store_buffer(CHUNK_MAGIC)           # 4 bytes: "NOMD"
	file.store_16(CHUNK_VERSION)             # 2 bytes: version
	file.store_16(0)                         # 2 bytes: flags (reserved)
	file.store_32(checksum)                  # 4 bytes: CRC32
	file.store_32(raw_bytes.size())          # 4 bytes: 원본 크기 (검증용)

	# Payload
	file.store_buffer(compressed)

	file.close()
	return true


## 청크 파일 읽기
func _read_chunk_file(path: String) -> PackedInt32Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedInt32Array()

	# Header 읽기
	var magic := file.get_buffer(4)
	if magic != CHUNK_MAGIC:
		push_error("[SaveManager] Invalid chunk magic: %s" % path)
		file.close()
		return PackedInt32Array()

	var version := file.get_16()
	var _flags := file.get_16()
	var stored_checksum := file.get_32()
	var original_size := file.get_32()

	# Version 체크
	if version > CHUNK_VERSION:
		push_error("[SaveManager] Unsupported chunk version %d: %s" % [version, path])
		file.close()
		return PackedInt32Array()

	# Payload 읽기
	var compressed := file.get_buffer(file.get_length() - HEADER_SIZE)
	file.close()

	# CRC32 검증
	var calculated_checksum := _crc32(compressed)
	if calculated_checksum != stored_checksum:
		push_error("[SaveManager] Checksum mismatch: %s" % path)
		return PackedInt32Array()

	# ZSTD 압축 해제
	var raw_bytes := compressed.decompress(original_size, FileAccess.COMPRESSION_ZSTD)
	if raw_bytes.size() != original_size:
		push_error("[SaveManager] Decompression size mismatch: %s" % path)
		return PackedInt32Array()

	# PackedByteArray -> PackedInt32Array
	var voxel_data := raw_bytes.to_int32_array()
	return voxel_data


## CRC32 계산 (간단 구현)
func _crc32(data: PackedByteArray) -> int:
	# Godot 내장 hash 사용 (완벽한 CRC32는 아니지만 충분)
	return hash(data)


# ============================================
# Player Data
# ============================================

## 플레이어 상태 저장 (별도 파일)
func save_player(player_data: Dictionary) -> void:
	if current_world_id.is_empty():
		return
	_save_json(_get_world_dir() + PLAYER_DATA_FILE, player_data)


## 플레이어 상태 로드 (별도 파일)
func load_player() -> Dictionary:
	if current_world_id.is_empty():
		return {}
	return _load_json(_get_world_dir() + PLAYER_DATA_FILE)


## Phase 5-3: 플레이어 위치를 world.json에 저장
func save_player_to_world_meta(pos: Vector3, rotation_y: float, head_rotation_x: float) -> void:
	if current_world_id.is_empty():
		return

	var meta := load_world_meta(current_world_id)
	if meta.is_empty():
		return

	meta["player_data"] = {
		"position": {"x": pos.x, "y": pos.y, "z": pos.z},
		"rotation_y": rotation_y,
		"head_rotation_x": head_rotation_x
	}
	meta["last_played"] = Time.get_datetime_string_from_system()

	_save_json(_get_world_dir() + WORLD_META_FILE, meta)
	print("[SaveManager] Player position saved: %s" % pos)


## Phase 5-3: world.json에서 플레이어 데이터 로드
func get_player_data_from_world_meta() -> Dictionary:
	if current_world_id.is_empty():
		return {}

	var meta := load_world_meta(current_world_id)
	if meta.is_empty():
		return {}

	if meta.has("player_data"):
		return meta["player_data"]

	# 기본값 반환
	return {
		"position": {"x": 8.0, "y": 50.0, "z": 8.0},
		"rotation_y": 0.0,
		"head_rotation_x": 0.0
	}


# ============================================
# Auto Save
# ============================================

func _trigger_auto_save() -> void:
	print("[SaveManager] Auto-save triggered")

	# WorldGenerator에게 Dirty 청크 저장 요청
	if WorldGenerator.instance:
		flush_dirty_chunks(WorldGenerator.instance.active_chunks)


## 모든 Dirty 청크 저장 (게임 종료/자동저장 시)
func flush_dirty_chunks(chunks: Dictionary) -> void:
	var saved_count := 0

	for chunk_pos in chunks.keys():
		var chunk: VoxelChunk = chunks[chunk_pos]
		if chunk.is_dirty():
			save_chunk_async(chunk_pos, chunk.get_voxel_data())
			chunk.mark_clean()
			saved_count += 1

	if saved_count > 0:
		print("[SaveManager] Flushing %d dirty chunks" % saved_count)


## 동기 저장 (게임 종료 시 - 모든 저장 완료 대기)
func flush_dirty_chunks_sync(chunks: Dictionary) -> void:
	var saved_count := 0
	for chunk_pos in chunks.keys():
		var chunk: VoxelChunk = chunks[chunk_pos]
		if chunk.is_dirty():
			var path := _get_chunk_path(chunk_pos)
			_write_chunk_file(path, chunk.get_voxel_data())
			chunk.mark_clean()
			saved_count += 1
	if saved_count > 0:
		print("[SaveManager] Sync flush completed: %d chunks" % saved_count)


# ============================================
# Utility
# ============================================

func _get_world_dir() -> String:
	return SAVE_BASE_DIR + current_world_id + "/"


func _get_chunk_path(chunk_pos: Vector2i) -> String:
	return _get_world_dir() + CHUNK_SUBDIR + "%d_%d%s" % [chunk_pos.x, chunk_pos.y, CHUNK_EXTENSION]


func _save_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) == OK:
		return json.data
	return {}


func _delete_directory_recursive(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		return false

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		var full_path := path + "/" + file_name
		if dir.current_is_dir():
			_delete_directory_recursive(full_path)
		else:
			dir.remove(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	return DirAccess.remove_absolute(path) == OK
