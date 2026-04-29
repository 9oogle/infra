# 서비스 모니터링 연동 가이드

각 Spring Boot 서비스에서 **Prometheus 메트릭**과 **Zipkin 분산 추적**을 연동하는 방법을 설명합니다.

---

## 목차

1. [의존성 추가](#1-의존성-추가)
2. [application.yaml 설정](#2-applicationyaml-설정)
3. [인프라 연동 — prometheus.yml.tmpl 수정](#3-인프라-연동--prometheusymltmpl-수정)
4. [인프라 연동 — monitoring-vm .env 수정](#4-인프라-연동--monitoring-vm-env-수정)
5. [GCP 방화벽 규칙 추가](#5-gcp-방화벽-규칙-추가)
6. [Grafana 대시보드 설정](#6-grafana-대시보드-설정)
7. [연동 검증](#7-연동-검증)

---

## 1. 의존성 추가

`build.gradle`에 아래 의존성을 추가합니다.

```groovy
// Prometheus 메트릭 수집
implementation 'io.micrometer:micrometer-registry-prometheus'

// 분산 추적 (Zipkin) — 이미 추가돼 있으면 생략
implementation 'io.micrometer:micrometer-tracing-bridge-brave'
implementation 'io.zipkin.reporter2:zipkin-reporter-brave'
```

> `spring-boot-starter-actuator`는 이미 포함돼 있어야 합니다. (`mentoring-service`는 포함되어 있음)

---

## 2. application.yaml 설정

### 2-1. 공통 설정 (프로파일 무관)

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health, info, prometheus   # /actuator/prometheus 노출
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: ${spring.application.name}   # Grafana에서 앱별 필터링에 사용
  tracing:
    sampling:
      probability: 1.0                          # 로컬 기본값 (local 프로파일에서 0.0으로 override)
  zipkin:
    tracing:
      endpoint: http://localhost:9411/api/v2/spans   # 기본값 (prod 프로파일에서 override)
```

### 2-2. local 프로파일

```yaml
---
spring:
  config:
    activate:
      on-profile: local

management:
  tracing:
    sampling:
      probability: 0.0   # 로컬에서는 트레이스 전송 안 함
```

### 2-3. prod 프로파일

```yaml
---
spring:
  config:
    activate:
      on-profile: prod

management:
  zipkin:
    tracing:
      endpoint: http://<MONITORING_EXTERNAL_IP>:9411/api/v2/spans   # 실제 Monitoring VM IP
  tracing:
    sampling:
      probability: 0.1   # 운영에서는 10% 샘플링 권장 (트래픽에 따라 조절)
```

> `<MONITORING_EXTERNAL_IP>`은 monitoring VM의 외부 IP입니다. Config Server에서 관리하는 경우 환경변수로 주입해도 됩니다.

### mentoring-service 적용 예시 (전체 yaml)

현재 `mentoring-service/src/main/resources/application.yaml`의 `management` 섹션을 아래와 같이 수정합니다.

**변경 전:**
```yaml
management:
  tracing:
    sampling:
      probability: 1.0
  zipkin:
    tracing:
      endpoint: http://localhost:9411/api/v2/spans
```

**변경 후:**
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health, info, prometheus
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: ${spring.application.name}
  tracing:
    sampling:
      probability: 1.0
  zipkin:
    tracing:
      endpoint: http://localhost:9411/api/v2/spans
```

그리고 `prod` 프로파일 블록에 추가:
```yaml
---
spring:
  config:
    activate:
      on-profile: prod

management:
  zipkin:
    tracing:
      endpoint: http://<MONITORING_EXTERNAL_IP>:9411/api/v2/spans
  tracing:
    sampling:
      probability: 0.1

eureka:
  client:
    register-with-eureka: true
    fetch-registry: true
```

---

## 3. 인프라 연동 — prometheus.yml.tmpl 수정

`monitoring-vm/prometheus.yml.tmpl`에 각 서비스의 scrape job을 추가합니다.

서비스가 배포되는 VM의 내부 IP와 포트를 사용합니다. 아래는 서비스 VM이 `SERVICE_VM_IP` 내부 IP에서 동작한다고 가정한 예시입니다.

```yaml
  # ── Spring Boot 서비스 메트릭 ─────────────────────
  - job_name: 'spring-services'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
          - '${MENTORING_SERVICE_HOST}:8081'
        labels:
          service: 'mentoring-service'
      # 서비스가 늘어날 때마다 아래에 추가
      # - targets:
      #     - '${ANOTHER_SERVICE_HOST}:8082'
      #   labels:
      #     service: 'another-service'
```

추가 후 전체 파일 구조 예시:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'kafka'
    static_configs:
      - targets:
          - '${KAFKA_1_HOST}:9308'
          - '${KAFKA_2_HOST}:9308'
          - '${KAFKA_3_HOST}:9308'
        labels:
          cluster: 'goggle-kafka'

  - job_name: 'redis'
    static_configs:
      - targets:
          - '${REDIS_1_HOST}:9121'
          - '${REDIS_2_HOST}:9121'
          - '${REDIS_3_HOST}:9121'
        labels:
          cluster: 'goggle-redis'

  - job_name: 'node-kafka'
    static_configs:
      - targets:
          - '${KAFKA_1_HOST}:9100'
          - '${KAFKA_2_HOST}:9100'
          - '${KAFKA_3_HOST}:9100'
        labels:
          group: 'kafka'

  - job_name: 'node-redis'
    static_configs:
      - targets:
          - '${REDIS_1_HOST}:9100'
          - '${REDIS_2_HOST}:9100'
          - '${REDIS_3_HOST}:9100'
        labels:
          group: 'redis'

  - job_name: 'spring-services'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
          - '${MENTORING_SERVICE_HOST}:8081'
        labels:
          service: 'mentoring-service'

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

---

## 4. 인프라 연동 — monitoring-vm .env 수정

`monitoring-vm/.env`에 서비스 VM의 내부 IP를 추가합니다.

```env
GRAFANA_PASSWORD=your-password

# Kafka VM 내부 IP
KAFKA_1_HOST=10.178.0.x
KAFKA_2_HOST=10.178.0.x
KAFKA_3_HOST=10.178.0.x

# Redis VM 내부 IP
REDIS_1_HOST=10.178.0.x
REDIS_2_HOST=10.178.0.x
REDIS_3_HOST=10.178.0.x

# Service VM 내부 IP  ← 추가
MENTORING_SERVICE_HOST=10.178.0.x
```

`.env` 수정 후 Prometheus를 재시작합니다:

```bash
# monitoring VM에서
cd ~/infra/monitoring-vm
docker compose down
docker volume rm monitoring-vm_prometheus-config
docker compose up -d
```

`prometheus-init` 컨테이너가 `.env` 값을 `prometheus.yml.tmpl`에 주입하고 새 설정으로 Prometheus가 뜹니다.

---

## 5. GCP 방화벽 규칙 추가

Prometheus(monitoring VM)가 서비스 VM의 Actuator 엔드포인트를 긁을 수 있도록 **내부 네트워크** 인바운드를 허용해야 합니다.

| 대상 VM | 허용 포트 | 용도 |
|---------|----------|------|
| 서비스 VM | `8081` (또는 해당 서비스 포트) | Prometheus → `/actuator/prometheus` |

> Zipkin은 서비스 → monitoring VM 방향 (아웃바운드)이므로 서비스 VM에서 `9411` 포트 아웃바운드를 허용합니다.
> 단, GCP 기본 정책상 아웃바운드는 모두 허용이므로 별도 설정 불필요한 경우가 대부분입니다.

GCP Console → VPC network → Firewall → Create rule:

```
Name: allow-actuator-from-monitoring
Direction: Ingress
Target: 서비스 VM 태그 (예: service-vm)
Source IP ranges: monitoring VM 내부 IP (예: 10.178.0.x/32)
Protocols/ports: TCP 8081
```

---

## 6. Grafana 대시보드 설정

[Grafana](http://34.50.39.161:3000) 접속 후 Prometheus data source가 연결돼 있어야 합니다 (README의 Grafana 초기 설정 참고).

### Spring Boot 대시보드 Import

**Dashboards → Import → ID 입력:**

| 대시보드 | ID | 설명 |
|----------|-----|------|
| JVM (Micrometer) | `4701` | Heap, GC, Thread, CPU 등 JVM 상세 메트릭 |
| Spring Boot Statistics | `6756` | HTTP 요청 처리량, 응답시간, 에러율 |

Import 후 **datasource**를 `Prometheus`로, **Application** 필터를 `mentoring-service` (또는 `${spring.application.name}`에 설정한 값)로 선택합니다.

### 주요 메트릭 쿼리 예시

Grafana에서 직접 쿼리할 때 참고:

```promql
# HTTP 요청 처리량 (RPS)
rate(http_server_requests_seconds_count{application="mentoring-service"}[1m])

# P95 응답시간
histogram_quantile(0.95, rate(http_server_requests_seconds_bucket{application="mentoring-service"}[5m]))

# 에러율 (5xx)
rate(http_server_requests_seconds_count{application="mentoring-service",status=~"5.."}[1m])

# JVM Heap 사용량
jvm_memory_used_bytes{application="mentoring-service",area="heap"}
```

---

## 7. 연동 검증

### Prometheus 메트릭 확인

서비스가 실행 중인 VM에서:

```bash
# 1. Actuator 엔드포인트 노출 확인
curl http://localhost:8081/actuator
# 응답에 "prometheus" 항목이 있어야 함

# 2. Prometheus 메트릭 노출 확인
curl http://localhost:8081/actuator/prometheus
# jvm_, http_server_requests_, process_ 등의 메트릭이 출력되어야 함
```

[Prometheus UI](http://34.50.39.161:9090)에서:

```
Status → Targets → spring-services 항목이 UP 상태여야 함
```

### Zipkin 트레이스 확인

서비스에 HTTP 요청을 보낸 뒤 [Zipkin UI](http://34.50.39.161:9411)에서:

1. **Find a trace** → Service Name에서 `mentoring-service` (또는 `spring.application.name` 값) 선택
2. **Run Query** → 트레이스 목록이 표시되면 연동 성공

> `probability: 0.1`로 설정한 경우 요청 10건 중 약 1건만 기록됩니다. 테스트 중에는 임시로 `1.0`으로 올려서 확인하세요.

### Grafana에서 확인

1. [Grafana](http://34.50.39.161:3000) 접속
2. **Explore** → datasource `Prometheus` → 아래 쿼리 실행:
   ```promql
   up{job="spring-services"}
   ```
   결과가 `1`이면 Prometheus가 서비스를 정상 수집 중입니다.