# Redis Sentinel 高可用集群部署指南（双机部署）

本项目提供了基于Docker的Redis Sentinel高可用集群部署方案，适用于两台物理机的场景。通过合理分配Sentinel节点位置和设置Quorum值，确保在主节点所在机器故障时能够可靠地进行故障转移。

## 架构说明

### 节点分布
- 机器A（Master节点机器）：
  - 1个Redis Master节点（Redis 7.4.3）
  - 2个Sentinel节点（优化分布，增强可靠性）
- 机器B（Replica节点机器）：
  - 1个Redis Replica节点
  - 2个Sentinel节点

### 网络规划
- 机器A：
  - Redis端口：6379
  - Sentinel端口：26379, 26380
- 机器B：
  - Redis端口：6379
  - Sentinel端口：26379, 26380

### 安全特性
- Redis密码认证
- protected-mode开启
- 内网部署，隔离外部访问
- 脚本中增加了密码强度检查
- 健康检查确保服务正常

### 高可用特性
- 4个Sentinel节点均衡分布在两台机器上
- Quorum值设置为2，确保多数决策
- 任一台机器故障时，仍有2个Sentinel节点正常运行
- 完善的故障检测与恢复机制

## 环境要求

- Docker Engine (版本 17.06.0 或更高)
- Docker Compose (支持V1或V2版本)
  * Docker Compose V1: `docker-compose` 命令 (1.18.0 或更高)
  * Docker Compose V2: `docker compose` 命令
- Redis镜像（需提前下载到本地）：redis:7.4.3
- 两台物理机之间可以通过内网互相访问

## 快速部署

### 1. 准备工作

#### 1.1 Docker和Docker Compose
确保两台机器已安装Docker和Docker Compose：
```bash
# 检查Docker版本
docker --version  # 需要 17.06.0 或更高版本

# 检查Docker Compose版本
# V1版本
docker-compose --version  # 需要 1.18.0 或更高版本
# 或V2版本
docker compose version
```

#### 1.2 Redis镜像准备
对于有外网环境的服务器，可以直接拉取镜像：
```bash
docker pull redis:7.4.3
```

对于离线环境，需要提前准备好镜像：
```bash
# 在有网络的环境中拉取并保存镜像
docker pull redis:7.4.3
docker save -o redis-7.4.3.tar redis:7.4.3

# 将镜像文件传输到目标服务器
# 然后在目标服务器上加载镜像
docker load -i redis-7.4.3.tar
```

将`redis-7.4.3.tar`文件放在部署脚本的同级目录，脚本会自动检测并加载。

### 2. 下载部署脚本和配置文件
将项目文件夹复制到两台机器上，包含以下关键文件：
- `deploy_master.sh`：机器A的部署脚本
- `deploy_replica.sh`：机器B的部署脚本

### 3. 部署过程

#### 3.1 在机器A（Master节点）上部署
```bash
# 执行部署脚本，提供本机IP、对端机器IP和Redis密码
./deploy_master.sh <机器A_IP> <机器B_IP> "<Redis密码>"

# 例如：
./deploy_master.sh 192.168.1.100 192.168.1.101 "StrongPassword123"
```

> 注意：密码应该使用引号括起来，特别是包含特殊字符时

#### 3.2 在机器B（Replica节点）上部署
```bash
# 执行部署脚本，提供本机IP、对端机器IP和Redis密码
./deploy_replica.sh <机器B_IP> <机器A_IP> "<Redis密码>"

# 例如：
./deploy_replica.sh 192.168.1.101 192.168.1.100 "StrongPassword123"
```

### 4. 验证部署

脚本执行过程中会自动进行健康检查。如果需要手动验证：

1. 验证主从复制状态：
   ```bash
   # 在机器A上执行
   docker exec redis-master redis-cli -h <机器A_IP> -a "<Redis密码>" info replication

   # 在机器B上执行
   docker exec redis-replica redis-cli -h <机器B_IP> -a "<Redis密码>" info replication
   ```

2. 验证Sentinel状态：
   ```bash
   # 在机器A上执行 - 检查两个Sentinel
   docker exec redis-sentinel-1 redis-cli -h <机器A_IP> -p 26379 info sentinel
   docker exec redis-sentinel-4 redis-cli -h <机器A_IP> -p 26380 info sentinel

   # 在机器B上执行 - 检查两个Sentinel
   docker exec redis-sentinel-2 redis-cli -h <机器B_IP> -p 26379 info sentinel
   docker exec redis-sentinel-3 redis-cli -h <机器B_IP> -p 26380 info sentinel
   ```

## 故障转移测试

### 模拟机器A故障
1. 停止机器A上的所有服务：
   ```bash
   cd /opt/redis-sentinel/machine-a
   docker compose down  # V2版本
   # 或者
   docker-compose down  # V1版本
   ```

2. 在机器B上观察故障转移过程：
   ```bash
   # 监控Sentinel状态
   docker exec redis-sentinel-2 redis-cli -h <机器B_IP> -p 26379 info sentinel

   # 检查Redis角色变化
   docker exec redis-replica redis-cli -h <机器B_IP> -a "<Redis密码>" info replication
   ```

3. 预期结果：
   - 机器B的Redis节点应该从Replica角色转变为Master角色
   - 所有Sentinel节点应该识别新的Master节点

### 恢复机器A并重新加入集群
1. 在机器A上重新启动服务：
   ```bash
   cd /opt/redis-sentinel/machine-a
   docker compose up -d  # V2版本
   # 或者
   docker-compose up -d  # V1版本
   ```

2. 验证机器A的Redis节点现在是以Replica角色加入集群：
   ```bash
   docker exec redis-master redis-cli -h <机器A_IP> -a "<Redis密码>" info replication
   ```

### 测试机器B故障
1. 停止机器B上的所有服务：
   ```bash
   cd /opt/redis-sentinel/machine-b
   docker compose down  # V2版本
   # 或者
   docker-compose down  # V1版本
   ```

2. 在机器A上验证Sentinel状态：
   ```bash
   docker exec redis-sentinel-1 redis-cli -h <机器A_IP> -p 26379 info sentinel
   docker exec redis-sentinel-4 redis-cli -h <机器A_IP> -p 26380 info sentinel
   ```

3. 确认机器A的Redis节点保持为Master角色。

## 技术细节

### 关键配置说明

1. **Sentinel分布与Quorum设置**：
   - 每台机器上都部署了2个Sentinel节点，总共4个
   - Quorum设置为2，确保在任一机器故障时仍能正常决策
   - 避免Sentinel单点故障问题

2. **网络模式**：
   - 使用host网络模式部署，避免Docker网络隔离问题
   - 确保容器可以直接使用主机网络接口

3. **持久化设置**：
   - 启用AOF持久化，确保数据可靠性
   - 数据保存在主机的数据目录中

4. **安全配置**：
   - 启用Redis密码认证（requirepass和masterauth）
   - Sentinel节点配置相应的认证密码（sentinel auth-pass）
   - 启用protected-mode保护模式
   - 部署脚本增加密码强度检查

5. **健康检查**：
   - Docker容器配置了健康检查，确保服务可用性
   - 脚本自动验证Redis和Sentinel状态

## 注意事项

1. **网络配置**：
   - 确保两台机器间的网络稳定可靠
   - 检查防火墙设置，确保Redis和Sentinel端口互通

2. **数据安全**：
   - 建议使用强密码，避免弱密码
   - 密码应包含大小写字母、数字和特殊字符，长度不少于12位
   - 考虑定期更换密码
   - 配置防火墙限制只允许内网访问

3. **监控建议**：
   - 建议配置外部监控系统监控Redis集群状态
   - 关注Sentinel日志以了解故障转移情况

## 维护命令速查

```bash
# 查看复制状态
docker exec -it redis-master redis-cli -h <机器A_IP> -a "<Redis密码>" info replication
docker exec -it redis-replica redis-cli -h <机器B_IP> -a "<Redis密码>" info replication

# 查看Sentinel状态
docker exec -it redis-sentinel-1 redis-cli -h <机器A_IP> -p 26379 info sentinel

# 手动触发故障转移（测试用）
docker exec -it redis-sentinel-1 redis-cli -h <机器A_IP> -p 26379 sentinel failover mymaster

# 查看容器日志
docker logs redis-master
docker logs redis-replica
docker logs redis-sentinel-1
```

## 故障排查

如果在使用过程中遇到Sentinel监控问题，可以尝试以下方法：

1. **检查Sentinel日志**：
   ```bash
   docker logs redis-sentinel-1 | tail -50
   ```

2. **重置Sentinel状态**：
   ```bash
   redis-cli -h <机器A_IP> -p 26379 SENTINEL RESET mymaster
   ```

3. **手动触发故障转移**：
   ```bash
   redis-cli -h <机器A_IP> -p 26379 SENTINEL FAILOVER mymaster
   ```

4. **验证所有Sentinel状态**：
   ```bash
   # 执行此命令检查所有Sentinel节点是否一致
   for port in 26379 26380; do
     echo "== Checking Sentinel on port $port =="
     redis-cli -h <机器A_IP> -p $port SENTINEL masters
   done

   for port in 26379 26380; do
     echo "== Checking Sentinel on port $port =="
     redis-cli -h <机器B_IP> -p $port SENTINEL masters
   done
   ```
   ##