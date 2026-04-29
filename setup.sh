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
# ================================================

TARGET=${1:-all}

setup_vm() {
  local VM=$1
  local HOST_VAR="$(echo $VM | tr '[:lower:]' '[:upper:]')_VM_HOST"
  local HOST="${!HOST_VAR}"

  echo "🔧 $VM VM 세팅 중... ($HOST)"

  ssh $HOST << 'REMOTE'
    # Docker 설치
    if ! command -v docker &> /dev/null; then
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker $USER
      echo "✅ Docker 설치 완료"
    else
      echo "✅ Docker 이미 설치됨"
    fi

    # 레포 클론
    if [ ! -d ~/infra ]; then
      git clone https://github.com/goggle-edu/infra.git ~/infra
      echo "✅ 레포 클론 완료"
    else
      cd ~/infra && git pull
      echo "✅ 레포 최신화 완료"
    fi

    # .env 파일 존재 확인
    echo "⚠️  .env 파일을 직접 생성해주세요: ~/infra/$TARGET/.env"
REMOTE

  echo "✅ $VM VM 세팅 완료"
}

# SSH 호스트 설정 (환경변수로 관리)
KAFKA_1_VM_HOST=${KAFKA_1_VM_HOST:-"goggle-kafka-1"}
KAFKA_2_VM_HOST=${KAFKA_2_VM_HOST:-"goggle-kafka-2"}
KAFKA_3_VM_HOST=${KAFKA_3_VM_HOST:-"goggle-kafka-3"}
REDIS_VM_HOST=${REDIS_VM_HOST:-"goggle-redis"}
MONITORING_VM_HOST=${MONITORING_VM_HOST:-"goggle-monitoring"}

setup_kafka_cluster() {
  echo "🔧 Kafka 클러스터 세팅 중 (3노드)..."
  for i in 1 2 3; do
    local HOST_VAR="KAFKA_${i}_VM_HOST"
    local HOST="${!HOST_VAR}"
    echo "  - kafka-${i} ($HOST)"
    ssh $HOST << 'REMOTE'
      if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker $USER
      fi
      if [ ! -d ~/infra ]; then
        git clone https://github.com/goggle-edu/infra.git ~/infra
      else
        cd ~/infra && git pull
      fi
      echo "⚠️  .env 파일 생성 필요: ~/infra/kafka-vm/.env"
REMOTE
  done
  echo "✅ Kafka 클러스터 세팅 완료"
}

case $TARGET in
  kafka)      setup_kafka_cluster ;;
  redis)      setup_vm redis ;;
  monitoring) setup_vm monitoring ;;
  all)
    setup_kafka_cluster
    setup_vm redis
    setup_vm monitoring
    echo ""
    echo "🎉 전체 VM 세팅 완료!"
    echo "다음 단계: main 브랜치에 push하면 GitHub Actions가 자동 배포"
    ;;
  *)
    echo "사용법: ./setup.sh [kafka|redis|monitoring|all]"
    exit 1
    ;;
esac