# Redis Sentinel集群使用指南 (Redis 7.4.3)

## 架构优势

### 4个Sentinel节点（当前部署方案）vs 2个Sentinel节点

本集群使用4个Sentinel节点（每台机器2个）并将Quorum设置为2，优势如下：

- **更可靠的故障检测**：需要至少2个Sentinel认为主节点故障才会触发故障转移，降低误判概率
- **更高的可用性**：任一台机器完全故障时，另一台机器上的2个Sentinel仍可达成决策
- **更好的网络分区容忍性**：能在网络分区情况下仍有可能在一个分区内形成多数决策
- **降低脑裂风险**：减少不同Sentinel组做出冲突决策的可能性
- **更强的容错能力**：系统可以容忍任意1个Sentinel节点失效而不影响故障转移决策

## 连接方式

### 1. 直接连接Redis（不推荐）

```bash
# 连接主节点（机器A）
redis-cli -h <机器A_IP> -p 6379 -a "<Redis密码>"

# 连接从节点（机器B）
redis-cli -h <机器B_IP> -p 6379 -a "<Redis密码>"
```

这种方式不推荐，因为：
- 无法感知主从切换
- 故障转移后需要手动修改连接地址
- 可能导致写入失败

### 2. 通过Sentinel连接（推荐）

```bash
# 连接任意一个Sentinel节点
redis-cli -h <机器A_IP> -p 26379
redis-cli -h <机器A_IP> -p 26380
redis-cli -h <机器B_IP> -p 26379
redis-cli -h <机器B_IP> -p 26380

# 获取当前主节点信息
sentinel get-master-addr-by-name mymaster
```

注意：Sentinel节点本身不需要密码认证，但通过Sentinel获取到的Redis主节点仍需要密码认证。

### 3. 使用Redis客户端库（强烈推荐）

#### Python示例（使用redis-py）

```python
from redis.sentinel import Sentinel
import time

# 配置Sentinel连接信息 - 包含全部4个Sentinel节点
sentinel = Sentinel([
    ('<机器A_IP>', 26379),
    ('<机器A_IP>', 26380),
    ('<机器B_IP>', 26379),
    ('<机器B_IP>', 26380)
], socket_timeout=0.1)

# 获取主节点连接，注意添加密码参数
master = sentinel.master_for('mymaster', socket_timeout=0.1, password='<Redis密码>')

# 获取从节点连接，注意添加密码参数
slave = sentinel.slave_for('mymaster', socket_timeout=0.1, password='<Redis密码>')

# 使用示例
try:
    # 写入操作（主节点）
    master.set('key', 'value')
    
    # 读取操作（从节点）
    value = slave.get('key')
    print(f"Read from slave: {value}")
except Exception as e:
    print(f"Error: {e}")
```

#### Java示例（使用Jedis）

```java
import redis.clients.jedis.JedisSentinelPool;
import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPoolConfig;
import java.util.HashSet;
import java.util.Set;

public class RedisSentinelExample {
    public static void main(String[] args) {
        // 配置Sentinel节点信息 - 包含全部4个Sentinel节点
        Set<String> sentinels = new HashSet<>();
        sentinels.add("<机器A_IP>:26379");
        sentinels.add("<机器A_IP>:26380");
        sentinels.add("<机器B_IP>:26379");
        sentinels.add("<机器B_IP>:26380");

        // 连接池配置
        JedisPoolConfig poolConfig = new JedisPoolConfig();
        poolConfig.setMaxTotal(10);
        poolConfig.setMaxIdle(5);
        poolConfig.setMinIdle(1);
        poolConfig.setTestOnBorrow(true);
        
        // 创建连接池，添加密码参数
        JedisSentinelPool pool = new JedisSentinelPool("mymaster", sentinels, poolConfig, 2000, "<Redis密码>", 0);

        try (Jedis jedis = pool.getResource()) {
            // 写入数据
            jedis.set("key", "value");
            
            // 读取数据
            String value = jedis.get("key");
            System.out.println("Read value: " + value);
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            pool.close();
        }
    }
}
```

#### Node.js示例（使用ioredis）

```javascript
const Redis = require('ioredis');

// 创建Sentinel客户端，添加密码配置 - 包含全部4个Sentinel节点
const redis = new Redis({
    sentinels: [
        { host: '<机器A_IP>', port: 26379 },
        { host: '<机器A_IP>', port: 26380 },
        { host: '<机器B_IP>', port: 26379 },
        { host: '<机器B_IP>', port: 26380 }
    ],
    name: 'mymaster',
    password: '<Redis密码>',  // 添加密码配置
    maxRetriesPerRequest: 3,  // 每个请求的最大重试次数
    connectTimeout: 10000,    // 连接超时时间 10秒
    retryStrategy(times) {    // 自定义重试策略
        const delay = Math.min(times * 100, 2000);
        return delay;
    }
});

// 监听事件 - 对故障转移进行处理
redis.on('error', (error) => {
    console.error('Redis连接错误:', error);
});
redis.on('connect', () => {
    console.log('Redis已连接');
});
redis.on('ready', () => {
    console.log('Redis准备就绪');
});
redis.on('+switch-master', (masterName, oldHost, oldPort, newHost, newPort) => {
    console.log(`故障转移发生: ${masterName} 从 ${oldHost}:${oldPort} 切换到 ${newHost}:${newPort}`);
    // 可以在这里执行故障转移后的业务逻辑
});

// 使用示例
async function example() {
    try {
        // 写入数据
        await redis.set('key', 'value');
        console.log('写入成功');

        // 读取数据
        const value = await redis.get('key');
        console.log('读取值:', value);
    } catch (error) {
        console.error('错误:', error);
    }
}

example();
```

#### Go示例（使用go-redis）

首先安装go-redis库：
```bash
go get github.com/redis/go-redis/v9
```

然后使用以下代码连接到Redis Sentinel集群：

```go
package main

import (
	"context"
	"fmt"
	"github.com/redis/go-redis/v9"
	"time"
)

func main() {
	// 定义Sentinel节点地址 - 包含全部4个Sentinel节点
	sentinelAddrs := []string{
		"<机器A_IP>:26379",
		"<机器A_IP>:26380",
		"<机器B_IP>:26379",
		"<机器B_IP>:26380",
	}

	// 创建Redis Sentinel客户端
	rdb := redis.NewFailoverClient(&redis.FailoverOptions{
		MasterName:    "mymaster",
		SentinelAddrs: sentinelAddrs,
		Password:      "<Redis密码>",      // Redis服务器密码
		DB:            0,                 // 默认DB
		DialTimeout:   5 * time.Second,   // 连接超时
		ReadTimeout:   3 * time.Second,   // 读取超时
		WriteTimeout:  3 * time.Second,   // 写入超时
		MaxRetries:    3,                 // 最大重试次数
	})

	// 使用context进行超时控制
	ctx := context.Background()
	
	// 关闭连接
	defer rdb.Close()

	// 使用示例
	// 写入数据
	err := rdb.Set(ctx, "key", "value", 0).Err()
	if err != nil {
		fmt.Printf("写入数据错误: %v\n", err)
		return
	}
	fmt.Println("写入成功")

	// 读取数据
	val, err := rdb.Get(ctx, "key").Result()
	if err != nil {
		fmt.Printf("读取数据错误: %v\n", err)
		return
	}
	fmt.Printf("读取结果: %s\n", val)

	// 使用管道批量操作示例
	pipe := rdb.Pipeline()
	for i := 0; i < 3; i++ {
		pipe.Set(ctx, fmt.Sprintf("key:%d", i), fmt.Sprintf("value:%d", i), 0)
	}
	_, err = pipe.Exec(ctx)
	if err != nil {
		fmt.Printf("管道操作错误: %v\n", err)
		return
	}
	fmt.Println("管道操作完成")
	
	// 错误处理与重试示例
	maxRetries := 3
	for attempt := 0; attempt < maxRetries; attempt++ {
		_, err := rdb.Get(ctx, "non-existent-key").Result()
		if err == redis.Nil {
			fmt.Println("键不存在")
			break
		} else if err != nil {
			fmt.Printf("尝试 %d: 错误 %v\n", attempt+1, err)
			time.Sleep(time.Duration(attempt+1) * 100 * time.Millisecond)
			continue
		}
		break
	}
}
```

Go语言的连接池管理是自动处理的，go-redis库会在内部维护连接池，无需手动管理连接的创建和释放。如果需要更精细的连接池控制，可以通过设置选项：

```go
// 连接池配置示例
rdb := redis.NewFailoverClient(&redis.FailoverOptions{
    MasterName:       "mymaster",
    SentinelAddrs:    sentinelAddrs,
    Password:         "<Redis密码>",
    PoolSize:         10,                // 连接池大小
    MinIdleConns:     2,                 // 最小空闲连接数
    MaxConnAge:       time.Hour,         // 连接最大生命周期
    PoolTimeout:      4 * time.Second,   // 连接池超时
    IdleTimeout:      5 * time.Minute,   // 空闲连接超时
    IdleCheckFrequency: time.Minute,     // 空闲连接检查频率
})
```

#### C#示例（使用StackExchange.Redis）

首先安装StackExchange.Redis包：
```
dotnet add package StackExchange.Redis
```

然后使用以下代码连接到Redis Sentinel集群：

```csharp
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using StackExchange.Redis;

namespace RedisSentinelExample
{
    class Program
    {
        static async Task Main(string[] args)
        {
            // 配置选项
            ConfigurationOptions configurationOptions = new ConfigurationOptions
            {
                ServiceName = "mymaster", // Sentinel服务名
                Password = "<Redis密码>",  // Redis密码
                AbortOnConnectFail = false, // 连接失败时不中止
                ConnectTimeout = 5000,     // 连接超时(ms)
                SyncTimeout = 3000,        // 同步操作超时(ms)
                ConnectRetry = 3,          // 连接重试次数
                TieBreaker = ""            // 禁用tie-breaking
            };

            // 添加所有Sentinel节点
            configurationOptions.EndPoints.Add("<机器A_IP>", 26379);
            configurationOptions.EndPoints.Add("<机器A_IP>", 26380);
            configurationOptions.EndPoints.Add("<机器B_IP>", 26379);
            configurationOptions.EndPoints.Add("<机器B_IP>", 26380);
            
            // 注册Sentinel监听
            configurationOptions.CommandMap = CommandMap.Sentinel;

            // 连接Sentinel
            ConnectionMultiplexer sentinelConnection = await ConnectionMultiplexer.ConnectAsync(configurationOptions);
            
            // 获取主节点信息
            IServer sentinelServer = sentinelConnection.GetServer(sentinelConnection.GetEndPoints()[0]);
            RedisResult sentinelResult = await sentinelServer.ExecuteAsync("SENTINEL", "get-master-addr-by-name", "mymaster");
            RedisValue[] masterInfo = (RedisValue[])sentinelResult;
            string masterHost = masterInfo[0];
            int masterPort = (int)masterInfo[1];

            // 连接到实际的Redis
            ConfigurationOptions redisConfig = new ConfigurationOptions
            {
                Password = "<Redis密码>",
                AbortOnConnectFail = false
            };
            redisConfig.EndPoints.Add(masterHost, masterPort);
            ConnectionMultiplexer redisConnection = await ConnectionMultiplexer.ConnectAsync(redisConfig);
            
            // 使用Redis进行操作
            IDatabase db = redisConnection.GetDatabase();
            
            try
            {
                // 写入数据
                bool setResult = await db.StringSetAsync("testKey", "Hello from C#");
                Console.WriteLine($"写入结果: {setResult}");
                
                // 读取数据
                string value = await db.StringGetAsync("testKey");
                Console.WriteLine($"读取值: {value}");
                
                // 当遇到主从切换时，需要关闭现有连接并重新连接
                redisConnection.ConnectionFailed += (sender, args) =>
                {
                    Console.WriteLine($"Redis连接失败: {args.Exception.Message}");
                    // 可以启动重新连接流程
                };
            }
            catch(Exception ex)
            {
                Console.WriteLine($"Redis操作错误: {ex.Message}");
            }
            finally
            {
                sentinelConnection.Dispose();
                redisConnection.Dispose();
            }
        }
    }
}
```

通过使用StackExchange.Redis库，您可以在C#/.NET应用中稳定地连接到Redis Sentinel集群。

## 故障转移处理策略

### 故障转移过程

当主节点发生故障时，Redis Sentinel会自动执行以下步骤：

1. **故障检测**：至少2个Sentinel节点检测到主节点不可用
2. **故障确认**：Sentinel之间互相确认主节点状态
3. **Leader选举**：Sentinel集群选举出一个Leader来执行故障转移
4. **从节点提升**：选择一个从节点提升为新的主节点
5. **配置更新**：更新其它从节点指向新的主节点
6. **客户端通知**：通知客户端主节点已更改

整个过程通常在5-30秒内完成，取决于网络状况和`down-after-milliseconds`配置。

### 客户端处理策略

在故障转移过程中，应用程序应当实现以下策略：

1. **自动重连**：
   - 使用支持Sentinel的客户端库
   - 配置合理的重试策略
   - 监听连接失败事件并自动恢复

2. **错误处理**：
   - 实现指数退避重试机制
   - 对暂时性错误进行宽容处理
   - 设置重试上限，避免无限重试

3. **操作冗余**：
   - 关键操作考虑实现幂等性
   - 维护操作日志，便于恢复
   - 对失败操作进行重放

4. **事务处理**：
   - 故障转移期间事务可能中断
   - 重要事务考虑使用乐观锁
   - 实现事务回滚机制

### 故障转移后的处理

当主节点恢复后会自动变为从节点，但有时可能需要手动干预：

1. **验证集群状态**：
   ```bash
   # 查询所有Sentinel节点了解集群状态
   for port in 26379 26380; do
     for ip in <机器A_IP> <机器B_IP>; do
       echo "=== 检查 $ip:$port ==="
       redis-cli -h $ip -p $port sentinel masters
     done
   done
   ```

2. **手动触发故障转移**（测试或紧急情况）：
   ```bash
   redis-cli -h <某Sentinel_IP> -p 26379 sentinel failover mymaster
   ```

3. **修复不一致状态**：
   ```bash
   # 如果发现Sentinel状态不一致，可以重置
   redis-cli -h <Sentinel_IP> -p 26379 sentinel reset mymaster
   ```

## 密码安全建议

使用Redis Sentinel集群时，为确保系统安全，请遵循以下密码最佳实践：

1. **强密码要求**：
   - 长度至少12个字符
   - 包含大小写字母、数字和特殊字符
   - 避免使用字典词汇或个人信息

2. **密码管理**：
   - 使用安全的方式存储密码，如环境变量或密钥管理系统
   - 避免在代码中硬编码密码
   - 定期更换密码

3. **命令行使用**：
   - 在命令行使用时，给密码添加引号，如：`-a "复杂密码!@#"`
   - 使用 `-a` 参数传递密码，而不是交互式输入（自动化脚本中）
   - 注意密码可能会在命令历史中记录

4. **程序中使用**：
   - 使用连接池配置，减少身份验证频率
   - 实现重试机制，处理认证失败的情况
   - 监控失败的认证尝试，可能表明密码泄露

## 使用建议

### 1. 读写分离

- 写操作始终发送到主节点
- 读操作可以发送到从节点
- 对数据一致性要求高的读操作应该发送到主节点
- 注意从节点数据可能有微秒级延迟

### 2. 错误处理

```python
# Python示例
def redis_operation_with_retry(func, max_retries=3):
    for attempt in range(max_retries):
        try:
            return func()
        except Exception as e:
            if attempt == max_retries - 1:
                raise
            time.sleep(0.1 * (attempt + 1))

# 使用示例
def set_value():
    return master.set('key', 'value')

redis_operation_with_retry(set_value)
```

### 3. 健康检查

```python
def check_redis_health():
    try:
        # 检查主节点
        master_info = sentinel.discover_master('mymaster')
        print(f"Master node: {master_info}")

        # 检查从节点
        slave_info = sentinel.discover_slaves('mymaster')
        print(f"Slave nodes: {slave_info}")

        # 检查全部Sentinel节点状态
        sentinel_hosts = [
            ('<机器A_IP>', 26379),
            ('<机器A_IP>', 26380),
            ('<机器B_IP>', 26379),
            ('<机器B_IP>', 26380)
        ]
        
        for host, port in sentinel_hosts:
            try:
                conn = redis.Redis(host=host, port=port)
                sentinel_info = conn.execute_command('SENTINEL', 'MASTER', 'mymaster')
                print(f"Sentinel {host}:{port} 状态正常，监控的主节点: {sentinel_info}")
            except Exception as e:
                print(f"Sentinel {host}:{port} 不可访问: {e}")
                
        return True
    except Exception as e:
        print(f"Health check failed: {e}")
        return False
```

### 4. 监控关键指标

```python
def monitor_redis_metrics():
    # 主节点指标
    master_info = master.info()
    print(f"Connected clients: {master_info['connected_clients']}")
    print(f"Used memory: {master_info['used_memory_human']}")
    print(f"Total commands processed: {master_info['total_commands_processed']}")

    # 复制状态
    repl_info = master.info('replication')
    print(f"Connected slaves: {repl_info['connected_slaves']}")
    
    # 监控延迟
    if 'connected_slaves' in repl_info and int(repl_info['connected_slaves']) > 0:
        for i in range(int(repl_info['connected_slaves'])):
            slave_key = f"slave{i}"
            if slave_key in repl_info:
                slave_data = repl_info[slave_key]
                lag = slave_data.get('lag', 'unknown')
                print(f"Slave {i} lag: {lag}")
                
    # 监控Sentinel状态
    for host, port in sentinel_hosts:
        try:
            conn = redis.Redis(host=host, port=port)
            sentinel_masters = conn.execute_command('SENTINEL', 'MASTERS')
            print(f"Sentinel {host}:{port} 正在监控 {len(sentinel_masters)} 个主节点")
        except Exception as e:
            print(f"Sentinel {host}:{port} 监控失败: {e}")
```

## 常见问题处理

### 1. 连接失败

检查以下几点：
- Sentinel节点是否可访问
- 防火墙配置是否正确
- 网络连接是否正常
- 是否配置了正确的protected-mode和bind设置

### 2. 写入失败

可能的原因：
- 连接到了从节点
- 主节点故障转移中
- 网络问题

解决方案：
- 确保使用Sentinel获取主节点
- 实现重试机制
- 监控主从状态

### 3. 数据一致性

注意事项：
- 从节点数据可能有延迟
- 故障转移过程中可能丢失少量数据
- 重要操作建议使用主节点

### 4. Sentinel无法正确识别主节点

可能的原因：
- Quorum设置不当
- 网络分区
- Sentinel配置不一致

解决方案：
- 检查所有Sentinel配置是否一致
- 确认网络连通性
- 手动重置Sentinel状态：`sentinel reset mymaster`

## 性能优化建议

1. 连接池配置：
```python
# Python示例
from redis.sentinel import SentinelConnectionPool
from redis import Redis

pool = SentinelConnectionPool(
    service_name='mymaster',
    sentinel_manager=sentinel,
    max_connections=100,
    socket_timeout=0.1
)
redis_client = Redis(connection_pool=pool)
```

2. 批量操作：
```python
# 使用管道批量操作
with master.pipeline() as pipe:
    for i in range(100):
        pipe.set(f'key:{i}', f'value:{i}')
    pipe.execute()
```

3. 合理的超时设置：
```python
# 设置合理的超时时间
sentinel = Sentinel([
    ('<机器A_IP>', 26379),
    ('<机器A_IP>', 26380),
    ('<机器B_IP>', 26379),
    ('<机器B_IP>', 26380)
], 
socket_timeout=0.1,          # 套接字超时
connection_timeout=0.1,      # 连接超时
master_socket_timeout=0.1    # 主节点操作超时
) 
```

4. 合理使用Redis 7.4.3新特性：
   - ACL权限控制增强
   - 函数计算功能
   - 流数据处理优化
   - 改进的内存使用效率