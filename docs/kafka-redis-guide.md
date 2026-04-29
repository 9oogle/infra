# Kafka / Redis 서비스 연결 가이드

Spring Boot 서비스에서 고글에듀 Kafka 클러스터(KRaft)와 Redis HA(Sentinel)에 연결하는 방법을 설명합니다.

---

## 목차

1. [Kafka 연결](#1-kafka-연결)
2. [Redis Sentinel 연결](#2-redis-sentinel-연결)
3. [환경변수 정리](#3-환경변수-정리)
4. [연결 검증](#4-연결-검증)

---

## 1. Kafka 연결

### 클러스터 스펙 요약

| 항목 | 값 |
|------|----|
| 브로커 수 | 3 (KRaft, 컨트롤러 겸임) |
| 기본 Replication Factor | 3 |
| Min ISR | 2 (브로커 1대 장애 허용) |
| 인증 | 없음 (PLAINTEXT) |
| Auto Topic Creation | 활성화 |

### application.yaml

```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS}
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
      acks: all                   # min.insync.replicas(2)와 맞춰 데이터 유실 방지
      retries: 3
      properties:
        enable.idempotence: true  # 중복 전송 방지 (acks=all 필요)
    consumer:
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      auto-offset-reset: earliest
      enable-auto-commit: false   # 수동 커밋 권장 (처리 후 commit)
      group-id: ${spring.application.name}
```

> `KAFKA_BOOTSTRAP_SERVERS`는 세 브로커 모두 나열합니다. 한 대가 다운돼도 연결 가능.

### KAFKA_BOOTSTRAP_SERVERS 값

```
# 서비스 VM의 환경변수 또는 Config Server에 설정
KAFKA_BOOTSTRAP_SERVERS=<KAFKA_1_INTERNAL_IP>:9092,<KAFKA_2_INTERNAL_IP>:9092,<KAFKA_3_INTERNAL_IP>:9092
```

> 내부 IP를 사용합니다. Kafka 브로커는 `KAFKA_ADVERTISED_LISTENERS`에 각 VM의 내부 IP(`${KAFKA_HOST}`)로 등록돼 있습니다.

### prod 프로파일 — kafka 설정 override

로컬에서는 Kafka 없이 동작할 수 있도록 `local` 프로파일에서 자동 설정을 exclude하고 있습니다 (mentoring-service 참고). prod 프로파일에는 별도 설정 없이 환경변수만 주입하면 됩니다.

```yaml
---
spring:
  config:
    activate:
      on-profile: prod

# KAFKA_BOOTSTRAP_SERVERS 환경변수 주입 → spring.kafka.bootstrap-servers에 자동 바인딩
```

### 토픽 생성

`KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"`로 설정돼 있어 처음 메시지를 produce하면 자동 생성됩니다. 파티션 수와 replication factor를 직접 제어하려면 Kafka UI에서 수동 생성을 권장합니다.

**Kafka UI:** [http://34.50.50.68:8989](http://34.50.50.68:8989)

1. **Topics → Add a Topic**
2. 이름, Partitions(권장: 3 이상), Replication Factor(3), Min ISR(2) 입력

### Consumer Group 모니터링

Kafka UI → **Consumer Groups** → group-id 선택 → **Lag** 수치 확인.
Lag이 지속적으로 쌓이면 consumer 처리 속도 문제입니다.

---

## 2. Redis Sentinel 연결

### 클러스터 스펙 요약

| 항목 | 값 |
|------|----|
| 구성 | master 1 + replica 2 |
| Sentinel 쿼럼 | 2/3 |
| Master Name | `mymaster` |
| 최대 메모리 | 256MB (VM당) |
| Eviction 정책 | `allkeys-lru` |
| 인증 | 비밀번호 필요 (`REDIS_PASSWORD`) |

### 의존성

```groovy
implementation 'org.springframework.boot:spring-boot-starter-data-redis'
```

Lettuce가 기본 클라이언트로 사용됩니다. Sentinel 모드를 지원합니다.

### application.yaml

```yaml
spring:
  data:
    redis:
      sentinel:
        master: mymaster
        nodes:
          - ${REDIS_SENTINEL_1}
          - ${REDIS_SENTINEL_2}
          - ${REDIS_SENTINEL_3}
      password: ${REDIS_PASSWORD}
      lettuce:
        pool:
          max-active: 8
          max-idle: 8
          min-idle: 2
          max-wait: 2000ms
```

### 환경변수 값

```
REDIS_SENTINEL_1=<REDIS_1_INTERNAL_IP>:26379
REDIS_SENTINEL_2=<REDIS_2_INTERNAL_IP>:26379
REDIS_SENTINEL_3=<REDIS_3_INTERNAL_IP>:26379
REDIS_PASSWORD=<REDIS_PASSWORD 시크릿>
```

> Sentinel 포트는 **26379** 입니다. Redis 포트(6379)와 혼동하지 않도록 주의하세요.

### Sentinel 동작 방식

평소에는 master(`redis-1`)에 read/write가 모두 향합니다. master가 5초 이상 응답하지 않으면 Sentinel 쿼럼(2/3)이 failover를 결정하고 replica 중 하나를 새 master로 승격합니다. Lettuce는 Sentinel을 통해 새 master 주소를 자동으로 갱신하므로 **애플리케이션 재시작 없이 자동 복구**됩니다.

### Lettuce connection pool 활성화

Spring Boot 3.x에서 Lettuce pool을 사용하려면 `commons-pool2` 의존성이 필요합니다:

```groovy
implementation 'org.apache.commons:commons-pool2'
```

### TTL 설정 예시 (RedisTemplate)

```java
redisTemplate.opsForValue().set(key, value, Duration.ofMinutes(30));
```

eviction 정책이 `allkeys-lru`이므로 메모리 한계(256MB)에 도달하면 TTL 미설정 키도 제거됩니다. 중요한 데이터는 별도 영속 저장소를 병행하세요.

---

## 3. 환경변수 정리

서비스 VM(또는 Config Server)에 주입해야 할 환경변수 전체 목록:

| 변수 | 예시 값 | 설명 |
|------|---------|------|
| `KAFKA_BOOTSTRAP_SERVERS` | `<KAFKA_1_INTERNAL_IP>:9092,<KAFKA_2_INTERNAL_IP>:9092,<KAFKA_3_INTERNAL_IP>:9092` | Kafka 3-node 내부 IP |
| `REDIS_SENTINEL_1` | `<REDIS_1_INTERNAL_IP>:26379` | redis-1 Sentinel |
| `REDIS_SENTINEL_2` | `<REDIS_2_INTERNAL_IP>:26379` | redis-2 Sentinel |
| `REDIS_SENTINEL_3` | `<REDIS_3_INTERNAL_IP>:26379` | redis-3 Sentinel |
| `REDIS_PASSWORD` | (GitHub Secrets) | Redis/Sentinel 공통 비밀번호 |
| `DB_USERNAME` | (GitHub Secrets) | PostgreSQL 사용자명 |
| `DB_PASSWORD` | (GitHub Secrets) | PostgreSQL 비밀번호 |

---

## 4. 연결 검증

### Kafka

서비스 기동 로그에서 아래 메시지가 보이면 정상:

```
[AdminClient clientId=...] Node ... disconnected  ← 최초 연결 시도
o.a.k.clients.producer.KafkaProducer    : [Producer ...] Instantiated an idempotent producer.
```

Kafka UI → **Brokers** → 3개 브로커 모두 `Online` 상태인지 확인.

### Redis

서비스 기동 로그에서 아래 메시지가 보이면 정상:

```
o.s.d.r.c.LettuceConnectionFactory : Resolved master mymaster:6379 ...
```

직접 연결 테스트:

```bash
# redis-1 VM에서
redis-cli -p 26379 -a <password> sentinel master mymaster
# role: master, ip, port 확인
```

### Sentinel Failover 테스트

```bash
# 의도적으로 failover 발생
redis-cli -p 26379 sentinel failover mymaster

# 새 master 확인
redis-cli -p 26379 sentinel master mymaster
```

애플리케이션이 재시작 없이 새 master로 자동 전환되면 HA 구성이 정상입니다.