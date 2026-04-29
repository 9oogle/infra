# 고글에듀 인프라

고글에듀 서비스들이 공유하는 Kafka, Redis, 모니터링 인프라의 구성과 연동 방법을 설명합니다.

## 서비스 연동 가이드

각 서비스 레포에서 인프라를 사용하려면 아래 가이드를 참고하세요.

| 가이드 | 내용 |
|--------|------|
| [Kafka / Redis 연결 설정](docs/kafka-redis-guide.md) | bootstrap-servers, Sentinel 연결, 환경변수 목록 |
| [Prometheus / Zipkin 연동](docs/service-monitoring-guide.md) | 메트릭 수집, 분산 추적 연결 방법 |
| [Grafana / Portainer 운영](docs/grafana-portainer-guide.md) | 대시보드 Import, Alert 설정, VM 관리 |

---

## 전체 구조

GCP 위에 7개 VM을 구성하였으며, 역할별로 Kafka 클러스터(3대), Redis 클러스터(3대), 모니터링(1대)으로 분리되어 있습니다.

```
                     ┌─────────────────────────────────────────┐
                     │            Monitoring VM                 │
                     │   Prometheus :9090  Grafana :3000        │
                     │   Zipkin :9411      Portainer :9000      │
                     └────────┬────────────────────┬───────────┘
                              │ scrape              │ scrape
          ┌───────────────────┼─────────────────────┼──────────────────────┐
          │                   │                     │                      │
 ┌────────▼────────┐ ┌────────▼────────┐  ┌────────▼────────┐  ┌──────────▼──────┐
 │  kafka-1 (ui)   │ │    kafka-2      │  │    kafka-3      │  │  redis-1 (master)│
 │  Kafka  :9092   │ │  Kafka  :9092   │  │  Kafka  :9092   │  │  Redis  :6379    │
 │  Exporter:9308  │ │  Exporter:9308  │  │  Exporter:9308  │  │  Exporter:9121   │
 │  kafka-ui:8989  │ │  Node   :9100   │  │  Node   :9100   │  │  Sentinel:26379  │
 │  Node   :9100   │ └─────────────────┘  └─────────────────┘  └──────────────────┘
 └─────────────────┘                                            ┌──────────────────┐
                                                                │  redis-2 (replica)│
                                                                │  Redis  :6379    │
                                                                │  Exporter:9121   │
                                                                │  Sentinel:26379  │
                                                                └──────────────────┘
                                                                ┌──────────────────┐
                                                                │  redis-3 (replica)│
                                                                │  Redis  :6379    │
                                                                │  Exporter:9121   │
                                                                │  Sentinel:26379  │
                                                                └──────────────────┘
```

### GCP VM 스펙

| VM | 타입 | 스펙 | 월 비용 (us-central1) |
|----|------|------|-----------------------|
| kafka-1, 2, 3 | `e2-small` | 2vCPU, 2GB RAM | ~$13/대 |
| redis-1, 2, 3 | `e2-micro` | 2vCPU, 1GB RAM | ~$6/대 |
| monitoring | `e2-small` | 2vCPU, 2GB RAM | ~$13 |

### 접속 URL

| 서비스 | URL | 용도 |
|--------|-----|------|
| Kafka UI | [바로가기](http://34.50.50.68:8989) | 토픽 / Consumer Group 관리 |
| Grafana | [바로가기](http://34.50.39.161:3000) | 메트릭 대시보드 |
| Prometheus | [바로가기](http://34.50.39.161:9090) | 메트릭 수집 및 쿼리 |
| Zipkin | [바로가기](http://34.50.39.161:9411) | 분산 추적 |
| Portainer | [바로가기](http://34.50.39.161:9000) | 컨테이너 관리 UI |

---

## Kafka 클러스터

### 구성

3개 브로커를 KRaft로 구성하였습니다. 각 브로커가 컨트롤러 역할을 겸하며, 쿼럼(과반수)으로 리더를 선출합니다. 브로커 1대 장애 시에도 클러스터가 정상 동작합니다.

| 항목 | 값 | 의미 |
|------|-----|------|
| Replication Factor | 3 | 모든 토픽의 데이터를 3개 브로커에 복제 |
| Min ISR | 2 | 최소 2개 복제본이 동기화되어야 쓰기 허용 |
| Auto Topic Creation | 활성화 | Producer가 처음 produce 시 자동 생성 |

### 서비스에서 연결하는 방법

```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS}
```

`KAFKA_BOOTSTRAP_SERVERS` 값: `<KAFKA_1_INTERNAL_IP>:9092,<KAFKA_2_INTERNAL_IP>:9092,<KAFKA_3_INTERNAL_IP>:9092`

> 세 브로커를 모두 나열하여 한 대가 다운되더라도 연결이 끊기지 않도록 합니다.
> producer/consumer 세부 설정은 [Kafka / Redis 연결 설정](docs/kafka-redis-guide.md)을 참고하세요.

### 인프라 배포

```bash
# CLUSTER_ID 생성 (최초 1회)
docker run --rm confluentinc/cp-kafka:7.5.0 kafka-storage random-uuid

# kafka-1 먼저 기동 (Kafka UI 포함), 이후 2, 3
make kafka-1-up
make kafka-2-up
make kafka-3-up
```

각 VM의 `.env`는 `kafka-vm/.env.example`을 복사해 작성합니다.

| VM | BROKER_ID | KAFKA_HOST |
|----|-----------|------------|
| kafka-1 | 1 | 해당 VM 내부 IP |
| kafka-2 | 2 | 해당 VM 내부 IP |
| kafka-3 | 3 | 해당 VM 내부 IP |

`KAFKA_1_HOST`, `KAFKA_2_HOST`, `KAFKA_3_HOST`는 3개 VM 모두 동일하게 설정합니다.

### GCP 방화벽 (내부 네트워크)

| 포트 | 용도 |
|------|------|
| 9092 | Kafka 클라이언트 연결 |
| 29093 | KRaft 컨트롤러 간 통신 |
| 9308 | Kafka Exporter → Prometheus |
| 9100 | Node Exporter → Prometheus |

---

## Redis HA

### 구성

master 1대 + replica 2대를 Sentinel로 감시하는 HA 구성입니다. master 장애 시 Sentinel 쿼럼(2/3)이 자동으로 failover를 결정하고 replica 중 하나를 master로 승격합니다. 애플리케이션은 Sentinel 주소만 알면 되며, failover 후에도 재시작 없이 새 master로 자동 전환됩니다.

| 항목 | 값 |
|------|-----|
| Master Name | `mymaster` |
| Sentinel 쿼럼 | 2/3 |
| 최대 메모리 | 256MB |
| Eviction 정책 | `allkeys-lru` |

### 서비스에서 연결하는 방법

```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes:
          - ${REDIS_SENTINEL_1}   # <REDIS_1_INTERNAL_IP>:26379
          - ${REDIS_SENTINEL_2}   # <REDIS_2_INTERNAL_IP>:26379
          - ${REDIS_SENTINEL_3}   # <REDIS_3_INTERNAL_IP>:26379
      password: ${REDIS_PASSWORD}
```

> Redis 포트(6379)가 아닌 Sentinel 포트 **26379**에 연결합니다.
> Lettuce pool 설정 등 세부 내용은 [Kafka / Redis 연결 설정](docs/kafka-redis-guide.md)을 참고하세요.

### 인프라 배포

```bash
# master를 먼저 기동해야 replica가 복제를 시작할 수 있습니다
make redis-1-up   # master + sentinel + exporter
make redis-2-up   # replica + sentinel + exporter
make redis-3-up   # replica + sentinel + exporter
```

각 VM의 `.env`는 `redis-vm/.env.example`을 복사해 작성합니다.

| VM | SENTINEL_HOST | ROLE |
|----|---------------|------|
| redis-1 | 해당 VM 내부 IP | master |
| redis-2 | 해당 VM 내부 IP | replica |
| redis-3 | 해당 VM 내부 IP | replica |

`REDIS_MASTER_HOST`는 3개 VM 모두 redis-1의 내부 IP로 동일하게 설정합니다.

### GCP 방화벽 (내부 네트워크)

| 포트 | 용도 |
|------|------|
| 6379 | Redis 클라이언트 연결 |
| 26379 | Sentinel 통신 |
| 9121 | Redis Exporter → Prometheus |
| 9100 | Node Exporter → Prometheus |

---

## 모니터링

### 구성

monitoring VM 1대에 Prometheus, Grafana, Zipkin, Portainer를 함께 운영합니다.

- **Prometheus**: Kafka Exporter(`:9308`), Redis Exporter(`:9121`), Node Exporter(`:9100`)를 15초 간격으로 수집합니다. IP는 `.env`로 주입되어 `prometheus.yml`이 컨테이너 기동 시 자동 생성됩니다.
- **Grafana**: Prometheus를 datasource로 연결하여 대시보드를 제공합니다.
- **Zipkin**: 각 서비스가 HTTP 트레이스를 전송하면 분산 추적을 시각화합니다.
- **Portainer**: monitoring VM과 kafka/redis VM의 컨테이너를 한 곳에서 관리합니다.

### 서비스에서 연결하는 방법

각 서비스의 `application-prod.yaml`에 아래 설정을 추가합니다.

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health, info, prometheus
  metrics:
    tags:
      application: ${spring.application.name}
  tracing:
    sampling:
      probability: 0.1
  zipkin:
    tracing:
      endpoint: http://<MONITORING_EXTERNAL_IP>:9411/api/v2/spans
```

> Prometheus가 서비스의 `/actuator/prometheus`를 수집하려면 `monitoring-vm/prometheus.yml.tmpl`에 scrape job을 추가해야 합니다.
> 전체 절차는 [Prometheus / Zipkin 연동](docs/service-monitoring-guide.md)을 참고하세요.

### 인프라 배포

```bash
make monitoring-up
```

`prometheus-init` 컨테이너가 `.env`의 IP를 `prometheus.yml.tmpl`에 주입한 뒤 종료하고, Prometheus가 생성된 설정으로 기동됩니다.

IP 변경 시 Prometheus volume을 초기화하고 재기동합니다.

```bash
cd ~/infra/monitoring-vm
docker compose down
docker volume rm monitoring-vm_prometheus-config
docker compose up -d
```

### GCP 방화벽 (내부 네트워크, monitoring VM → 각 VM 인바운드)

| 대상 | 포트 |
|------|------|
| Kafka VM | 9308, 9100 |
| Redis VM | 9121, 9100 |

---

## 인프라 최초 세팅

### 1단계: GitHub Secrets 등록

GitHub 레포 → Settings → Secrets and variables → Actions에 아래 값을 등록합니다.

| Secret | 설명 |
|--------|------|
| `SSH_PRIVATE_KEY` | VM 접근용 SSH 개인키 |
| `SSH_USER` | VM SSH 사용자명 |
| `KNOWN_HOSTS` | `ssh-keyscan <VM 외부 IP들>` 출력값 |
| `KAFKA_1_VM_HOST` | kafka-1 VM 외부 IP |
| `KAFKA_2_VM_HOST` | kafka-2 VM 외부 IP |
| `KAFKA_3_VM_HOST` | kafka-3 VM 외부 IP |
| `KAFKA_1_INTERNAL_IP` | kafka-1 VM 내부 IP |
| `KAFKA_2_INTERNAL_IP` | kafka-2 VM 내부 IP |
| `KAFKA_3_INTERNAL_IP` | kafka-3 VM 내부 IP |
| `REDIS_1_VM_HOST` | redis-1 VM 외부 IP |
| `REDIS_2_VM_HOST` | redis-2 VM 외부 IP |
| `REDIS_3_VM_HOST` | redis-3 VM 외부 IP |
| `REDIS_1_INTERNAL_IP` | redis-1 VM 내부 IP |
| `REDIS_2_INTERNAL_IP` | redis-2 VM 내부 IP |
| `REDIS_3_INTERNAL_IP` | redis-3 VM 내부 IP |
| `MONITORING_VM_HOST` | monitoring VM 외부 IP |
| `KAFKA_CLUSTER_ID` | `kafka-storage random-uuid`로 생성한 값 |
| `REDIS_PASSWORD` | Redis 비밀번호 |
| `GRAFANA_PASSWORD` | Grafana 비밀번호 |


### 2단계: 각 VM 초기화

각 VM에 Docker를 설치하고 레포를 클론합니다. 로컬에서 아래 명령어를 실행합니다.

```bash
./setup.sh kafka       # kafka-1, 2, 3 VM
./setup.sh redis       # redis-1, 2, 3 VM
./setup.sh monitoring  # monitoring VM
```

### 3단계: 배포

`main` 브랜치에 push하면 GitHub Actions가 변경된 VM만 자동으로 `.env` 생성 후 배포합니다.

```bash
git push origin main
```

> 최초 배포 시에는 모든 파일이 변경된 것으로 감지되어 kafka, redis, monitoring 전체가 배포됩니다.

이후 수동 배포가 필요한 경우:

```bash
make all-up        # 전체 배포
make kafka-up      # Kafka만
make redis-up      # Redis만
make monitoring-up # 모니터링만
make status        # 전체 상태 확인
make sync-and-up   # 파일 동기화 후 재배포
```