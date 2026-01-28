class_name VoxelChunk
extends StaticBody3D
## VoxelChunk.gd - Seamless Chunk Borders
## Cross-Chunk Face Culling + WorkerThreadPool 멀티스레딩

var _voxel_mutex: Mutex = Mutex.new()

var _pending_mesh_update: bool = false
var _pending_needs_collision: bool = false

const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 64
const VOXEL_DATA_SIZE: int = CHUNK_SIZE * CHUNK_HEIGHT * CHUNK_SIZE  # 16384

# 생성된 물리 바디 참조 저장
var _collision_rid: RID

# ================================
# Phase 3: PackedInt32Array 기반 복셀 데이터
# 인덱스: y + x * CHUNK_HEIGHT + z * CHUNK_HEIGHT * CHUNK_SIZE
# 값: 0 = 공기, 1+ = 블록 타입
# ================================
var _voxel_data: PackedInt32Array
var chunk_position: Vector2i

# ================================
# Phase 5: Persistence State
# ================================
var _is_dirty: bool = false              # 수정 여부 (저장 필요)
var _is_from_file: bool = false          # 파일에서 로드됨 (vs 노이즈 생성)


## 생성자: 배열 초기화 보장
func _init() -> void:
	_init_voxel_data()


## 인덱스 변환: (x, y, z) -> 1D 인덱스 (Y축 Stride=1 최적화)
func _voxel_idx(x: int, y: int, z: int) -> int:
	return y + x * CHUNK_HEIGHT + z * CHUNK_HEIGHT * CHUNK_SIZE


## 범위 체크
func _is_valid_local_pos(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < CHUNK_SIZE and y >= 0 and y < CHUNK_HEIGHT and z >= 0 and z < CHUNK_SIZE


## 복셀 데이터 초기화
func _init_voxel_data() -> void:
	_voxel_data.resize(VOXEL_DATA_SIZE)
	_voxel_data.fill(0)


# ================================
# Wrapper API (외부 접근용)
# ================================

## 복셀 존재 여부 확인
func has_voxel(local_pos: Vector3i) -> bool:
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		return false
	if not _is_valid_local_pos(local_pos.x, local_pos.y, local_pos.z):
		return false
	return _voxel_data[_voxel_idx(local_pos.x, local_pos.y, local_pos.z)] != 0


## 복셀 타입 조회 (없으면 0 반환)
func get_voxel(local_pos: Vector3i) -> int:
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		return 0
	if not _is_valid_local_pos(local_pos.x, local_pos.y, local_pos.z):
		return 0
	return _voxel_data[_voxel_idx(local_pos.x, local_pos.y, local_pos.z)]


## 복셀 설정 + Dirty 마킹
func set_voxel(local_pos: Vector3i, block_type: int) -> void:
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		return
	if not _is_valid_local_pos(local_pos.x, local_pos.y, local_pos.z):
		return
	var idx := _voxel_idx(local_pos.x, local_pos.y, local_pos.z)
	var old_value := _voxel_data[idx]
	if old_value != block_type:
		_voxel_data[idx] = block_type
		_is_dirty = true  # 변경 시에만 Dirty


## 복셀 삭제 + Dirty 마킹
func erase_voxel(local_pos: Vector3i) -> void:
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		return
	if not _is_valid_local_pos(local_pos.x, local_pos.y, local_pos.z):
		return
	var idx := _voxel_idx(local_pos.x, local_pos.y, local_pos.z)
	if _voxel_data[idx] != 0:
		_voxel_data[idx] = 0
		_is_dirty = true  # 변경 시에만 Dirty


# ================================
# Phase 5: Persistence API
# ================================

## Dirty 상태 확인
func is_dirty() -> bool:
	return _is_dirty


## 저장 완료 후 Clean 마킹
func mark_clean() -> void:
	_is_dirty = false


## 파일 로드 여부 확인
func is_from_file() -> bool:
	return _is_from_file


## 전체 복셀 데이터 반환 (저장용)
func get_voxel_data() -> PackedInt32Array:
	return _voxel_data


## 외부 데이터로 복셀 설정 (파일 로드용)
func set_voxel_data_from_file(data: PackedInt32Array) -> void:
	if data.size() != VOXEL_DATA_SIZE:
		push_error("[VoxelChunk] Invalid voxel data size: %d (expected %d)" % [data.size(), VOXEL_DATA_SIZE])
		return
	_voxel_data = data
	_is_from_file = true
	_is_dirty = false  # 로드 직후는 Clean


# 공유 머티리얼 (모든 청크가 동일한 머티리얼 사용)
static var _shared_material: StandardMaterial3D = null

static var _mesh_instance_pool: Array[MeshInstance3D] = []

# Phase 2-6: 충돌체 상태 - Self-Healing (변수 캐싱 제거됨)
# has_collision()은 항상 실제 노드 존재 여부를 확인

# ================================
# Phase 2-7: Thread State
# ================================
var _is_thread_running: bool = false              # 스레드 작업 진행 중
var _thread_voxel_data: PackedInt32Array          # 스레드용 복셀 데이터 복사본
var _thread_needs_collision: bool = false         # 완료 후 충돌체 생성 여부
var _is_priority_update: bool = false             # 우선순위 업데이트 여부

# ================================
# Phase 2-Optimization: Threaded Physics
# ================================
var _thread_mesh: ArrayMesh = null            # 스레드에서 생성된 메쉬
var _thread_shape: Shape3D = null             # 스레드에서 생성된 충돌체 쉐이프
var _cached_shape: Shape3D = null             # 캐싱된 충돌체 쉐이프 (재사용)

signal mesh_thread_completed  # 스레드 완료 시그널

# 6방향 벡터 (Godot 좌표계: Y-Up)
const DIRECTIONS = [
	Vector3i.UP,
	Vector3i.DOWN,
	Vector3i.LEFT,
	Vector3i.RIGHT,
	Vector3i.FORWARD,
	Vector3i.BACK
]

# 각 방향에 따른 4개 정점 (반시계 방향 CCW)
const FACE_VERTICES = {
	Vector3i.UP: [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)],
	Vector3i.DOWN: [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)],
	Vector3i.LEFT: [Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1)],
	Vector3i.RIGHT: [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
	Vector3i.FORWARD: [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)],
	Vector3i.BACK: [Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)]
}


func generate_chunk(pos: Vector2i, noise_base: FastNoiseLite, noise_mtn: FastNoiseLite) -> void:
	generate_chunk_with_options(pos, noise_base, noise_mtn, true)


## Phase 2-6: 충돌체 생성 여부를 선택할 수 있는 청크 생성 (동기식)
func generate_chunk_with_options(pos: Vector2i, noise_base: FastNoiseLite, noise_mtn: FastNoiseLite, with_collision: bool) -> void:
	chunk_position = pos
	position = Vector3(pos.x * CHUNK_SIZE, 0, pos.y * CHUNK_SIZE)

	_generate_voxel_data(noise_base, noise_mtn)

	# 메쉬 데이터 빌드 및 시각적 메쉬 적용
	var mesh: ArrayMesh = _build_mesh_data()
	_apply_visual_mesh(mesh)

	# 충돌체는 옵션에 따라 생성
	if with_collision:
		_create_collision()


## Phase 2-7: 스레드 기반 청크 생성 (복셀 데이터만 동기, 메쉬는 스레드)
func generate_chunk_threaded(pos: Vector2i, noise_base: FastNoiseLite, noise_mtn: FastNoiseLite, with_collision: bool) -> void:
	chunk_position = pos
	position = Vector3(pos.x * CHUNK_SIZE, 0, pos.y * CHUNK_SIZE)

	# 복셀 데이터 생성 (노이즈 계산 - 비교적 가벼움)
	_generate_voxel_data(noise_base, noise_mtn)

	# 메쉬 빌드를 스레드로 위임
	start_threaded_mesh_update(with_collision)


func _generate_voxel_data(n1: FastNoiseLite, n2: FastNoiseLite) -> void:
	_init_voxel_data()
	var global_x_start: int = chunk_position.x * CHUNK_SIZE
	var global_z_start: int = chunk_position.y * CHUNK_SIZE

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			var gx: int = global_x_start + x
			var gz: int = global_z_start + z

			var h1: float = n1.get_noise_2d(gx, gz)
			var h2: float = n2.get_noise_2d(gx, gz)
			var height: int = int((h1 * 20.0 + 20.0) + (h2 * 4.0))
			height = clampi(height, 1, CHUNK_HEIGHT - 1)

			# Y축 연속 메모리 접근 (캐시 친화적)
			var base_idx: int = x * CHUNK_HEIGHT + z * CHUNK_HEIGHT * CHUNK_SIZE
			for y in range(height + 1):
				_voxel_data[base_idx + y] = 1

	# Phase 5: 노이즈 생성 청크는 Dirty=false (저장 불필요)
	_is_from_file = false
	_is_dirty = false


# ================================
# Phase 2-7: Threaded Mesh Building
# ================================

## 스레드 작업 진행 중인지 확인
func is_thread_running() -> bool:
	return _is_thread_running


func start_threaded_mesh_update(with_collision: bool = false, priority: bool = false) -> void:
	if _is_thread_running:
		if WorldGenerator.instance and WorldGenerator.instance.log_collision:
			print("[PENDING] Chunk %s queuing pending update (was: %s, new collision: %s)" % [chunk_position, _pending_mesh_update, with_collision])
		_pending_mesh_update = true
		_pending_needs_collision = _pending_needs_collision or with_collision
		return

	var t0 := Time.get_ticks_usec()

	if WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[THREAD_START] Chunk %s, voxel_data size: %d, with_collision: %s" % [chunk_position, _voxel_data.size(), with_collision])

	# ★ 안전장치: _voxel_data가 비어있으면 초기화 후 복사
	_voxel_mutex.lock()
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		_voxel_data.resize(VOXEL_DATA_SIZE)
		_voxel_data.fill(0)
	_thread_voxel_data = _voxel_data.duplicate()
	_voxel_mutex.unlock()
	var t1 := Time.get_ticks_usec()

	_thread_needs_collision = with_collision
	_is_priority_update = priority

	_is_thread_running = true
	WorkerThreadPool.add_task(_thread_build_mesh_arrays)
	var t2 := Time.get_ticks_usec()

	var total := t2 - t0
	if total > 1000:
		print("[SLOW_START] Chunk %s: dup=%d, total=%d µs" % [chunk_position, t1 - t0, total])


## [Worker Thread] 메쉬 및 충돌체 빌드 - Greedy Meshing 적용
func _thread_build_mesh_arrays() -> void:
	if WorldGenerator.instance and WorldGenerator.instance.log_mesh:
		print("[THREAD] Chunk %s _thread_voxel_data.size() = %d" % [chunk_position, _thread_voxel_data.size()])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Greedy Meshing: 각 방향별로 면을 병합하여 생성
	for dir in DIRECTIONS:
		_greedy_mesh_direction_threadsafe(st, dir)

	st.index()
	st.generate_normals()

	# [핵심 변경] commit()으로 메쉬 객체 직접 생성 (Godot 4.x 스레드 안전)
	var mesh: ArrayMesh = st.commit()
	_thread_mesh = mesh

	if mesh:
		var face_count: int = mesh.get_faces().size() / 3
		if WorldGenerator.instance and WorldGenerator.instance.log_mesh:
			print("[MESH] Chunk %s: %d triangles" % [chunk_position, face_count])

	# [핵심 최적화] 무거운 충돌체 계산을 스레드에서 수행
	if mesh and mesh.get_surface_count() > 0:
		_thread_shape = mesh.create_trimesh_shape()
	else:
		_thread_shape = null

	# Main Thread로 완료 콜백 (call_deferred는 Thread-Safe)
	call_deferred("_on_thread_mesh_complete")


## [Greedy Meshing] 특정 방향의 모든 면을 병합하여 생성 (Thread-Safe 버전)
func _greedy_mesh_direction_threadsafe(st: SurfaceTool, dir: Vector3i) -> void:
	# ★ 방어 코드: 배열 크기 검증 (Out of bounds 크래시 방지)
	if _thread_voxel_data.size() != VOXEL_DATA_SIZE:
		return

	# 방향에 따른 축 설정
	# slice_axis: 슬라이스를 나누는 축 (면의 법선 방향)
	# u_axis, v_axis: 2D 평면의 두 축
	var slice_axis: int
	var u_axis: int
	var v_axis: int
	var slice_count: int
	var u_size: int
	var v_size: int

	if dir == Vector3i.UP or dir == Vector3i.DOWN:
		slice_axis = 1  # Y축으로 슬라이스
		u_axis = 0      # X
		v_axis = 2      # Z
		slice_count = CHUNK_HEIGHT
		u_size = CHUNK_SIZE
		v_size = CHUNK_SIZE
	elif dir == Vector3i.LEFT or dir == Vector3i.RIGHT:
		slice_axis = 0  # X축으로 슬라이스
		u_axis = 2      # Z
		v_axis = 1      # Y
		slice_count = CHUNK_SIZE
		u_size = CHUNK_SIZE
		v_size = CHUNK_HEIGHT
	else:  # FORWARD or BACK
		slice_axis = 2  # Z축으로 슬라이스
		u_axis = 0      # X
		v_axis = 1      # Y
		slice_count = CHUNK_SIZE
		u_size = CHUNK_SIZE
		v_size = CHUNK_HEIGHT

	# 각 슬라이스 처리
	for slice_idx in range(slice_count):
		# 2D 마스크 생성: 노출된 면 표시
		var mask: Array = []
		mask.resize(u_size)
		for u in range(u_size):
			mask[u] = []
			mask[u].resize(v_size)
			for v in range(v_size):
				mask[u][v] = false

		# 마스크 채우기: 해당 슬라이스의 노출된 면 찾기
		for u in range(u_size):
			for v in range(v_size):
				var pos := Vector3i.ZERO
				pos[slice_axis] = slice_idx
				pos[u_axis] = u
				pos[v_axis] = v

				# 인라인 인덱스 계산 (성능 최적화)
				var idx: int = pos.y + pos.x * CHUNK_HEIGHT + pos.z * CHUNK_HEIGHT * CHUNK_SIZE
				if _thread_voxel_data[idx] != 0:
					var neighbor: Vector3i = pos + dir
					if not _is_neighbor_solid_threadsafe(neighbor):
						mask[u][v] = true

		if chunk_position == Vector2i(0, 0) and slice_idx == 0:
			var exposed_count: int = 0
			for u in range(u_size):
				for v in range(v_size):
					if mask[u][v]:
						exposed_count += 1
			if WorldGenerator.instance and WorldGenerator.instance.log_debug:
				print("[DEBUG] Chunk (0,0) dir=%s slice=0 exposed: %d" % [dir, exposed_count])

		# Greedy 알고리즘으로 면 병합
		for v in range(v_size):
			var u: int = 0
			while u < u_size:
				if mask[u][v]:
					# 새 사각형 시작점 발견
					# 가로(u) 방향으로 확장
					var width: int = 1
					while u + width < u_size and mask[u + width][v]:
						width += 1

					# 세로(v) 방향으로 확장
					var height: int = 1
					var can_expand: bool = true
					while v + height < v_size and can_expand:
						for wu in range(width):
							if not mask[u + wu][v + height]:
								can_expand = false
								break
						if can_expand:
							height += 1

					# 시작 위치 계산
					var pos := Vector3i.ZERO
					pos[slice_axis] = slice_idx
					pos[u_axis] = u
					pos[v_axis] = v

					# 병합된 쿼드 생성
					_add_greedy_face(st, pos, dir, width, height, u_axis, v_axis)

					# 처리된 영역 마킹
					for wu in range(width):
						for wv in range(height):
							mask[u + wu][v + wv] = false

					u += width
				else:
					u += 1


## [Greedy Meshing] 병합된 면(width x height) 추가 - FACE_VERTICES 기반
## 원본 _add_face()의 정점 순서를 그대로 유지하며 width/height만큼 확장
func _add_greedy_face(st: SurfaceTool, pos: Vector3i, dir: Vector3i, width: int, height: int, u_axis: int, v_axis: int) -> void:
	var base_verts = FACE_VERTICES[dir]  # 원본 1x1 면의 4개 정점 (정확한 와인딩 순서)
	var normal := Vector3(dir)
	var color := Color(0.2, 0.8, 0.2) if dir == Vector3i.UP else Color(0.5, 0.35, 0.2)

	# 4개 정점 계산: FACE_VERTICES 기반으로 width/height 확장
	# FACE_VERTICES의 각 좌표는 0 또는 1이므로,
	# u_axis 방향으로 1인 좌표는 width로, v_axis 방향으로 1인 좌표는 height로 확장
	var verts: Array[Vector3] = []
	verts.resize(4)
	var uvs: Array[Vector2] = []
	uvs.resize(4)

	for i in range(4):
		var v: Vector3 = Vector3(pos) + base_verts[i]
		var uv := Vector2.ZERO

		# u축 방향: 원본 좌표가 1이면 (width - 1)만큼 추가 확장
		if base_verts[i][u_axis] == 1:
			v[u_axis] += (width - 1)
			uv.x = width
		# else: uv.x = 0 (기본값)

		# v축 방향: 원본 좌표가 1이면 (height - 1)만큼 추가 확장
		if base_verts[i][v_axis] == 1:
			v[v_axis] += (height - 1)
			uv.y = height
		# else: uv.y = 0 (기본값)

		verts[i] = v
		uvs[i] = uv

	# Triangle 1: 0 -> 1 -> 2 (원본 _add_face와 동일)
	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(uvs[0])
	st.add_vertex(verts[0])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(uvs[1])
	st.add_vertex(verts[1])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(uvs[2])
	st.add_vertex(verts[2])

	# Triangle 2: 0 -> 2 -> 3 (원본 _add_face와 동일)
	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(uvs[0])
	st.add_vertex(verts[0])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(uvs[2])
	st.add_vertex(verts[2])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(uvs[3])
	st.add_vertex(verts[3])


func _on_thread_mesh_complete() -> void:
	_is_thread_running = false
	
	if not is_instance_valid(self) or not is_inside_tree():
		_cleanup_thread_data()
		return
	
	# ★ 변경: PENDING 유무와 관계없이 일단 finalize 큐에 등록
	# (사용자에게 즉각적인 피드백 제공, PENDING은 finalize 후 처리)
	# Note: _is_priority_update는 finalize_build()에서 리셋 (물리 바이패스용)
	if WorldGenerator.instance:
		if _is_priority_update:
			WorldGenerator.instance.request_priority_chunk_apply(self)
		else:
			WorldGenerator.instance.request_chunk_apply(self)

## [Critical Optimization] 실제 노드 생성 및 씬 트리 적용 (WorldGenerator가 호출)
func finalize_build() -> void:
	if WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[FINALIZE_START] Chunk %s, thread_voxel_data: %d" % [chunk_position, _thread_voxel_data.size()])
	var t0: int = Time.get_ticks_usec()
	
	# 1. 메쉬 적용 (MeshInstance3D 생성 및 add_child)
	if _thread_mesh:
		_apply_visual_mesh(_thread_mesh)
	var t1: int = Time.get_ticks_usec()
	
	# 2. 충돌체 쉐이프 캐싱
	_cached_shape = _thread_shape
	var t2: int = Time.get_ticks_usec()
	
	# 3. [핵심] "현재" 플레이어 위치 기준으로 충돌체 필요 여부 판단
	var needs_collision_now: bool = false
	if WorldGenerator.instance and WorldGenerator.instance.player:
		var player_pos: Vector3 = WorldGenerator.instance.player.global_position
		var player_chunk: Vector2i = Global.world_to_chunk(player_pos)
		var dist: float = Vector2(player_chunk - chunk_position).length()
		if dist <= Global.PHYSICS_DISTANCE:
			needs_collision_now = true
	
	# 4. 충돌체 생성 - ★ 우선순위면 즉시, 아니면 큐
	if needs_collision_now:
		if _is_priority_update:
			# 플레이어 상호작용: 큐 무시하고 즉시 생성
			create_collision_robust()
			if WorldGenerator.instance and WorldGenerator.instance.log_collision:
				print("[PRIORITY_COLLISION] Chunk %s immediate collision create" % chunk_position)
		elif WorldGenerator.instance:
			# 배경 로딩: 큐에 등록
			WorldGenerator.instance.request_collision_create(self)
	var t3: int = Time.get_ticks_usec()
	
	# 5. 스레드 데이터 정리
	_cleanup_thread_data()
	var t4: int = Time.get_ticks_usec()
	
	# 6. 완료 시그널 발송
	mesh_thread_completed.emit()
	
	# [측정] 단계별 비용 로그
	var duration: int = t4 - t0
	if WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[FINALIZE] mesh: %d, cache: %d, collision_req: %d, cleanup: %d (µs)" % [t1-t0, t2-t1, t3-t2, t4-t3])
	
	# [PERF] Lag Spike 감지 (10ms 초과 시 경고)
	if duration > 10000 and WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[LAG SPIKE] Chunk %s finalize_build took %d µs (%.2f ms)" % [chunk_position, duration, duration / 1000.0])
	
	# [BENCHMARK] 1ms 이상이면 통계 기록
	if duration > 1000 and WorldGenerator.instance:
		WorldGenerator.instance.record_finalize_time(duration / 1000.0)
	
	if chunk_position == Vector2i(0, 0) and WorldGenerator.instance and WorldGenerator.instance.log_diag:
		var mi = get_node_or_null("MeshInstance3D")
		if mi and mi.mesh:
			var aabb = mi.mesh.get_aabb()
			print("[DIAG] Chunk (0,0) AABB: %s" % aabb)
	
	# ★ 추가: PENDING이 있으면 재업데이트 시작 (현재 결과는 이미 화면에 반영됨)
	if _pending_mesh_update:
		if WorldGenerator.instance and WorldGenerator.instance.log_collision:
			print("[PENDING_RESTART] Chunk %s scheduling deferred update" % chunk_position)
		_pending_mesh_update = false
		var needs_col: bool = _pending_needs_collision
		_pending_needs_collision = false
		# call_deferred로 현재 finalize 완료 후 시작
		call_deferred("start_threaded_mesh_update", needs_col, true)  # priority=true
	
	# ★ 마지막에 우선순위 플래그 리셋
	_is_priority_update = false


## 스레드 데이터 정리
func _cleanup_thread_data() -> void:
	if WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[CLEANUP] voxel_data: %d" % _thread_voxel_data.size())
	_thread_voxel_data = PackedInt32Array()  # 메모리 해제
	_thread_mesh = null
	_thread_shape = null
	# Note: _cached_shape는 정리하지 않음 (충돌체 재생성에 필요)

## [Thread-Safe] 이웃 블록 솔리드 확인 - 배열 인덱스 접근
func _is_neighbor_solid_threadsafe(neighbor_local: Vector3i) -> bool:
	# Y축 범위 체크
	if neighbor_local.y < 0 or neighbor_local.y >= CHUNK_HEIGHT:
		return false

	# 청크 내부인지 확인
	var is_inside_x: bool = neighbor_local.x >= 0 and neighbor_local.x < CHUNK_SIZE
	var is_inside_z: bool = neighbor_local.z >= 0 and neighbor_local.z < CHUNK_SIZE

	if is_inside_x and is_inside_z:
		# 내부: 배열 인덱스 접근 (고속)
		var idx: int = neighbor_local.y + neighbor_local.x * CHUNK_HEIGHT + neighbor_local.z * CHUNK_HEIGHT * CHUNK_SIZE
		return _thread_voxel_data[idx] != 0

	# 경계면: 이웃 청크 직접 조회 (Mutex)
	if WorldGenerator.instance == null:
		return false

	var global_pos := WorldGenerator.to_global_pos(chunk_position, neighbor_local)
	return WorldGenerator.instance.is_block_solid_threadsafe(global_pos)

## 동기식 메쉬 업데이트 (초기 생성용 - 기존 호환성 유지)
func update_mesh() -> void:
	_create_mesh()


## 메쉬 데이터 빌드 - Greedy Meshing 적용 (동기식)
func _build_mesh_data() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Greedy Meshing: 각 방향별로 면을 병합하여 생성
	for dir in DIRECTIONS:
		_greedy_mesh_direction_sync(st, dir)

	st.index()
	st.generate_normals()

	var mesh: ArrayMesh = st.commit()
	if mesh:
		var face_count: int = mesh.get_faces().size() / 3
		if WorldGenerator.instance and WorldGenerator.instance.log_mesh:
			print("[MESH] Chunk %s: %d triangles" % [chunk_position, face_count])

	return mesh


## [Greedy Meshing] 특정 방향의 모든 면을 병합하여 생성 (동기식 버전)
func _greedy_mesh_direction_sync(st: SurfaceTool, dir: Vector3i) -> void:
	# ★ 방어 코드: 배열 크기 검증
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		return

	var slice_axis: int
	var u_axis: int
	var v_axis: int
	var slice_count: int
	var u_size: int
	var v_size: int

	if dir == Vector3i.UP or dir == Vector3i.DOWN:
		slice_axis = 1
		u_axis = 0
		v_axis = 2
		slice_count = CHUNK_HEIGHT
		u_size = CHUNK_SIZE
		v_size = CHUNK_SIZE
	elif dir == Vector3i.LEFT or dir == Vector3i.RIGHT:
		slice_axis = 0
		u_axis = 2
		v_axis = 1
		slice_count = CHUNK_SIZE
		u_size = CHUNK_SIZE
		v_size = CHUNK_HEIGHT
	else:
		slice_axis = 2
		u_axis = 0
		v_axis = 1
		slice_count = CHUNK_SIZE
		u_size = CHUNK_SIZE
		v_size = CHUNK_HEIGHT

	for slice_idx in range(slice_count):
		var mask: Array = []
		mask.resize(u_size)
		for u in range(u_size):
			mask[u] = []
			mask[u].resize(v_size)
			for v in range(v_size):
				mask[u][v] = false

		for u in range(u_size):
			for v in range(v_size):
				var pos := Vector3i.ZERO
				pos[slice_axis] = slice_idx
				pos[u_axis] = u
				pos[v_axis] = v

				# 인라인 인덱스 계산 (성능 최적화)
				var idx: int = pos.y + pos.x * CHUNK_HEIGHT + pos.z * CHUNK_HEIGHT * CHUNK_SIZE
				if _voxel_data[idx] != 0:
					var neighbor: Vector3i = pos + dir
					if not _is_neighbor_solid(pos, neighbor, dir):
						mask[u][v] = true

		for v in range(v_size):
			var u: int = 0
			while u < u_size:
				if mask[u][v]:
					var width: int = 1
					while u + width < u_size and mask[u + width][v]:
						width += 1

					var height: int = 1
					var can_expand: bool = true
					while v + height < v_size and can_expand:
						for wu in range(width):
							if not mask[u + wu][v + height]:
								can_expand = false
								break
						if can_expand:
							height += 1

					var pos := Vector3i.ZERO
					pos[slice_axis] = slice_idx
					pos[u_axis] = u
					pos[v_axis] = v

					_add_greedy_face(st, pos, dir, width, height, u_axis, v_axis)

					for wu in range(width):
						for wv in range(height):
							mask[u + wu][v + wv] = false

					u += width
				else:
					u += 1


func _apply_visual_mesh(mesh: ArrayMesh) -> void:
	# 기존 MeshInstance3D 풀에 반납
	for child in get_children():
		if child is MeshInstance3D:
			_return_mesh_to_pool(child)
	
	var t1 = Time.get_ticks_usec()
	var mi: MeshInstance3D = _get_pooled_mesh_instance()
	mi.name = "MeshInstance3D"
	var t2 = Time.get_ticks_usec()
	mi.mesh = mesh
	var t3 = Time.get_ticks_usec()
	
	if _shared_material == null:
		_shared_material = StandardMaterial3D.new()
		_shared_material.vertex_color_use_as_albedo = true
	mi.set_surface_override_material(0, _shared_material)
	var t4 = Time.get_ticks_usec()
	
	add_child(mi)
	var t5 = Time.get_ticks_usec()

	if WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[MESH_APPLY] new: %d, mesh=: %d, mat: %d, add_child: %d (µs)" % [t2-t1, t3-t2, t4-t3, t5-t4])


## 충돌체 생성 (기존 충돌체 삭제 후 재생성)
func _create_collision() -> void:
	# 기존 충돌체 삭제
	_remove_collision_internal()

	# MeshInstance3D 찾기
	var mi: MeshInstance3D = null
	for child in get_children():
		if child is MeshInstance3D:
			mi = child
			break

	if mi == null or mi.mesh == null:
		return

	if mi.mesh.get_surface_count() > 0:
		mi.create_trimesh_collision()

func create_collision_robust() -> void:
	var start_time: int = Time.get_ticks_usec()
	
	# 기존 RID 임시 저장 (나중에 삭제)
	var old_rid: RID = _collision_rid
	
	if _cached_shape:
		# 1. 새 바디 먼저 생성
		var body_rid = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		
		# 2. 쉐이프 추가
		PhysicsServer3D.body_add_shape(body_rid, _cached_shape.get_rid())
		
		# 3. 위치 설정
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)
		
		# 4. 월드 공간에 등록
		var space_rid = get_world_3d().space
		PhysicsServer3D.body_set_space(body_rid, space_rid)
		
		# 5. 새 RID 저장
		_collision_rid = body_rid
	else:
		_collision_rid = RID()
	
	# 6. 기존 충돌체 삭제 (새 것이 준비된 후)
	if old_rid.is_valid():
		PhysicsServer3D.free_rid(old_rid)
	
	var duration: int = Time.get_ticks_usec() - start_time
	if duration > 1000 and WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[LAG SPIKE] Chunk %s Collision Create took %.2f ms" % [chunk_position, duration / 1000.0])
	if duration > 1000 and WorldGenerator.instance:
		WorldGenerator.instance.record_collision_time(duration / 1000.0)


func enable_collision() -> void:
	if _collision_rid.is_valid():
		# 이미 있으면 활성화만
		PhysicsServer3D.body_set_collision_layer(_collision_rid, 1)
		PhysicsServer3D.body_set_collision_mask(_collision_rid, 1)
	else:
		# 없으면 생성 요청
		if WorldGenerator.instance:
			WorldGenerator.instance.request_collision_create(self)

func disable_collision() -> void:
	if _collision_rid.is_valid():
		PhysicsServer3D.body_set_collision_layer(_collision_rid, 0)
		PhysicsServer3D.body_set_collision_mask(_collision_rid, 0)


func has_physics_body() -> bool:
	return _collision_rid.is_valid()



func _remove_collision_internal() -> void:
	if _collision_rid.is_valid():
		PhysicsServer3D.free_rid(_collision_rid)
		_collision_rid = RID()


func has_collision() -> bool:
	return _collision_rid.is_valid()


## 동기식 메쉬 생성 (기존 호환성 - 초기 청크 생성용)
func _create_mesh() -> void:
	var mesh: ArrayMesh = _build_mesh_data()
	_apply_visual_mesh(mesh)
	_create_collision()


## ★ 이웃 블록 솔리드 체크 (로컬 vs 글로벌)
func _is_neighbor_solid(_local_pos: Vector3i, neighbor_local: Vector3i, _dir: Vector3i) -> bool:
	# Y축 범위 체크 (위아래는 항상 로컬)
	if neighbor_local.y < 0 or neighbor_local.y >= CHUNK_HEIGHT:
		return false

	# 청크 내부인지 확인
	var is_inside_x: bool = neighbor_local.x >= 0 and neighbor_local.x < CHUNK_SIZE
	var is_inside_z: bool = neighbor_local.z >= 0 and neighbor_local.z < CHUNK_SIZE

	if is_inside_x and is_inside_z:
		# 내부: 배열 인덱스 접근 (고속)
		var idx: int = neighbor_local.y + neighbor_local.x * CHUNK_HEIGHT + neighbor_local.z * CHUNK_HEIGHT * CHUNK_SIZE
		return _voxel_data[idx] != 0
	else:
		# 경계면: 글로벌 조회 (WorldGenerator 통해)
		if WorldGenerator.instance == null:
			return false  # 아직 초기화 안 됨

		var global_pos: Vector3i = WorldGenerator.to_global_pos(chunk_position, neighbor_local)
		return WorldGenerator.instance.is_block_solid_global(global_pos)


func _add_face(st: SurfaceTool, pos: Vector3i, dir: Vector3i):
	var verts = FACE_VERTICES[dir]
	var normal = Vector3(dir)

	var color = Color(0.2, 0.8, 0.2) if dir == Vector3i.UP else Color(0.5, 0.35, 0.2)

	# Tri 1: 0 -> 1 -> 2
	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(Vector3(pos) + verts[0])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(Vector3(pos) + verts[1])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(Vector3(pos) + verts[2])

	# Tri 2: 0 -> 2 -> 3
	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(Vector3(pos) + verts[0])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(Vector3(pos) + verts[2])

	st.set_normal(normal)
	st.set_color(color)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(Vector3(pos) + verts[3])

func _exit_tree() -> void:
	if _collision_rid.is_valid():
		PhysicsServer3D.free_rid(_collision_rid)
		_collision_rid = RID()


## 풀에서 MeshInstance3D 가져오기 (없으면 새로 생성)
static func _get_pooled_mesh_instance() -> MeshInstance3D:
	if _mesh_instance_pool.size() > 0:
		return _mesh_instance_pool.pop_back()
	return MeshInstance3D.new()


## MeshInstance3D를 풀에 반납
static func _return_mesh_to_pool(mi: MeshInstance3D) -> void:
	if mi.get_parent():
		mi.get_parent().remove_child(mi)
	mi.mesh = null
	_mesh_instance_pool.append(mi)

## 풀 프리워밍 (로딩 중 미리 생성)
static func prewarm_pool(count: int) -> void:
	for i in range(count):
		var mi := MeshInstance3D.new()
		_mesh_instance_pool.append(mi)
	print("[POOL] Prewarmed %d MeshInstance3D" % count)


## Thread-safe 복셀 존재 확인
func has_voxel_threadsafe(local_pos: Vector3i) -> bool:
	if not _is_valid_local_pos(local_pos.x, local_pos.y, local_pos.z):
		return false
	_voxel_mutex.lock()
	if _voxel_data.size() != VOXEL_DATA_SIZE:
		_voxel_mutex.unlock()
		return false
	var idx: int = local_pos.y + local_pos.x * CHUNK_HEIGHT + local_pos.z * CHUNK_HEIGHT * CHUNK_SIZE
	var result: bool = _voxel_data[idx] != 0
	_voxel_mutex.unlock()
	return result
