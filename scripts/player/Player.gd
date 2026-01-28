class_name Player
extends CharacterBody3D
## Player Controller - Phase 2-8
## Constant Gravity + Input-Driven Step Sensing + World Loading Lock

# ================================
# Phase 2-8: Loading Lock State
# ================================
var is_locked: bool = true  # 월드 로딩 중 이동/중력 차단

# ================================
# Constants (튜닝 파라미터)
# ================================
const SPEED: float = 5.0
const SPRINT_SPEED: float = 8.0
const SNEAK_SPEED: float = 2.5
const JUMP_VELOCITY: float = 12.0  # 강한 중력을 이겨낼 폭발적 점프력
const MOUSE_SENSITIVITY: float = 0.002

# 중력 배수 (상시 적용 - 타협 없는 무게감)
const GRAVITY_MULTIPLIER: float = 4.0

# 시점 제한 (고개 꺾임 방지)
const PITCH_LIMIT: float = 89.0

# 웅크리기 관련 상수
const STAND_HEIGHT: float = 1.8          # 서있을 때 캡슐 높이
const CROUCH_HEIGHT: float = 1.2         # 웅크릴 때 캡슐 높이
const STAND_COLLISION_Y: float = 0.9     # 서있을 때 콜리전 Y (높이/2)
const CROUCH_COLLISION_Y: float = 0.6    # 웅크릴 때 콜리전 Y (높이/2)
const STAND_HEAD_Y: float = 1.6          # 서있을 때 머리 높이
const CROUCH_HEAD_Y: float = 1.0         # 웅크릴 때 머리 높이
const CROUCH_TRANSITION_SPEED: float = 10.0  # 웅크리기 전환 속도

# 계단 오르기 관련 상수
const MAX_STEP_HEIGHT: float = 0.5       # 최대 계단 높이 (0.5m)
const STEP_CHECK_DISTANCE: float = 0.75  # 전방 계단 감지 거리

# 걷기 애니메이션
const WALK_ANIM_SPEED: float = 10.0  # 흔들림 속도
const ARM_SWING_ANGLE: float = 0.5   # 팔 흔들림 각도 (라디안)
const LEG_SWING_ANGLE: float = 0.7   # 다리 흔들림 각도 (라디안)

# ================================
# Node References
# ================================
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var interact_ray: RayCast3D = $Head/InteractRay
@onready var ceiling_ray: RayCast3D = $CeilingCheck
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var capsule: CapsuleShape3D = collision_shape.shape

# 계단 감지 레이캐스트
@onready var step_ray_low: RayCast3D = $StepChecks/StepRayLow
@onready var step_ray_high: RayCast3D = $StepChecks/StepRayHigh

# 바디 메쉬
@onready var torso_mesh: MeshInstance3D = $BodyMesh/Torso

# 팔다리 피벗 (걷기 애니메이션용)
@onready var left_arm_pivot: Node3D = $BodyMesh/LeftArmPivot
@onready var right_arm_pivot: Node3D = $BodyMesh/RightArmPivot
@onready var left_leg_pivot: Node3D = $BodyMesh/LeftLegPivot
@onready var right_leg_pivot: Node3D = $BodyMesh/RightLegPivot

# ================================
# State Variables
# ================================
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_speed: float = SPEED

# 웅크리기 상태
var is_crouching: bool = false
var wants_to_stand: bool = false  # 키를 뗐지만 천장 때문에 못 일어나는 상태

# 현재 타겟 값 (부드러운 전환용)
var target_head_y: float = STAND_HEAD_Y
var target_collision_y: float = STAND_COLLISION_Y
var target_capsule_height: float = STAND_HEIGHT

# 걷기 애니메이션 타이머
var walk_anim_time: float = 0.0


func _ready() -> void:
	# 마우스 캡처 (게임 시작 시 마우스 숨김 및 고정)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## Phase 2-8: 플레이어 잠금 해제 (Critical Fix: 속도 초기화 보장)
func unlock() -> void:
	# 속도 완전 초기화 (낙하 방지)
	velocity = Vector3.ZERO

	# 위치 확인 로그
	print("[Player] Unlocking at position: %s" % global_position)
	print("[Player] Velocity reset to: %s" % velocity)

	# 바닥 상태 갱신
	move_and_slide()

	# 잠금 해제
	is_locked = false

	print("[Player] is_on_floor after unlock: %s" % is_on_floor())


## Phase 2-8: 플레이어 잠금
func lock() -> void:
	is_locked = true
	velocity = Vector3.ZERO  # 잠금 시에도 속도 초기화


# ================================
# Phase 5-3: Save/Load State
# ================================

## 현재 상태를 딕셔너리로 반환 (저장용)
func get_save_data() -> Dictionary:
	return {
		"position": global_position,
		"rotation_y": rotation.y,
		"head_rotation_x": head.rotation.x if head else 0.0
	}


## 저장된 상태 적용 (로드용)
func apply_save_data(data: Dictionary) -> void:
	if data.is_empty():
		return

	# 위치 복원 (y에 오프셋 추가하여 바닥 관통 방지)
	if data.has("position"):
		var pos_data = data["position"]
		var new_pos := Vector3(
			pos_data.get("x", 8.0),
			pos_data.get("y", 50.0),  # 안전 오프셋
			pos_data.get("z", 8.0)
		)
		global_position = new_pos
		print("[Player] Position restored to: %s" % new_pos)

	# 회전 복원
	if data.has("rotation_y"):
		rotation.y = data["rotation_y"]

	if data.has("head_rotation_x") and head:
		head.rotation.x = data["head_rotation_x"]

	# 속도 초기화
	velocity = Vector3.ZERO


func _input(event: InputEvent) -> void:
	# 마우스 이동 처리 (시점 회전)
	if event is InputEventMouseMotion:
		_handle_mouse_look(event)
		return

	# Note: ESC 키는 PauseMenu에서 처리 (Phase 5-2)

	# F5: 시점 전환
	if event.is_action_pressed("toggle_view"):
		_cycle_view_mode()

	# 블록 파괴
	if event.is_action_pressed("block_break"):
		_try_break_block()
	
	# 블록 설치
	if event.is_action_pressed("block_place"):
		_try_place_block()

func _physics_process(delta: float) -> void:
	# Phase 2-8: 월드 로딩 중이면 모든 물리 처리 차단
	if is_locked:
		return

	_handle_crouch(delta)
	_apply_gravity(delta)
	_handle_jump()
	_handle_movement()

	# 계단 오르기 (이동 전 입력 기반 감지)
	_handle_step_up()

	# 이동 실행
	move_and_slide()

	_handle_walk_animation(delta)


# ================================
# Mouse Look
# ================================
func _handle_mouse_look(event: InputEventMouseMotion) -> void:
	## 마우스 이동에 따른 카메라 회전
	## Yaw: 플레이어 전체 회전 (좌우)
	## Pitch: Head 노드만 회전 (상하)

	# Yaw (Y축 회전) - 플레이어 전체
	rotate_y(-event.relative.x * MOUSE_SENSITIVITY)

	# Pitch (X축 회전) - Head만
	head.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
	head.rotation.x = clamp(head.rotation.x, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))


# ================================
# Crouch System (물리적 웅크리기)
# ================================
func _handle_crouch(delta: float) -> void:
	## 웅크리기 입력 처리 및 물리적 충돌체 조정

	var wants_crouch: bool = Input.is_action_pressed("sneak")

	if wants_crouch:
		# 웅크리기 시작
		is_crouching = true
		wants_to_stand = false
		target_head_y = CROUCH_HEAD_Y
		target_collision_y = CROUCH_COLLISION_Y
		target_capsule_height = CROUCH_HEIGHT
	else:
		# 일어서기 시도
		if is_crouching:
			wants_to_stand = true
			# 천장 체크: 일어설 공간이 있는지 확인
			if _can_stand_up():
				is_crouching = false
				wants_to_stand = false
				target_head_y = STAND_HEAD_Y
				target_collision_y = STAND_COLLISION_Y
				target_capsule_height = STAND_HEIGHT
			# 공간이 없으면 웅크린 상태 유지 (wants_to_stand = true)

	# 부드러운 전환 적용
	_apply_crouch_transition(delta)

func _can_stand_up() -> bool:
	## 머리 위에 일어설 공간이 있는지 확인
	## CeilingCheck RayCast3D가 충돌하지 않으면 일어설 수 있음
	return not ceiling_ray.is_colliding()


func _apply_crouch_transition(delta: float) -> void:
	## 충돌체와 카메라 높이를 부드럽게 전환
	var lerp_speed: float = delta * CROUCH_TRANSITION_SPEED

	# 캡슐 높이 조정
	capsule.height = lerp(capsule.height, target_capsule_height, lerp_speed)

	# 콜리전 위치 조정 (발바닥 고정)
	collision_shape.position.y = lerp(collision_shape.position.y, target_collision_y, lerp_speed)

	# 머리/카메라 높이 조정
	head.position.y = lerp(head.position.y, target_head_y, lerp_speed)

	# 천장 체크 레이 위치도 조정 (현재 머리 위치 기준)
	ceiling_ray.position.y = collision_shape.position.y + (capsule.height * 0.5)


# ================================
# Gravity & Jump
# ================================
func _apply_gravity(delta: float) -> void:
	## 중력 적용 - 상시 GRAVITY_MULTIPLIER 적용
	## 상승/하강 구분 없이 항상 강한 중력으로 무게감 구현
	if not is_on_floor():
		velocity.y -= gravity * GRAVITY_MULTIPLIER * delta


func _handle_jump() -> void:
	## 점프 처리 (바닥에 있고 웅크리지 않을 때만)
	if Input.is_action_just_pressed("jump") and is_on_floor() and not is_crouching:
		velocity.y = JUMP_VELOCITY


# ================================
# Movement
# ================================
func _handle_movement() -> void:
	## WASD 이동 처리
	## 마인크래프트 스타일: 관성 없이 즉각 반응

	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	_update_speed()

	if direction:
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0


func _update_speed() -> void:
	## 현재 이동 속도 결정
	if is_crouching:
		current_speed = SNEAK_SPEED
	elif Input.is_action_pressed("sprint") and is_on_floor():
		current_speed = SPRINT_SPEED
	else:
		current_speed = SPEED


# ================================
# Step Up System (계단 등반)
# ================================
func _handle_step_up() -> void:
	## 계단/턱 자동 등반 처리
	## ★ Input 기반: velocity가 아닌 입력 방향으로 감지
	## 벽에 막혀 velocity가 0이 되어도 키를 누르고 있으면 감지

	# 바닥에 있지 않으면 스킵 (공중에서는 계단 오르기 비활성)
	if not is_on_floor():
		return

	# ★ 핵심: Input에서 직접 이동 의도 방향 계산
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	if input_dir.length() < 0.1:
		return  # 이동 입력이 없으면 스킵

	# 로컬 입력 → 월드 기준 이동 의도 벡터
	var world_move_intent: Vector3 = (global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	# 월드 방향 → 로컬 좌표로 변환 (RayCast3D.target_position은 로컬 좌표)
	var local_ray_dir: Vector3 = global_transform.basis.inverse() * world_move_intent

	# 동적으로 레이캐스트 방향 설정 (입력 방향으로)
	step_ray_low.target_position = local_ray_dir * STEP_CHECK_DISTANCE
	step_ray_high.target_position = local_ray_dir * STEP_CHECK_DISTANCE

	# 레이캐스트 강제 업데이트
	step_ray_low.force_raycast_update()
	step_ray_high.force_raycast_update()

	# 하단 레이가 충돌하고 (장애물 있음)
	# 상단 레이가 충돌하지 않으면 (위쪽 공간 있음)
	# → 올라갈 수 있는 계단
	if step_ray_low.is_colliding() and not step_ray_high.is_colliding():
		var collision_point: Vector3 = step_ray_low.get_collision_point()

		# 올라갈 높이 계산 (장애물 위로)
		var step_height: float = _detect_step_height(collision_point, world_move_intent)

		if step_height > 0.01 and step_height <= MAX_STEP_HEIGHT:
			# 캐릭터를 계단 위로 이동
			global_position.y += step_height + 0.05  # 약간의 여유


func _detect_step_height(collision_point: Vector3, direction: Vector3) -> float:
	## 실제 계단 높이를 감지
	## 장애물 바로 위에서 아래로 레이캐스트하여 표면 높이 측정

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state

	# 장애물 위쪽에서 아래로 레이캐스트
	var ray_start: Vector3 = collision_point + direction * 0.1 + Vector3.UP * MAX_STEP_HEIGHT
	var ray_end: Vector3 = ray_start - Vector3.UP * MAX_STEP_HEIGHT

	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.exclude = [self.get_rid()]

	var result: Dictionary = space_state.intersect_ray(query)

	if result:
		var surface_y: float = result.position.y
		var current_floor_y: float = global_position.y
		return surface_y - current_floor_y

	return 0.0

# ================================
# Camera View Mode (F5 시점 전환)
# ================================
enum ViewMode { FIRST_PERSON, THIRD_PERSON_BACK, THIRD_PERSON_FRONT }
var current_view: ViewMode = ViewMode.FIRST_PERSON

# 3인칭 카메라 거리
const THIRD_PERSON_DISTANCE: float = 4.0

func _cycle_view_mode() -> void:
	current_view = (current_view + 1) % 3 as ViewMode
	_apply_view_mode()


func _apply_view_mode() -> void:
	match current_view:
		ViewMode.FIRST_PERSON:
			camera.position = Vector3(0, 0, 0.15)
			camera.rotation.y = 0
			torso_mesh.visible = false  # 1인칭에서 상체 숨김 (선택)
		ViewMode.THIRD_PERSON_BACK:
			camera.position = Vector3(0, 0.5, THIRD_PERSON_DISTANCE)
			camera.rotation.y = 0
			torso_mesh.visible = true
		ViewMode.THIRD_PERSON_FRONT:
			camera.position = Vector3(0, 0.5, -THIRD_PERSON_DISTANCE)
			camera.rotation.y = PI  # 180도 회전
			torso_mesh.visible = true

# ================================
# Walk Animation
# ================================
func _handle_walk_animation(delta: float) -> void:
	var is_moving: bool = velocity.length() > 0.1 and is_on_floor()
	
	if is_moving:
		# 속도에 따라 애니메이션 속도 조절
		var speed_factor: float = current_speed / SPEED
		walk_anim_time += delta * WALK_ANIM_SPEED * speed_factor
		
		var swing: float = sin(walk_anim_time)
		
		# 팔: 다리와 반대로 흔들림
		left_arm_pivot.rotation.x = swing * ARM_SWING_ANGLE
		right_arm_pivot.rotation.x = -swing * ARM_SWING_ANGLE
		
		# 다리
		left_leg_pivot.rotation.x = -swing * LEG_SWING_ANGLE
		right_leg_pivot.rotation.x = swing * LEG_SWING_ANGLE
	else:
		# 정지 시 부드럽게 원위치
		walk_anim_time = 0.0
		left_arm_pivot.rotation.x = lerp(left_arm_pivot.rotation.x, 0.0, delta * 10.0)
		right_arm_pivot.rotation.x = lerp(right_arm_pivot.rotation.x, 0.0, delta * 10.0)
		left_leg_pivot.rotation.x = lerp(left_leg_pivot.rotation.x, 0.0, delta * 10.0)
		right_leg_pivot.rotation.x = lerp(right_leg_pivot.rotation.x, 0.0, delta * 10.0)

# ================================
# Block Interaction
# ================================
func _try_break_block() -> void:
	if not interact_ray.is_colliding():
		return
	
	var hit_pos: Vector3 = interact_ray.get_collision_point()
	var hit_normal: Vector3 = interact_ray.get_collision_normal()
	
	# 블록 중심 좌표 (표면에서 안쪽으로)
	var block_pos: Vector3 = hit_pos - hit_normal * 0.5
	var block_coord: Vector3i = Vector3i(floor(block_pos.x), floor(block_pos.y), floor(block_pos.z))
	
	WorldGenerator.instance.break_block(block_coord)


func _try_place_block() -> void:
	if not interact_ray.is_colliding():
		return
	
	var hit_pos: Vector3 = interact_ray.get_collision_point()
	var hit_normal: Vector3 = interact_ray.get_collision_normal()
	
	# 블록 설치 좌표 (표면에서 바깥쪽으로)
	var place_pos: Vector3 = hit_pos + hit_normal * 0.5
	var block_coord: Vector3i = Vector3i(floor(place_pos.x), floor(place_pos.y), floor(place_pos.z))
	
	WorldGenerator.instance.place_block(block_coord)
