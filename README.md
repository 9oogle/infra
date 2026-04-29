# 고글에듀 인프라

## 전체 구조

```
                     ┌─────────────────────────────────────────┐
                     │            Monitoring VM                 │
                     │   Prometheus :9090  Grafana :3000        │
                     │   Zipkin :9411                           │
                     └────────┬────────────────────┬───────────┘
                              │ scrape              │ scrape
          ┌───────────────────┼─────────────────────┼──────────────────────┐
          │                   │                     │                      │
 ┌────────▼────────┐ ┌────────▼────────┐  ┌────────▼────────┐  ┌──────────▼──────┐
 │  kafka-1 (ui)   │ │    kafka-2      │  │    kafka-3      │  │   redis-1 (master)│
 │  Kafka  :9092   │ │  Kafka  :9092   │  │  Kafka  :9092   │  │  Redis  :6379     │
 │  Exporter:9308  │ │  Exporter:9308  │  │  Exporter:9308  │  │  Exporter:9121    │
 │  kafka-ui:8989  │ │  Node   :9100   │  │  Node   :9100   │  │  Sentinel:26379   │
 │  Node   :9100   │ └─────────────────┘  └─────────────────┘  └──────────────────┘
 └─────────────────┘                                             ┌──────────────────┐
                                                                 │  redis-2 (replica)│
                                                                 │  Redis  :6379     │
                                                                 │  Exporter:9121    │
                                                                 │  Sentinel:26379   │
                                                                 └──────────────────┘
                                                                 ┌──────────────────┐
                                                                 │  redis-3 (replica)│
                                                                 │  Redis  :6379     │
                                                                 │  Exporter:9121    │
                                                                 │  Sentinel:26379   │
                                                                 └──────────────────┘
```

## GCP VM 스펙

| VM | 타입 | 스펙 | 월 비용 (us-central1) |
|----|------|------|----------------------|
| kafka-1, 2, 3 | `e2-small` | 2vCPU, 2GB RAM | ~$13/대 |
| redis-1, 2, 3 | `e2-micro` | 2vCPU, 1GB RAM | ~$6/대 |
| monitoring | `e2-small` | 2vCPU, 2GB RAM | ~$13 |

---

## Kafka 클러스터 (KRaft, 3-node)

### 1. CLUSTER_ID 생성 (최초 1회)
```bash
docker run --rm confluentinc/cp-kafka:7.5.0 kafka-storage random-uuid
```

### 2. 각 VM에 .env 파일 생성
`kafka-vm/.env.example`을 복사해서 `.env`로 생성.

| VM | BROKER_ID | KAFKA_HOST |
|----|-----------|------------|
| kafka-1 | 1 | 이 VM의 내부 IP |
| kafka-2 | 2 | 이 VM의 내부 IP |
| kafka-3 | 3 | 이 VM의 내부 IP |

`KAFKA_1_HOST`, `KAFKA_2_HOST`, `KAFKA_3_HOST`는 3개 VM 모두 동일하게 설정.

### 3. 기동 순서
```bash
# kafka-1 먼저 (kafka-ui 포함)
make kafka-1-up

# 이후 2, 3
make kafka-2-up
make kafka-3-up
```

### 4. GCP 방화벽 규칙

kafka VM 간 통신을 위해 아래 포트를 **내부 네트워크**에 허용:

| 포트 | 용도 |
|------|------|
| 9092 | Kafka 클라이언트 연결 |
| 29093 | KRaft 컨트롤러 통신 (브로커 간) |
| 9308 | Kafka Exporter → Prometheus |
| 9100 | Node Exporter → Prometheus |

---

## Redis HA (Sentinel, 3-node)

### 1. 각 VM에 .env 파일 생성
`redis-vm/.env.example`을 복사해서 `.env`로 생성.

| VM | SENTINEL_HOST | ROLE |
|----|---------------|------|
| redis-1 | 이 VM의 내부 IP | master |
| redis-2 | 이 VM의 내부 IP | replica |
| redis-3 | 이 VM의 내부 IP | replica |

`REDIS_MASTER_HOST`는 3개 VM 모두 redis-1 내부 IP.

### 2. 기동 순서 (master 먼저)
```bash
make redis-1-up   # master + sentinel + exporter
make redis-2-up   # replica + sentinel + exporter
make redis-3-up   # replica + sentinel + exporter
```

### 3. Sentinel 동작 확인
```bash
# redis-1 VM에서
redis-cli -p 26379 sentinel master mymaster

# Failover 테스트
redis-cli -p 26379 sentinel failover mymaster
```

### 4. 애플리케이션 연결 설정 (Spring Boot)
```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes:
          - redis-1-내부IP:26379
          - redis-2-내부IP:26379
          - redis-3-내부IP:26379
      password: ${REDIS_PASSWORD}
```

### 5. GCP 방화벽 규칙

| 포트 | 용도 |
|------|------|
| 6379 | Redis 클라이언트 연결 |
| 26379 | Sentinel 통신 |
| 9121 | Redis Exporter → Prometheus |
| 9100 | Node Exporter → Prometheus |

---

## 모니터링 (Prometheus + Grafana)

### 1. .env 파일 생성
`monitering-vm/.env.example`을 복사해서 `.env`로 생성 후 IP 입력.

### 2. 기동
```bash
make monitoring-up
```
`prometheus-init` 컨테이너가 `.env`의 IP를 `prometheus.yml.tmpl`에 주입한 뒤 종료하고, Prometheus가 생성된 설정으로 시작됨.

### 3. IP 변경 시 Prometheus 재설정
```bash
# monitoring VM에서
cd ~/infra/monitering-vm
docker compose down
docker volume rm monitering-vm_prometheus-config
docker compose up -d
```

### 4. GCP 방화벽 규칙

Monitoring VM → 각 VM 에 아래 포트 **내부 네트워크** 인바운드 허용 필요:

| 대상 | 포트 |
|------|------|
| Kafka VM | 9308, 9100 |
| Redis VM | 9121, 9100 |

### 5. Grafana 초기 설정

1. `http://monitoring-VM-IP:3000` 접속 (admin / .env의 GRAFANA_PASSWORD)
2. **Connections → Data Sources → Add** → Prometheus 선택
   - URL: `http://prometheus:9090`
3. 추천 대시보드 Import (Dashboards → Import):

| 대상 | Dashboard ID |
|------|-------------|
| Kafka | 7589 |
| Redis | 763 |
| Node Exporter | 1860 |

### 6. 분산 추적 (Zipkin)

애플리케이션에서 Zipkin으로 트레이스를 전송하려면:

```yaml
# Spring Boot application.yml
management:
  tracing:
    sampling:
      probability: 1.0
  zipkin:
    tracing:
      endpoint: http://monitoring-VM-IP:9411/api/v2/spans
```

---

## Portainer (컨테이너 관리 UI)

Portainer Server가 monitoring VM에 함께 올라감. `make monitoring-up` 하면 자동 기동.

| 컴포넌트 | 위치 | 포트 |
|----------|------|------|
| Portainer | monitoring VM | `:9000` |

### 초기 설정

1. `http://34.50.39.161:9000` 접속
2. 최초 접속 시 admin 계정 생성 (5분 내 설정 필요)
3. **Get Started** → local Docker 환경 자동 연결됨

---

## GitHub Actions Secrets

Config Server / Service / Payment는 각 앱 레포에서 배포하므로 이 레포에는 불필요.

```
SSH_PRIVATE_KEY       # 모든 VM 접근용 SSH 개인키
KNOWN_HOSTS           # ssh-keyscan으로 생성한 known_hosts 내용

KAFKA_1_VM_HOST       # goggle-edu-deploy@34.50.50.68
KAFKA_2_VM_HOST       # goggle-edu-deploy@34.22.75.156
KAFKA_3_VM_HOST       # goggle-edu-deploy@34.50.11.167

REDIS_1_VM_HOST       # goggle-edu-deploy@34.47.126.116
REDIS_2_VM_HOST       # goggle-edu-deploy@34.22.66.206
REDIS_3_VM_HOST       # goggle-edu-deploy@34.64.211.243

MONITORING_VM_HOST    # goggle-edu-deploy@34.50.39.161

KAFKA_CLUSTER_ID      # kafka-storage random-uuid로 생성
REDIS_PASSWORD        # Redis 비밀번호
GRAFANA_PASSWORD      # Grafana 비밀번호
```

---

## 전체 배포

```bash
# SSH config 등록 후
make all-up

# 개별 배포
make kafka-up
make redis-up
make monitoring-up

# 상태 확인
make status

# 전체 동기화 후 재배포
make sync-and-up
```

---

## 최초 세팅 가이드

### 1단계: GitHub Secrets 등록

GitHub 레포 → Settings → Secrets and variables → Actions에 아래 값 등록.

| Secret | 설명 |
|--------|------|
| `SSH_PRIVATE_KEY` | VM 접근용 SSH 개인키 |
| `KNOWN_HOSTS` | `ssh-keyscan <VM IP들>` 출력값 |
| `KAFKA_1_VM_HOST` | `goggle-edu-deploy@34.50.50.68` |
| `KAFKA_2_VM_HOST` | `goggle-edu-deploy@34.22.75.156` |
| `KAFKA_3_VM_HOST` | `goggle-edu-deploy@34.50.11.167` |
| `REDIS_1_VM_HOST` | `goggle-edu-deploy@34.47.126.116` |
| `REDIS_2_VM_HOST` | `goggle-edu-deploy@34.22.66.206` |
| `REDIS_3_VM_HOST` | `goggle-edu-deploy@34.64.211.243` |
| `MONITORING_VM_HOST` | `goggle-edu-deploy@34.50.39.161` |
| `KAFKA_CLUSTER_ID` | `kafka-storage random-uuid` 로 생성한 값 |
| `REDIS_PASSWORD` | Redis 비밀번호 |
| `GRAFANA_PASSWORD` | Grafana 비밀번호 |

### 2단계: 각 VM 초기화

각 VM에 Docker 설치 및 레포 클론. 로컬에서 아래 명령어 실행:

```bash
./setup.sh kafka       # kafka-1, 2, 3 VM
./setup.sh redis       # redis-1, 2, 3 VM
./setup.sh monitoring  # monitoring VM
```

### 3단계: 배포

`main` 브랜치에 push하면 GitHub Actions가 변경된 VM만 자동으로 `.env` 생성 + 배포.

```bash
git push origin main
```

> 최초 배포 시 전체 파일가 변경된 것으로 감지되어 kafka, redis, monitoring 전부 배포됨.

### 4단계: 서비스 확인

| 서비스 | URL |
|--------|-----|
| Kafka UI | http://34.50.50.68:8989 |
| Redis Insight | http://34.47.126.116:8001 |
| Grafana | http://34.50.39.161:3000 |
| Prometheus | http://34.50.39.161:9090 |
| Zipkin | http://34.50.39.161:9411 |
| Portainer | http://34.50.39.161:9000 |

### Portainer에서 kafka/redis VM 연결

Portainer는 kafka, redis VM에도 agent가 떠 있어서 전체 VM을 한 곳에서 관리할 수 있음.

1. Portainer UI(`http://34.50.39.161:9000`) 접속
2. **Environments → Add environment → Agent** 선택
3. 각 VM agent URL 등록:

| VM | Agent URL |
|----|-----------|
| kafka-1 | `http://10.178.0.3:9001` |
| kafka-2 | `http://10.178.0.4:9001` |
| kafka-3 | `http://10.178.0.5:9001` |
| redis-1 | `http://10.178.0.8:9001` |
| redis-2 | `http://10.178.0.7:9001` |
| redis-3 | `http://10.178.0.9:9001` |