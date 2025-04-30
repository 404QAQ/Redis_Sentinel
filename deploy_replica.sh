#!/bin/bash

# 检查参数
if [ "$#" -ne 3 ]; then
    echo "用法: $0 <本机IP> <对端机器IP> <Redis密码>"
    echo "示例: $0 192.168.1.101 192.168.1.100 StrongPassword123"
    exit 1
fi

REPLICA_IP=$1
MASTER_IP=$2
REDIS_PASSWORD=$3
DEPLOY_PATH="/opt/redis-sentinel/machine-b"

# 密码强度检查
if [ ${#REDIS_PASSWORD} -lt 8 ]; then
    echo "警告: Redis密码长度不足8位，建议使用更强的密码"
    read -p "是否继续? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "开始部署Redis Replica节点和Sentinel节点..."
echo "本机IP (Replica): $REPLICA_IP"
echo "对端IP (Master): $MASTER_IP"
echo "Redis密码: ********" # 不显示实际密码

# 检测Docker Compose版本
if docker compose version &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
    echo "使用Docker Compose V2"
elif docker-compose --version &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
    echo "使用Docker Compose V1"
else
    echo "错误: 未找到Docker Compose，请先安装"
    exit 1
fi

# 创建必要的目录
mkdir -p ${DEPLOY_PATH}/{config,data/replica}

# 创建Redis从节点配置文件
cat > ${DEPLOY_PATH}/config/replica.conf << EOF
port 6379
bind ${REPLICA_IP}
daemonize no
pidfile /var/run/redis_6379.pid
logfile ""
dir /data

# 密码认证
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}

# 持久化配置
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# 主从复制配置
replicaof ${MASTER_IP} 6379
replica-serve-stale-data yes
replica-read-only yes

# 防脑裂配置
cluster-node-timeout 5000

# 其他配置
protected-mode yes
EOF

# 创建Sentinel2配置文件
cat > ${DEPLOY_PATH}/config/sentinel2.conf << EOF
port 26379
bind ${REPLICA_IP}
daemonize no
pidfile /var/run/redis-sentinel-2.pid
logfile ""
dir /tmp

# Sentinel配置
sentinel monitor mymaster ${MASTER_IP} 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel auth-pass mymaster ${REDIS_PASSWORD}

# 配置纪元持久化
sentinel config-epoch mymaster 1

protected-mode yes
EOF

# 创建Sentinel3配置文件
cat > ${DEPLOY_PATH}/config/sentinel3.conf << EOF
port 26380
bind ${REPLICA_IP}
daemonize no
pidfile /var/run/redis-sentinel-3.pid
logfile ""
dir /tmp

# Sentinel配置
sentinel monitor mymaster ${MASTER_IP} 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel auth-pass mymaster ${REDIS_PASSWORD}

# 配置纪元持久化
sentinel config-epoch mymaster 1

protected-mode yes
EOF

# 创建docker-compose文件
cat > ${DEPLOY_PATH}/docker-compose.yml << EOF
version: '3.7'

services:
  redis-replica:
    image: redis:7.4.3
    container_name: redis-replica
    command: redis-server /usr/local/etc/redis/redis.conf
    volumes:
      - ./config/replica.conf:/usr/local/etc/redis/redis.conf
      - ./data/replica:/data
    network_mode: "host"
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "${REPLICA_IP}", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 3s
      retries: 3

  sentinel2:
    image: redis:7.4.3
    container_name: redis-sentinel-2
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./config/sentinel2.conf:/usr/local/etc/redis/sentinel.conf
    network_mode: "host"
    restart: always
    depends_on:
      - redis-replica
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "${REPLICA_IP}", "-p", "26379", "info", "Sentinel"]
      interval: 5s
      timeout: 3s
      retries: 3

  sentinel3:
    image: redis:7.4.3
    container_name: redis-sentinel-3
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./config/sentinel3.conf:/usr/local/etc/redis/sentinel.conf
    network_mode: "host"
    restart: always
    depends_on:
      - redis-replica
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "${REPLICA_IP}", "-p", "26380", "info", "Sentinel"]
      interval: 5s
      timeout: 3s
      retries: 3
EOF

# 检查和准备Redis镜像
if [ -f "redis-7.4.3.tar" ] && ! docker images | grep -q "redis:7.4.3"; then
    echo "从本地文件加载Redis 7.4.3镜像..."
    docker load -i redis-7.4.3.tar
elif ! docker images | grep -q "redis:7.4.3"; then
    echo "未找到Redis 7.4.3镜像，尝试拉取..."
    if ! docker pull redis:7.4.3; then
        echo "错误: 无法拉取Redis 7.4.3镜像"
        echo "如果是离线环境，请确保已经提前准备好redis:7.4.3镜像"
        echo "可以使用以下命令导入预先准备的镜像："
        echo "docker load -i redis-7.4.3.tar"
        exit 1
    fi
fi

# 启动服务
cd ${DEPLOY_PATH}
${DOCKER_COMPOSE_CMD} down -v 2>/dev/null
${DOCKER_COMPOSE_CMD} up -d

# 等待服务启动并进行健康检查
echo "等待服务启动并进行健康检查..."
echo "这可能需要一些时间，请耐心等待..."
sleep 30  # 增加等待时间到30秒

# 验证Redis Replica状态
if ! docker exec redis-replica redis-cli -h ${REPLICA_IP} -a ${REDIS_PASSWORD} ping | grep -q "PONG"; then
    echo "警告: Redis Replica未正常响应，请检查配置和日志"
    echo "查看日志: docker logs redis-replica"
else
    echo "Redis Replica运行正常"
fi

# 验证主从复制状态
REPL_ROLE=$(docker exec redis-replica redis-cli -h ${REPLICA_IP} -a ${REDIS_PASSWORD} info replication | grep "role" | cut -d: -f2 | tr -d '[:space:]')
if [ "$REPL_ROLE" != "slave" ]; then
    echo "警告: Redis未正确配置为从节点，当前角色: $REPL_ROLE"
    echo "查看复制状态: docker exec redis-replica redis-cli -h ${REPLICA_IP} -a ${REDIS_PASSWORD} info replication"
else
    echo "Redis主从复制配置正常"
fi

# 给Sentinel更多时间来发现和监控主节点
echo "等待Sentinel初始化并发现主节点..."
sleep 15

# 验证Sentinel状态
echo "检查Sentinel2状态..."
if docker exec redis-sentinel-2 redis-cli -h ${REPLICA_IP} -p 26379 info Sentinel | grep -q "master0:name=mymaster"; then
    echo "Sentinel2监控正常"
else
    echo "警告: Sentinel2未正确监控Master"
    echo "正在显示Sentinel2日志以帮助诊断问题:"
    docker logs redis-sentinel-2 | tail -20
fi

echo "检查Sentinel3状态..."
if docker exec redis-sentinel-3 redis-cli -h ${REPLICA_IP} -p 26380 info Sentinel | grep -q "master0:name=mymaster"; then
    echo "Sentinel3监控正常"
else
    echo "警告: Sentinel3未正确监控Master"
    echo "正在显示Sentinel3日志以帮助诊断问题:"
    docker logs redis-sentinel-3 | tail -20
fi

echo "部署完成！Redis Sentinel高可用集群已设置。"
echo "部署路径: ${DEPLOY_PATH}"
echo ""
echo "提示: 本机部署了2个Sentinel节点和1个Replica节点"
echo "这些节点与机器A上的节点共同构成了具有4个Sentinel的高可用集群"
echo "Quorum值设置为2，确保系统能够在任一机器故障时正确进行故障转移"
echo ""
echo "建议测试故障转移场景:"
echo "1. 关闭机器A，验证Replica自动晋升为Master"
echo "2. 恢复机器A，验证机器A自动作为Slave加入集群"
echo "3. 关闭机器B，验证所有Sentinel能正确识别Master状态" 