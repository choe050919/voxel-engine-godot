class_name VoxelChunk
extends StaticBody3D
## VoxelChunk.gd - Seamless Chunk Borders
## Cross-Chunk Face Culling + WorkerThreadPool 멀티스레딩

const CHUNK_SIZE = 16
const CHUNK_HEIGHT = 64

# 생성된 물리 바디 참조 저장
var _collision_rid: RID

# 복셀 데이터 저장 (x, y, z)
var _voxels: Dictionary = {}
var chunk_position: Vector2i

# 공유 머티리얼 (모든 청크가 동일한 머티리얼 사용)
static var _shared_material: StandardMaterial3D = null

static var _mesh_instance_pool: Array[MeshInstance3D] = []

# Phase 2-6: 충돌체 상태 - Self-Healing (변수 캐싱 제거됨)
# has_collision()은 항상 실제 노드 존재 여부를 확인

# ================================
# Phase 2-7: Thread State
# ================================
var _is_thread_running: bool = false          # 스레드 작업 진행 중
var _thread_voxels: Dictionary = {}           # 스레드용 복셀 데이터 복사본
var _thread_border_solids: Dictionary = {}    # 스레드용 경계면 솔리드 캐시
var _thread_needs_collision: bool = false     # 완료 후 충돌체 생성 여부

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


func _generate_voxel_data(n1: FastNoiseLite, n2: FastNoiseLite):
	_voxels.clear()
	var global_x_start = chunk_position.x * CHUNK_SIZE
	var global_z_start = chunk_position.y * CHUNK_SIZE

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			var gx = global_x_start + x
			var gz = global_z_start + z

			var h1 = n1.get_noise_2d(gx, gz)
			var h2 = n2.get_noise_2d(gx, gz)
			var height = int((h1 * 20.0 + 20.0) + (h2 * 4.0))
			height = clamp(height, 1, CHUNK_HEIGHT - 1)

			for y in range(height + 1):
				_voxels[Vector3i(x, y, z)] = 1


# ================================
# Phase 2-7: Threaded Mesh Building
# ================================

## 스레드 작업 진행 중인지 확인
func is_thread_running() -> bool:
	return _is_thread_running


## 스레드를 사용한 메쉬 업데이트 시작
func start_threaded_mesh_update(with_collision: bool = false) -> void:
	if _is_thread_running:
		return  # 이미 스레드 작업 중

	if WorldGenerator.instance and WorldGenerator.instance.log_debug:
		print("[DEBUG] Chunk %s starting mesh update, voxel count: %d" % [chunk_position, _voxels.size()])

	# 스레드에서 사용할 데이터 복사 (Thread Safety)
	_thread_voxels = _voxels.duplicate()
	_thread_needs_collision = with_collision

	# 경계면 이웃 솔리드 상태 미리 캐싱 (Main Thread에서 안전하게)
	_cache_border_neighbors()

	_is_thread_running = true

	# WorkerThreadPool에 태스크 추가
	WorkerThreadPool.add_task(_thread_build_mesh_arrays)


## 경계면 이웃 블록의 솔리드 상태를 미리 캐싱 (Main Thread)
func _cache_border_neighbors() -> void:
	_thread_border_solids.clear()
	
	if WorldGenerator.instance == null:
		return
	
	# X=0 경계 (LEFT 방향)
	for z in range(CHUNK_SIZE):
		for y in range(CHUNK_HEIGHT):
			if _voxels.has(Vector3i(0, y, z)):  # 블록 있을 때만
				_query_global_and_cache(Vector3i(-1, y, z))
	
	# X=CHUNK_SIZE-1 경계 (RIGHT 방향)
	for z in range(CHUNK_SIZE):
		for y in range(CHUNK_HEIGHT):
			if _voxels.has(Vector3i(CHUNK_SIZE - 1, y, z)):
				_query_global_and_cache(Vector3i(CHUNK_SIZE, y, z))
	
	# Z=0 경계 (FORWARD 방향)
	for x in range(CHUNK_SIZE):
		for y in range(CHUNK_HEIGHT):
			if _voxels.has(Vector3i(x, y, 0)):
				_query_global_and_cache(Vector3i(x, y, -1))
	
	# Z=CHUNK_SIZE-1 경계 (BACK 방향)
	for x in range(CHUNK_SIZE):
		for y in range(CHUNK_HEIGHT):
			if _voxels.has(Vector3i(x, y, CHUNK_SIZE - 1)):
				_query_global_and_cache(Vector3i(x, y, CHUNK_SIZE))


func _query_global_and_cache(local_pos: Vector3i) -> void:
	if _thread_border_solids.has(local_pos):
		return
	var global_pos: Vector3i = WorldGenerator.to_global_pos(chunk_position, local_pos)
	_thread_border_solids[local_pos] = WorldGenerator.instance.is_block_solid_global(global_pos)


## [Worker Thread] 메쉬 및 충돌체 빌드 - Greedy Meshing 적용
func _thread_build_mesh_arrays() -> void:
	if WorldGenerator.instance and WorldGenerator.instance.log_mesh:
		print("[THREAD] Chunk %s _thread_voxels.size() = %d" % [chunk_position, _thread_voxels.size()])
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

				if _thread_voxels.has(pos):
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


## [Main Thread] 스레드 작업 완료 콜백 (권한 박탈 - 오직 큐 등록만)
func _on_thread_mesh_complete() -> void:
	_is_thread_running = false

	# 안전성 검사
	if not is_instance_valid(self) or not is_inside_tree():
		_cleanup_thread_data()
		return

	# [핵심] 절대 finalize_build()를 여기서 호출하지 마십시오.
	# 오직 WorldGenerator의 큐에 자신을 넣기만 합니다.
	if WorldGenerator.instance:
		WorldGenerator.instance.request_chunk_apply(self)


## [Critical Optimization] 실제 노드 생성 및 씬 트리 적용 (WorldGenerator가 호출)
func finalize_build() -> void:
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
	
	# 4. 충돌체 생성 요청
	if needs_collision_now:
		if WorldGenerator.instance:
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


## 스레드 데이터 정리
func _cleanup_thread_data() -> void:
	if WorldGenerator.instance and WorldGenerator.instance.log_collision:
		print("[CLEANUP] voxels: %d, border: %d" % [_thread_voxels.size(), _thread_border_solids.size()])
	_thread_voxels.clear()
	_thread_border_solids.clear()
	_thread_mesh = null
	_thread_shape = null
	# Note: _cached_shape는 정리하지 않음 (충돌체 재생성에 필요)


## [Thread-Safe] 이웃 블록 솔리드 체크
func _is_neighbor_solid_threadsafe(neighbor_local: Vector3i) -> bool:
	# 방어 코드
	if _thread_voxels == null or _thread_border_solids == null:
		return false
	
	# Y축 범위 체크
	if neighbor_local.y < 0 or neighbor_local.y >= CHUNK_HEIGHT:
		return false

	# 청크 내부인지 확인
	var is_inside_x: bool = neighbor_local.x >= 0 and neighbor_local.x < CHUNK_SIZE
	var is_inside_z: bool = neighbor_local.z >= 0 and neighbor_local.z < CHUNK_SIZE

	if is_inside_x and is_inside_z:
		# 내부: 복사된 복셀 데이터에서 조회
		return _thread_voxels.has(neighbor_local)
	else:
		# 경계면: 미리 캐싱된 데이터에서 조회
		return _thread_border_solids.get(neighbor_local, false)


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

				if _voxels.has(pos):
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
	
	# 기존 RID가 있으면 해제
	if _collision_rid.is_valid():
		PhysicsServer3D.free_rid(_collision_rid)
		_collision_rid = RID()
	
	if _cached_shape:
		# 1. 바디 생성
		var body_rid = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		
		# 2. 쉐이프 추가
		PhysicsServer3D.body_add_shape(body_rid, _cached_shape.get_rid())
		
		# 3. 위치 설정
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)
		
		# 4. 월드 공간에 등록
		var space_rid = get_world_3d().space
		PhysicsServer3D.body_set_space(body_rid, space_rid)
		
		# 5. RID 저장
		_collision_rid = body_rid
	
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
func _is_neighbor_solid(local_pos: Vector3i, neighbor_local: Vector3i, dir: Vector3i) -> bool:
	# Y축 범위 체크 (위아래는 항상 로컬)
	if neighbor_local.y < 0 or neighbor_local.y >= CHUNK_HEIGHT:
		return false

	# 청크 내부인지 확인
	var is_inside_x: bool = neighbor_local.x >= 0 and neighbor_local.x < CHUNK_SIZE
	var is_inside_z: bool = neighbor_local.z >= 0 and neighbor_local.z < CHUNK_SIZE

	if is_inside_x and is_inside_z:
		# 내부: 로컬 조회 (빠름)
		return _voxels.has(neighbor_local)
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
