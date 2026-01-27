# 🏗️ Voxel Engine Optimization Architecture
> **"The Swan Strategy"**: 물 밑(백엔드)에서는 치열하게 연산하지만, 물 위(프론트엔드)에서는 우아하고 끊김 없이.

이 문서는 본 프로젝트에 적용된 핵심 최적화 기술과 아키텍처 설계를 기술합니다. **"무한한 복셀 월드"**를 저사양 환경에서도 **"프레임 드랍(Stuttering) 없이"** 구동하기 위해 9가지 핵심 전략을 적용했습니다.

---

## 🎯 Executive Summary (핵심 요약)

| 기술 영역 | 적용 기술 (Keyword) | 기대 효과 (Value) |
| :--- | :--- | :--- |
| **CPU 부하 분산** | **WorkerThreadPool & Offloading** | 땅을 생성하는 무거운 계산 중에도 게임 화면이 멈추지 않음 |
| **렌더링 안정성** | **Main Thread Throttling (Queue)** | 로딩이 완료되어도 한 번에 1개씩만 화면에 그려 순간적인 렉 방지 |
| **메모리 최적화** | **Greedy Meshing & Pooling** | 불필요한 면을 제거하고 노드를 재사용하여 RAM/VRAM 사용량 최소화 |
| **물리 엔진** | **Dynamic Physics Bubble** | 플레이어 주변만 실제 물리 적용, 먼 곳은 연산 생략하여 CPU 절약 |
| **안전 장치** | **Fail-Safe Spawning** | 지형 로딩 실패 시 플레이어 추락을 방지하고 자동 복구하는 시스템 |

---

## 🛠️ Technical Detail (상세 기술 명세)

### 1. Zero-Stutter Pipeline (무중단 로딩 파이프라인)
가장 큰 병목인 '청크 생성(Meshing)'과 '충돌체 계산(Collision Baking)'을 메인 스레드에서 완전히 분리했습니다.

* **Multithreaded Offloading:** `VoxelChunk.gd`의 메쉬 빌드 작업을 `WorkerThreadPool`로 위임하여 백그라운드에서 처리합니다.
* **Throttling Queue System:**
    * 백그라운드 작업이 끝나도 즉시 화면에 띄우지 않고 `_chunk_apply_queue`에 등록합니다.
    * **Frame Budget:** 매 프레임당 `CHUNK_APPLIES_PER_FRAME` (기본값: 1개)만큼만 순차적으로 처리하여 프레임 타임 스파이크(Spike)를 원천 차단합니다.

### 2. Rendering Efficiency (렌더링 효율화)
복셀 게임의 고질적인 문제인 '너무 많은 삼각형(Vertex Count)' 문제를 해결했습니다.

* **Greedy Meshing:** 인접한 동일 텍스처의 블록들을 하나의 거대한 면(Face)으로 병합합니다. (삼각형 수 약 80% 감소 효과)
* **Cross-Chunk Culling:** 청크 경계면에 이웃 청크의 블록이 존재하면 해당 면을 그리지 않아, 보이지 않는 곳의 렌더링 비용을 "0"으로 만듭니다.
* **Material Sharing:** 모든 청크가 하나의 `StandardMaterial3D`를 공유하여 Draw Call 배칭 효율을 높입니다.

### 3. Smart Resource Management (지능형 자원 관리)
무한 맵 특성상 계속되는 메모리 할당/해제 비용을 관리합니다.

* **Node Pooling:** 청크가 시야에서 사라질 때 `MeshInstance3D`를 삭제(`queue_free`)하지 않고 풀(Pool)에 반납했다가, 새 청크 생성 시 재사용합니다.
* **Priority Loading:** `active_chunks` 로딩 시 플레이어와의 거리를 계산하여, 가까운 청크부터 우선적으로 생성합니다.

### 4. Dynamic Physics Bubble (동적 물리 버블)
Godot 물리 엔진(Jolt/PhysX)의 부하를 제어하기 위해 물리 연산 범위를 제한합니다.

* **Distance-Based Activation:** 플레이어 반경 `Global.PHYSICS_DISTANCE` 내의 청크만 `StaticBody3D` 충돌체를 생성/활성화합니다.
* **Async Collision Baking:** 값비싼 `create_trimesh_shape()` 연산을 스레드 내에서 미리 수행하고 캐싱(`_cached_shape`)하여, 메인 스레드에서는 적용만 수행합니다.

### 5. Stability & Monitoring (안전성 및 모니터링)
* **Fail-Safe Trap:** 플레이어가 지형 로딩 지연으로 바닥 아래로 떨어질 경우, 이를 감지하고 지상으로 안전하게 텔레포트시키는 로직이 내장되어 있습니다.
* **Performance Benchmark:** 30초간의 프레임, 청크 생성 시간, 지연 시간(Latency)을 측정하여 로그로 출력하는 벤치마크 도구가 포함되어 있습니다.

---

## 📂 Key Source Files
* **Core Logic:** `scripts/world/WorldGenerator.gd` (스케줄링, 큐 관리)
* **Chunk Logic:** `scripts/world/VoxelChunk.gd` (그리디 메싱, 스레드 처리)
* **Config:** `scripts/world/Global.gd` (전역 설정 상)