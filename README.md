# FLYTOex Network — 运维工具集

[![Platform](https://img.shields.io/badge/platform-Debian%2012%20%7C%20Ubuntu%2022%2B-lightgrey)](https://github.com/panwudi/flyto-network)
[![Version](https://img.shields.io/badge/version-3.0.0-blue)](https://github.com/panwudi/flyto-network)
[![Website](https://img.shields.io/badge/website-www.flytoex.com-orange)](https://www.flytoex.com)

多节点网络运维工具，支持中转节点、出口节点、全功能节点三种角色部署。提供 dialog TUI 交互界面，兼容纯文本降级模式。

---

## 节点角色

本工具将服务器分为三种角色，每种角色有不同的强制项和可选项：

| 角色 | 典型位置 | WireGuard | V2bX | WARP |
|------|---------|-----------|------|------|
| **中转节点** | 香港、新加坡等 | 客户端（可选） | 可选 | 可选 |
| **出口节点** | 美国、欧洲等 | 服务端（必须） | 不安装 | 可选 |
| **全功能节点** | 任意 | 不使用 | 可选 | 可选 |

### 强制执行项（所有角色）

- 禁用 IPv6（防止 IPv6 泄露）
- 禁用 systemd-resolved，锁定 `/etc/resolv.conf`（防 DNS 泄露）
- IPv4 优先（`/etc/gai.conf`）

### 按角色的额外强制项

- **出口节点**：强制开启 IPv4 转发（`net.ipv4.ip_forward=1`，WG 服务端转发必须）
- **中转节点启用 WG 时**：强制开启 IPv4 转发

---

## 网络架构

```
客户端
  │
  ▼
中转节点（香港）
  ├── [可选] WireGuard 客户端 → 出口节点（美国）→ 互联网
  ├── [可选] V2bX 代理节点
  └── [可选] WARP → Google / Gemini / OpenAI / Claude
             │
             └── source-based policy routing（回包走 eth0，出站走 wg0）

出口节点（美国）
  ├── WireGuard 服务端，接受中转节点连接
  └── NAT 转发至互联网
```

### Source-based policy routing（中转节点）

中转节点通过 Linux 内核路由严格分离两类流量：

| 流量类型 | 路径 | 说明 |
|---------|------|------|
| 客户端回包（SSH、VLESS 回包） | → `eth0`（原路返回） | 由 `ip rule pref 100 from <HK_PUB_IP> lookup eth0rt` 实现 |
| 代理发起的新连接 | → `wg0` → 出口节点 | `ip route replace default dev wg0` |

`wg0.conf` 中 `Table = off` 的原因：防止 `wg-quick up` 自动接管默认路由，导致 SSH 断开。所有路由规则由 `PostUp` 精确写入。

---

## 快速开始

### 在线安装（无需 git）

```bash
curl -fsSL https://raw.githubusercontent.com/panwudi/flyto-network/main/install.sh | sudo bash
```

安装脚本会：
1. 自动安装 `dialog`（TUI 交互库）
2. 下载并验证仓库文件完整性
3. 逐文件做 bash 语法检查
4. 启动 `flyto.sh` 主菜单

仅下载不启动：

```bash
curl -fsSL https://raw.githubusercontent.com/panwudi/flyto-network/main/install.sh | sudo bash -s -- --download-only
```

### 手动克隆

```bash
git clone https://github.com/panwudi/flyto-network.git
cd flyto-network
sudo bash flyto.sh
```

### 命令行直接指定角色

```bash
# 中转节点
sudo bash flyto.sh transit

# 出口节点
sudo bash flyto.sh exit-node

# 全功能节点
sudo bash flyto.sh standalone

# 强制纯文本模式（无 dialog）
sudo bash flyto.sh --no-dialog
```

---

## 目录结构

```
flyto-network/
├── flyto.sh                  # 统一入口（角色选择 + 主菜单）
├── Makefile                  # make check / make lint
├── lib/
│   ├── ui.sh                 # dialog TUI 封装（自动降级为纯文本）
│   ├── validate.sh           # 输入校验（IP / 密钥 / 端口格式）
│   ├── progress.sh           # 步骤进度追踪
│   └── error.sh              # 统一错误处理（trap ERR + 恢复建议）
├── modules/
│   ├── hk-setup.sh           # 中转节点部署（WG客户端可选 + V2bX可选）
│   ├── wg-server.sh          # 出口节点部署（WG服务端 + NAT）
│   └── warp.sh               # WARP 透明代理（可选）
├── scripts/
│   └── check.sh              # 仓库质量检查（语法 + shellcheck）
├── tools/
│   └── gen-secrets.sh        # secrets.enc 管理
├── docs/
│   ├── ARCHITECTURE.md
│   ├── RISK-AUDIT.md
│   └── DEVELOPMENT.md
├── secrets.enc               # AES-256-CBC 加密的面板配置
└── README.md
```

---

## 中转节点部署流程

### 全新安装

```
主菜单 → 部署新节点 → 中转节点 → 全新安装
```

部署向导共 6 步，每步完成后可选择继续 / 返回 / 退出：

```
步骤 1  基础系统配置
        安装依赖 · 禁用 IPv6 · 锁定 DNS · 启用 nftables
        （按需开启 IPv4 转发）

步骤 2  采集网络信息（自动探测，可手动覆盖，带格式校验）
        WAN 接口 · 默认网关 · 公网 IP

步骤 3  [可选] 是否配置 WireGuard 客户端？
        • 选"是"：输入出口节点公钥、Endpoint、隧道 IP（逐字段校验）
        • 选"否"：跳过，直接出站

步骤 4  （仅启用 WG 时）生成 wg0.conf + 启动 + 三项验证
        ① WG 握手时间 < 5 分钟
        ② 出口 IP 地区 = US
        ③ 回包路径 dev = eth0（WAN 接口）

步骤 5  [可选] 是否安装 V2bX？
        • 选"是"：安装 V2bX + 写入面板配置
          → 追问：是否注入 OpenAI/Claude 路由到 sing-box？（可选）
        • 选"否"：跳过

步骤 6  （仅 WG + V2bX 均启用时）部署面板 IP 监控（cron 每小时 :05）

可选    是否安装 WARP？（三种节点均为可选）
```

### 从备份恢复

```
主菜单 → 从备份恢复
```

粘贴备份块，脚本自动解析所有字段，缺失字段逐项提示补全。恢复模式会校验备份中的 IP 与当前机器是否一致，不一致时重新采集网络信息。

---

## 出口节点部署流程

```
主菜单 → 部署新节点 → 出口节点
```

```
步骤 1  基础系统（强制开启 IPv4 转发 + 禁用 IPv6 + 锁定 DNS）

步骤 2  生成 WG 密钥对 + 采集网络信息
        • 自动生成私钥/公钥
        • 设置监听端口（默认 51820）
        • 设置服务端隧道地址（如 10.0.0.1/24）
        • 探测/确认公网 IP

步骤 3  录入中转节点（Peer）信息
        • 支持多个中转节点
        • 每个 Peer：公钥 + 隧道 IP

步骤 4  生成 wg0.conf + NAT 规则 + 启动验证

步骤 5  输出 [Peer] 段（复制到中转节点使用）
```

部署完成后，脚本会输出以下 **[Peer] 段**，需复制到中转节点的 `wg0.conf`：

```ini
[Peer]
PublicKey = <出口节点公钥>
Endpoint = <出口节点公网IP>:<端口>
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

此信息同时保存于 `/etc/wg-server/server_info`（chmod 600）。

---

## WARP 可选功能

WARP 对三种节点均为可选。安装后提供两条分流通道：

| 流量类型 | 分流方式 |
|---------|---------|
| Google / Gemini | iptables + ipset 透明代理（TPROXY） |
| OpenAI / Claude | V2bX sing-box 路由 → WARP SOCKS5 |

**注意**：OpenAI/Claude 路由注入需要 V2bX 已安装，且在 V2bX 安装步骤中单独询问是否启用，默认不启用。

### WARP 管理命令

```bash
warp status         # 状态（含 Google 连通性）
warp test           # 8 层逐层诊断
warp start/stop/restart
warp ip             # 查看直连 IP 与 WARP IP
warp update         # 更新 Google IP 段
warp uninstall      # 完整卸载
```

---

## AI 路由注入（可选）

在 V2bX 安装步骤中，脚本会单独询问是否注入 OpenAI/Claude 域名路由：

```
是否注入 OpenAI/Claude 域名路由到 sing-box（需要 WARP 已安装或将安装）？[y/N]
```

- 默认 **N（不注入）**，选 Y 才启用
- 数据来源：MetaCubeX meta-rules-dat + v2fly domain-list-community
- 同步脚本：`/usr/local/bin/update-ai-warp-route.sh`（可手动刷新）

---

## 配置加密管理

面板 ApiHost 和 ApiKey 加密保存在 `secrets.enc`，使用 AES-256-CBC + PBKDF2（100000 次迭代）加密。

```bash
# 创建或更新 secrets.enc
sudo bash tools/gen-secrets.sh

# 清除解密缓存（下次运行重新输入口令）
sudo bash flyto.sh --clear-cache
```

**口令要求**：最少 8 位（v3 起从 4 位提高）。

缓存文件 `/etc/flyto/.secrets` 权限 600，仅 root 可读。

---

## 备份与恢复（中转节点）

### 备份

```bash
sudo bash flyto.sh backup
# 或主菜单 → 备份当前配置
```

输出示例：

```
########## BEGIN FLYTO BACKUP ##########
HK_PRIV_KEY=<私钥>
HK_PUB_KEY=<公钥>
HK_WG_ADDR=10.0.0.2/32
HK_WG_PEER_PUBKEY=<出口节点公钥>
HK_WG_ENDPOINT=1.2.3.4:51820
HK_WG_KEEPALIVE=25
US_WG_TUN_IP=10.0.0.1/32
HK_WAN_IF=eth0
HK_GW=5.6.7.1
HK_PUB_IP=5.6.7.8
V2BX_NODE_ID=123
########### END FLYTO BACKUP ###########
```

> ⚠️ `HK_PRIV_KEY` 极度敏感，请保存在本地加密存储（KeePass、1Password）中。

### 恢复

```bash
sudo bash flyto.sh restore
# 或主菜单 → 从备份恢复
```

粘贴备份块后，脚本会：
1. 自动解析所有字段
2. 校验格式，占位值字段提示手动补全
3. 对比当前机器 IP 与备份 IP，不一致时重新采集网络信息

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 12（推荐）；Ubuntu 22.04/24.04 |
| 架构 | x86\_64 / aarch64 |
| 权限 | root |
| 容器 | WARP 模块需要 `NET_ADMIN` capability |
| 依赖 | `curl`、`tar`、`bash`（安装脚本自动安装 `dialog`） |

---

## 日常运维

### WireGuard

```bash
wg show                         # 状态（含握手时间）
systemctl restart wg-quick@wg0  # 重启
journalctl -u wg-quick@wg0 -n 50
ip rule list                    # 策略路由规则
ip route show table eth0rt      # 回包路由表
```

### V2bX

```bash
v2bx status
v2bx restart
journalctl -u V2bX -f
tail -50 /etc/V2bX/error.log
```

### 面板 IP 监控（中转节点）

```bash
cat /etc/hk-setup/panel_ip               # 当前记录的面板 IP
/usr/local/bin/update-panel-route.sh     # 手动触发更新
tail -20 /var/log/update-panel-route.log # 查看日志
```

### 出口节点信息

```bash
cat /etc/wg-server/server_info           # 查看服务端 WG 信息（含私钥）
wg show                                  # 当前连接状态
```

---

## 故障排查

**SSH / 入站连接间歇断连**（中转节点）

原因通常是回包没走 `eth0`，source-based routing 失效：

```bash
ip rule list | grep eth0rt
ip route show table eth0rt
journalctl -u wg-quick@wg0 -n 30
```

**wg-quick up 后 SSH 立即断开**

原因是 `wg0.conf` 缺少 `Table = off`。通过 VNC/控制台登录后：

```bash
ip route replace default via <HK_GW> dev <HK_WAN_IF>  # 临时恢复
grep 'Table' /etc/wireguard/wg0.conf                   # 检查配置
sudo bash flyto.sh restore                              # 重新生成
```

**出口 IP 是中转节点 IP 而非出口节点 IP**

```bash
ip route show | grep default   # 应为 "default dev wg0"
wg show                        # 检查握手是否正常
```

**WARP 相关问题**

```bash
warp test     # 8 层逐层诊断
warp debug    # 原始日志 / 端口 / 规则
```

---

## 配置文件参考

| 路径 | 说明 |
|------|------|
| `/etc/flyto/.secrets` | 解密缓存（chmod 600） |
| `/etc/wireguard/wg0.conf` | WireGuard 配置（chmod 600） |
| `/etc/wg-server/server_info` | 出口节点 WG 信息（chmod 600） |
| `/etc/V2bX/config.json` | V2bX 主配置 |
| `/etc/V2bX/sing_origin.json` | sing-box 路由配置 |
| `/etc/hk-setup/wan_if` | 中转节点 WAN 接口 |
| `/etc/hk-setup/panel_ip` | 当前记录的面板 IP |
| `/etc/warp-google/env` | WARP 端口配置 |
| `/usr/local/bin/update-ai-warp-route.sh` | AI 路由同步脚本 |
| `/usr/local/bin/update-panel-route.sh` | 面板 IP 监控脚本 |

---

## 相关组件

- [zfl9/ipt2socks](https://github.com/zfl9/ipt2socks) — 透明 SOCKS5 转发
- [wyx2685/V2bX-script](https://github.com/wyx2685/V2bX-script) — V2bX 安装脚本
- [Cloudflare WARP](https://1.1.1.1/) — WARP 客户端

---

**FLYTOex Network · [www.flytoex.com](https://www.flytoex.com)**
