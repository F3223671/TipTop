# TipTop

SaltStack 代码仓。提需求：开 Issue 或评论并 @gavinhaiyingsun。

## 运维巡检

`scripts/ops-check.sh` 是仅适用于 Linux 的轻量巡检脚本，纯 bash 实现，只依赖系统常见命令（awk、df、logger 等），不引入任何第三方依赖。它采集：

- CPU 使用率：默认对 `/proc/stat` 间隔 60 秒采样两次，计算区间均值；
- 内存使用率：根据 `/proc/meminfo` 的 `MemTotal` 与 `MemAvailable` 计算；
- 根分区磁盘使用率：`df -P /`；
- 1/5/15 分钟负载：`/proc/loadavg`；
- 指定的 systemd 服务是否 `active`（需要 systemctl 和运行中的 systemd；不满足时跳过并说明）；
- 指定的 TCP 端口是否监听（`ss` 或 `netstat`；两者都不可用时跳过该项并在报告中说明）。

默认在磁盘使用率 >85%、内存使用率 >90%、load1 > CPU 核数 × 2 时告警；阈值均可通过参数覆盖。告警同时写入 stderr 和 syslog（`logger -t ops-check`）。

### 用法

```bash
# 默认检查：等待 60 秒采样 CPU 后输出报告
./scripts/ops-check.sh

# 检查服务与端口，并覆盖阈值
./scripts/ops-check.sh --services "sshd nginx" --ports "22 80" \
  --disk-warn 80 --mem-warn 85 --load-factor 1.5

# 输出机器可读 JSON（stdout 为 JSON；告警仍走 stderr 和 syslog）
./scripts/ops-check.sh --json

# 缩短 CPU 采样间隔（便于手动调试）
./scripts/ops-check.sh --cpu-interval 5

./scripts/ops-check.sh --help
```

参数：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--json` | 向 stdout 输出 JSON | 关闭 |
| `--services "a b"` | 要求处于 active 的 systemd 服务，空格分隔 | 不检查 |
| `--ports "22 80"` | 要求监听的 TCP 端口，空格分隔 | 不检查 |
| `--disk-warn N` | 磁盘使用率告警阈值（百分比） | `85` |
| `--mem-warn N` | 内存使用率告警阈值（百分比） | `90` |
| `--load-factor N` | load1 超过 `N × CPU 核数` 时告警 | `2` |
| `--cpu-interval N` | CPU 两次采样的间隔秒数 | `60` |
| `-h`, `--help` | 显示帮助并退出 | - |

### crontab 示例

每小时执行一次；告警由脚本内置的 `logger -t ops-check` 写入 syslog，cron 不再重复投递 stderr：

```cron
0 * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /opt/TipTop/scripts/ops-check.sh --services "sshd nginx" --ports "22 80" >/var/log/ops-check.log 2>/dev/null
```

请将 `/opt/TipTop` 换成实际部署路径，并按需调整服务名和端口。`/var/log/ops-check.log` 保存常规巡检报告；如需保留 stderr（告警、执行错误），可将 `2>/dev/null` 改为 `2>>/var/log/ops-check.err`。

### 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 所有检查正常 |
| `1` | 存在告警（阈值超限、服务未 active、端口未监听） |
| `2` | 脚本自身执行错误（参数非法、缺少 `/proc`、采集命令失败等） |
