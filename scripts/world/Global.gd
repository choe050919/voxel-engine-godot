extends Node
## Global.gd - Autoload
## 전역 상수 및 유틸리티

# ================================
# Chunk Settings
# ================================
const CHUNK_SIZE: int = 16       # 청크 가로/세로 (16x16)
const CHUNK_HEIGHT: int = 64     # 청크 최대 높이 (깊이감 확보)
const BLOCK_SCALE: float = 1.0   # 1복셀 = 1m

# ================================
# World Settings
# ================================
const SEA_LEVEL: int = 32        # 해수면 높이 (기준점)
const BASE_TERRAIN_HEIGHT: int = 40  # 기본 지형 높이

# ================================
# Render Settings (디렉터 조절용)
# ================================
const RENDER_DISTANCE: int = 8  # 청크 렌더링 반경 (10 = 21x21 = ~314개 청크)
const PHYSICS_DISTANCE: int = 4  # 물리/충돌 반경 (4 = 9x9 = ~50개 청크)
const CHUNKS_PER_FRAME: int = 2  # 프레임당 생성할 최대 청크 수

# ================================
# Block Types
# ================================
enum BlockType {
	AIR = 0,
	GRASS = 1,
	DIRT = 2,
	STONE = 3,
}


## 월드 좌표를 청크 좌표로 변환
static func world_to_chunk(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / CHUNK_SIZE),
		floori(world_pos.z / CHUNK_SIZE)
	)
