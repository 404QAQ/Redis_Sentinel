#!/bin/bash

# 检查参数
if [ "$#" -ne 3 ]; then
    echo "用法: $0 <本机IP> <对端机器IP> <Redis密码>"
    echo "示例: $0 192.168.1.100 192.168.1.101 StrongPassword123"
    exit 1
fi

MASTER_IP=$1
REPLICA_IP=$2
REDIS_PASSWORD=$3
DEPLOY_PATH="/opt/redis-sentinel/machine-a"

# 密码强度检查
if [ ${#REDIS_PASSWORD} -lt 8 ]; then
    echo "警告: Redis密码长度不足8位，建议使用更强的密码"
    read -p "是否继续? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "开始部署Redis Master节点..."
echo "本机IP (Master): $MASTER_IP"
echo "对端IP (Replica): $REPLICA_IP"
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
mkdir -p ${DEPLOY_PATH}/{config,data/master}

# 创建Redis主节点配置文件
cat > ${DEPLOY_PATH}/config/master.conf << EOF
port 6379
bind ${MASTER_IP}
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
replica-serve-stale-data yes
replica-read-only yes
min-replicas-to-write 1
min-replicas-max-lag 10

# 防脑裂配置
cluster-node-timeout 5000

# 其他配置
protected-mode yes
EOF

# 创建Sentinel1配置文件
cat > ${DEPLOY_PATH}/config/sentinel1.conf << EOF
port 26379
bind ${MASTER_IP}
daemonize no
pidfile /var/run/redis-sentinel-1.pid
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

# 创建Sentinel4配置文件
cat > ${DEPLOY_PATH}/config/sentinel4.conf << EOF
port 26380
bind ${MASTER_IP}
daemonize no
pidfile /var/run/redis-sentinel-4.pid
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
  redis-master:
    image: redis:7.4.3
    container_name: redis-master
    command: redis-server /usr/local/etc/redis/redis.conf
    volumes:
      - ./config/master.conf:/usr/local/etc/redis/redis.conf
      - ./data/master:/data
    network_mode: "host"
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "${MASTER_IP}", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 3s
      retries: 3

  sentinel1:
    image: redis:7.4.3
    container_name: redis-sentinel-1
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./config/sentinel1.conf:/usr/local/etc/redis/sentinel.conf
    network_mode: "host"
    restart: always
    depends_on:
      - redis-master
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "${MASTER_IP}", "-p", "26379", "info", "Sentinel"]
      interval: 5s
      timeout: 3s
      retries: 3
      
  sentinel4:
    image: redis:7.4.3
    container_name: redis-sentinel-4
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./config/sentinel4.conf:/usr/local/etc/redis/sentinel.conf
    network_mode: "host"
    restart: always
    depends_on:
      - redis-master
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "${MASTER_IP}", "-p", "26380", "info", "Sentinel"]
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

# 验证Redis Master状态
if ! docker exec redis-master redis-cli -h ${MASTER_IP} -a ${REDIS_PASSWORD} ping | grep -q "PONG"; then
    echo "警告: Redis Master未正常响应，请检查配置和日志"
    echo "查看日志: docker logs redis-master"
else
    echo "Redis Master运行正常"
fi

# 给Sentinel更多时间来发现和监控主节点
echo "等待Sentinel初始化并发现主节点..."
sleep 15

# 验证Sentinel状态
echo "检查Sentinel1状态..."
if docker exec redis-sentinel-1 redis-cli -h ${MASTER_IP} -p 26379 info Sentinel | grep -q "master0:name=mymaster"; then
    echo "Sentinel1监控正常"
else
    echo "警告: Sentinel1未正确监控Master"
    echo "正在显示Sentinel1日志以帮助诊断问题:"
    docker logs redis-sentinel-1 | tail -20
fi

echo "检查Sentinel4状态..."
if docker exec redis-sentinel-4 redis-cli -h ${MASTER_IP} -p 26380 info Sentinel | grep -q "master0:name=mymaster"; then
    echo "Sentinel4监控正常"
else
    echo "警告: Sentinel4未正确监控Master"
    echo "正在显示Sentinel4日志以帮助诊断问题:"
    docker logs redis-sentinel-4 | tail -20
fi

echo "部署完成！请在对端机器上部署Replica节点。"
echo "部署路径: ${DEPLOY_PATH}" 
echo ""
echo "请使用以下命令在对端机器上部署Replica节点："
echo "./deploy_replica.sh ${REPLICA_IP} ${MASTER_IP} \"${REDIS_PASSWORD}\""  # 引号保护密码

echo ""
echo "提示: 本机部署了2个Sentinel节点和1个Master节点"
echo "对端机器将部署2个Sentinel节点和1个Replica节点"
echo "总共4个Sentinel节点，Quorum值设置为2，能保证更好的高可用性" 