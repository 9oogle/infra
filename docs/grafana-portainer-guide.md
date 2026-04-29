# Grafana / Portainer 운영 가이드

모니터링 VM(`<MONITORING_EXTERNAL_IP>`)에서 동작하는 Grafana와 Portainer 사용 방법을 설명합니다.

---

## 목차

1. [Grafana 초기 설정](#1-grafana-초기-설정)
2. [대시보드 Import](#2-대시보드-import)
3. [주요 지표 해석](#3-주요-지표-해석)
4. [Alert 설정](#4-alert-설정)
5. [Portainer 초기 설정](#5-portainer-초기-설정)
6. [Portainer — kafka/redis VM 연결](#6-portainer--kafkaredis-vm-연결)
7. [Portainer 주요 기능](#7-portainer-주요-기능)

---

## 1. Grafana 초기 설정

**URL:** [http://34.50.39.161:3000](http://34.50.39.161:3000)
**초기 계정:** admin / `GRAFANA_PASSWORD` (`.env`에 설정한 값)

### Prometheus Data Source 연결

1. 좌측 메뉴 **Connections → Data sources → Add new data source**
2. **Prometheus** 선택
3. URL: `http://prometheus:9090` (같은 Docker network 내부)
4. **Save & test** → "Successfully queried the Prometheus API" 확인

---

## 2. 대시보드 Import

**Dashboards → New → Import → ID 입력 → Load**

| 대시보드 | ID | 용도 |
|----------|----|------|
| JVM (Micrometer) | `4701` | Spring Boot — Heap, GC, Thread, CPU |
| Spring Boot Statistics | `6756` | HTTP 처리량, 응답시간, 에러율 |
| Kafka Exporter Overview | `7589` | 브로커 메트릭, Consumer Lag, Topic 처리량 |
| Redis Dashboard | `763` | 메모리, 명령 처리량, 연결 수, 히트율 |
| Node Exporter Full | `1860` | 시스템 CPU, 메모리, 디스크, 네트워크 |

Import 후 **datasource** 드롭다운에서 `Prometheus`를 선택하고 저장합니다.

### Spring Boot 대시보드 — Application 필터

Import 후 상단 **Application** 변수 드롭다운에서 서비스 이름(예: `mentoring-service`)을 선택합니다. 이 값은 `management.metrics.tags.application: ${spring.application.name}` 설정에서 옵니다.

---

## 3. 주요 지표 해석

### Kafka (대시보드 7589)

| 지표 | 의미 | 임계값 기준 |
|------|------|------------|
| **Consumer Lag** | consumer가 produce 속도를 따라가지 못하는 메시지 수 | 지속 증가 시 consumer 성능 점검 |
| **Messages In/s** | 초당 브로커로 들어오는 메시지 수 | 갑작스러운 0 → 브로커 장애 의심 |
| **Under-Replicated Partitions** | replica가 부족한 파티션 수 | 0이어야 정상. 0 초과 시 브로커 점검 |
| **Active Controller** | 현재 KRaft 컨트롤러 역할을 하는 브로커 | 항상 1이어야 함 |

### Redis (대시보드 763)

| 지표 | 의미 | 임계값 기준 |
|------|------|------------|
| **Memory Usage** | 현재 사용 중인 메모리 | 256MB(maxmemory)의 80% 이상이면 경고 |
| **Keyspace Hits/Misses** | 캐시 히트율 | Hit rate 90% 미만이면 TTL/캐시 전략 재검토 |
| **Connected Clients** | 현재 연결된 클라이언트 수 | 급증 시 connection leak 점검 |
| **Evicted Keys** | LRU로 강제 제거된 키 수 | 지속 발생 시 메모리 증설 또는 TTL 단축 검토 |

### Node Exporter (대시보드 1860)

| 지표 | 임계값 기준 |
|------|------------|
| **CPU Usage** | 지속 80% 이상 → VM 스펙 검토 |
| **Memory Available** | 10% 미만 → OOM 위험 |
| **Disk Usage** | 85% 이상 → Kafka log 정리 또는 디스크 확장 |

---

## 4. Alert 설정

### Contact Point 설정 (Slack 예시)

1. **Alerting → Contact points → Add contact point**
2. Type: **Slack**
3. Webhook URL 입력 → **Test** → **Save**

### Alert Rule 생성

**Alerting → Alert rules → New alert rule**

아래는 권장 Alert 목록입니다.

#### Kafka Consumer Lag 급증

```promql
kafka_consumergroup_lag_sum > 1000
```
- Evaluation: 1m마다 평가, 5m 지속 시 발송

#### Redis 메모리 80% 초과

```promql
redis_memory_used_bytes / redis_memory_max_bytes > 0.8
```

#### Spring Boot 5xx 에러율 급증

```promql
rate(http_server_requests_seconds_count{status=~"5..",application="mentoring-service"}[5m]) > 0.1
```

#### Under-Replicated Partitions 발생

```promql
kafka_server_replicamanager_underreplicatedpartitions > 0
```

### Notification Policy 연결

**Alerting → Notification policies** → Root policy에 위에서 만든 Contact point 연결.

---

## 5. Portainer 초기 설정

**URL:** [http://34.50.39.161:9000](http://34.50.39.161:9000)

> 최초 기동 후 **5분 이내**에 admin 계정을 생성해야 합니다. 시간이 지나면 컨테이너를 재시작해야 합니다.

1. 접속 후 admin 비밀번호 설정
2. **Get Started** 클릭 → `local` 환경(monitoring VM Docker)이 자동으로 연결됨

---

## 6. Portainer — kafka/redis VM 연결

kafka/redis VM에는 `portainer-agent`가 포트 `9001`로 실행 중입니다. 아래 순서로 각 VM을 Portainer에 등록합니다.

**Environments → Add environment → Agent**

| VM | Agent URL |
|----|-----------|
| kafka-1 | `http://<KAFKA_1_INTERNAL_IP>:9001` |
| kafka-2 | `http://<KAFKA_2_INTERNAL_IP>:9001` |
| kafka-3 | `http://<KAFKA_3_INTERNAL_IP>:9001` |
| redis-1 | `http://<REDIS_1_INTERNAL_IP>:9001` |
| redis-2 | `http://<REDIS_2_INTERNAL_IP>:9001` |
| redis-3 | `http://<REDIS_3_INTERNAL_IP>:9001` |

등록 후 상단 환경 드롭다운에서 VM을 전환하며 각 VM의 컨테이너를 관리할 수 있습니다.

> **전제 조건:** monitoring VM → 각 VM의 포트 `9001`이 GCP 내부 방화벽에서 허용돼 있어야 합니다.

---

## 7. Portainer 주요 기능

### 컨테이너 상태 확인

**Containers** 탭 → 각 컨테이너의 상태(running/stopped), CPU/메모리 사용량 확인.

### 로그 확인

**Containers → 컨테이너 선택 → Logs**

- `kafka` 컨테이너 로그: 브로커 기동 오류, 파티션 재배치 이벤트 확인
- `sentinel` 컨테이너 로그: failover 이벤트 (`+switch-master` 메시지) 확인

### 컨테이너 재시작

**Containers → 컨테이너 선택 → Restart** (또는 상단 액션 버튼)

### 환경변수 확인

**Containers → 컨테이너 선택 → Inspect → Env** — 실행 중인 컨테이너의 환경변수 값 확인 (비밀번호는 마스킹 안 됨, 주의).

### 볼륨 확인

**Volumes** 탭 → `kafka-data`, `redis-data` 볼륨 크기 확인. 디스크 사용량이 많을 경우 Node Exporter 대시보드와 함께 점검합니다.