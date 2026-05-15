#!/bin/bash
# ================================================
# VM 최초 세팅 스크립트
# 새 VM 만들고 이것만 실행하면 끝
#
# 사용법:
#   chmod +x setup.sh
#   ./setup.sh kafka    # Kafka VM 세팅
#   ./setup.sh redis    # Redis VM 세팅
#   ./setup.sh all      # 전체 VM 세팅
#
# 네트워크 구조:
#   외부 IP 보유: kafka-1 , redis-1
#   내부 IP 전용: kafka-2/3, redis-2/3 → ProxyJump 경유 접속
# ================================================

TARGET=${1:-all}

# SSH 호스트 설정
SSH_USER=${SSH_USER:-"$(whoami)"}
KAFKA_1_VM_HOST=${KAFKA_1_VM_HOST:?필수: kafka-1 외부 IP (예: KAFKA_1_VM_HOST=x.x.x.x ./setup.sh)}
KAFKA_2_VM_HOST=${KAFKA_2_VM_HOST:?필수: kafka-2 내부 IP}
KAFKA_3_VM_HOST=${KAFKA_3_VM_HOST:?필수: kafka-3 내부 IP}
REDIS_1_VM_HOST=${REDIS_1_VM_HOST:?필수: redis-1 외부 IP}
REDIS_2_VM_HOST=${REDIS_2_VM_HOST:?필수: redis-2 내부 IP}
REDIS_3_VM_HOST=${REDIS_3_VM_HOST:?필수: redis-3 내부 IP}
MONITORING_VM_HOST=${MONITORING_VM_HOST:-"goggle-monitoring"}

REMOTE_SETUP='
  if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
    echo "✅ Docker 설치 완료"
  else
    echo "✅ Docker 이미 설치됨"
  fi
  if [ ! -d ~/infra ]; then
    git clone https://github.com/goggle-edu/infra.git ~/infra
    echo "✅ 레포 클론 완료"
  else
    cd ~/infra && git pull
    echo "✅ 레포 최신화 완료"
  fi
'

setup_vm() {
  local NAME=$1
  local HOST=$2
  local JUMP=$3

  echo "🔧 $NAME VM 세팅 중... ($HOST)"
  if [ -n "$JUMP" ]; then
    ssh -J ${SSH_USER}@${JUMP} ${SSH_USER}@${HOST} "$REMOTE_SETUP"
    echo "⚠️  .env 파일을 직접 생성해주세요: ~/infra/$TARGET/.env"
  else
    ssh ${SSH_USER}@${HOST} "$REMOTE_SETUP"
    echo "⚠️  .env 파일을 직접 생성해주세요: ~/infra/$TARGET/.env"
  fi
  echo "✅ $NAME VM 세팅 완료"
}

setup_kafka_cluster() {
  echo "🔧 Kafka 클러스터 세팅 중 (3노드)..."
  setup_vm "kafka-1" "$KAFKA_1_VM_HOST"
  setup_vm "kafka-2" "$KAFKA_2_VM_HOST" "$KAFKA_1_VM_HOST"
  setup_vm "kafka-3" "$KAFKA_3_VM_HOST" "$KAFKA_1_VM_HOST"
  echo "✅ Kafka 클러스터 세팅 완료"
}

setup_redis_cluster() {
  echo "🔧 Redis 클러스터 세팅 중 (3노드)..."
  setup_vm "redis-1" "$REDIS_1_VM_HOST"
  setup_vm "redis-2" "$REDIS_2_VM_HOST" "$REDIS_1_VM_HOST"
  setup_vm "redis-3" "$REDIS_3_VM_HOST" "$REDIS_1_VM_HOST"
  echo "✅ Redis 클러스터 세팅 완료"
}

case $TARGET in
  kafka)      setup_kafka_cluster ;;
  redis)      setup_redis_cluster ;;
  monitoring) setup_vm monitoring "$MONITORING_VM_HOST" ;;
  all)
    setup_kafka_cluster
    setup_redis_cluster
    setup_vm monitoring "$MONITORING_VM_HOST"
    echo ""
    echo "🎉 전체 VM 세팅 완료!"
    echo "다음 단계: main 브랜치에 push하면 GitHub Actions가 자동 배포"
    ;;
  *)
    echo "사용법: ./setup.sh [kafka|redis|monitoring|all]"
    exit 1
    ;;
esac
