---
name: cloudflare-ops
description: Manage bill's Cloudflare estate (billq.cc) via API instead of the dashboard - add/remove tunnel public hostnames (内网穿透), DNS records, and Access email-whitelist applications, using the API token stored in 1Password. Use when the user wants to expose a local/LAN service to the internet, add a subdomain, configure Cloudflare Tunnel ingress, manage Zero Trust Access whitelists, or says things like '加个内网穿透', '给 xxx 配个域名', '开个白名单', '配置 cloudflare', 'expose this service', 'add tunnel hostname', 'cloudflare access policy'.
---

# cloudflare-ops · Cloudflare 隧道 / DNS / Access 白名单操作

用 API 完成 billq.cc 域下的常见 Cloudflare 操作,避免开浏览器点控制台。控制台 URL 路径经常变、页面加载慢,**优先走 API;只有 API 权限覆盖不到的操作(如创建新 Token)才回退到浏览器**。

## 凭证

```bash
CF_TOKEN=$(op read "op://Personal/Cloudflare API Token (claude-automation)/credential")
```

- Token 名 `claude-automation`,权限:**Access: Apps and Policies (Edit)**、**Cloudflare Tunnel (Edit)** — 账户级;**DNS (Edit)** — 仅 billq.cc。
- 权限外的操作(zone 设置、Workers、账单等)这个 Token 做不了,别硬试。
- **Token 明文不落盘、不回显到对话**;curl 里用变量引用。
- 兜底:本机 `~/.cloudflared/cert.pem` 是账户证书,可执行 `cloudflared tunnel route dns <tunnel-id> <hostname>` 创建隧道 DNS 路由(不能管 Access)。

## 环境事实(2026-08 快照,变更后请更新本节)

| 项 | 值 |
|---|---|
| 账户 ID | `615eeb815d72cee51fdd879085bc54d2` |
| Zone | `billq.cc`(唯一 zone) |
| Zero Trust 团队域 | `billq.cloudflareaccess.com` |
| API 基地址 | `https://api.cloudflare.com/client/v4` |

**隧道(重点:都是本地管理 locally-managed,ingress 以机器上的 config.yml 为准,API 的 configurations 端点改不动!)**

| 隧道 | ID | 跑在哪 | ingress 配置 |
|---|---|---|---|
| Air 隧道 | `8e17712a-110c-4f26-be28-1c8f42fe4cb5` | MacBook Air(局域网 `ssh -i ~/.ssh/id_zju_sby billqiu@192.168.5.21`,外网 `ssh air-remote`) | `~/.cloudflared/config.yml`,launchd label `com.billqiu.cloudflared-chatbot` |
| 另一条隧道 | `af70db12-df0f-4e70-a3fe-61bc80f84db6` | 凭证文件在本机 `~/.cloudflared/`,归属机器待确认(疑似 zspace NAS,ssh.billq.cc/qb 等走它) | — |

**Air 隧道现有 hostname**:`chat.billq.cc`→:3000、`ssh-air.billq.cc`→ssh :22、`beszel.billq.cc`→:8091(Beszel 监控面板)

**Access 可复用策略**:

- `allow-owner-email` = `8eba1d3a-7ecd-4db6-9887-466375f5d588` —— 仅允许 `fanglaiq@gmail.com`(邮箱 OTP)。**个人服务加白名单直接复用它,别新建重复策略。**
- `allow-service-token` —— 给 cloudflared access ssh 用的服务令牌策略(ssh-air 在用)。

## Playbook ① 新增内网穿透域名(最常用)

目标:`<sub>.billq.cc` → Air 上的 `localhost:<port>`,并套邮箱白名单。三步:

```bash
# 1. Air 上加 ingress(新条目必须插在 catch-all `http_status:404` 之前)+ 重启
ssh -i ~/.ssh/id_zju_sby billqiu@192.168.5.21 '
cp ~/.cloudflared/config.yml ~/.cloudflared/config.yml.bak
# 用 Edit/sed 在 ingress 列表 404 前插入:
#   - hostname: <sub>.billq.cc
#     service: http://localhost:<port>
launchctl unload ~/Library/LaunchAgents/com.billqiu.cloudflared-chatbot.plist
launchctl load ~/Library/LaunchAgents/com.billqiu.cloudflared-chatbot.plist'

# 2. DNS 路由(本机执行,用 cert.pem,最简)
/usr/local/bin/cloudflared tunnel route dns 8e17712a-110c-4f26-be28-1c8f42fe4cb5 <sub>.billq.cc

# 3. Access 应用 + 白名单(复用现成策略)
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/615eeb815d72cee51fdd879085bc54d2/access/apps" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"<sub>","type":"self_hosted","domain":"<sub>.billq.cc",
       "policies":["8eba1d3a-7ecd-4db6-9887-466375f5d588"]}'
```

验证(两条都要过):

```bash
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" https://<sub>.billq.cc
# 期望 302 且 redirect_url 指向 billq.cloudflareaccess.com → 隧道通 + Access 生效
# 若 200 → 隧道通但白名单没挂上,回查第 3 步;若 404/530 → ingress 或 DNS 有问题
```

## Playbook ② DNS 记录

```bash
ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=billq.cc" \
  -H "Authorization: Bearer $CF_TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')

# 增(隧道 CNAME 目标固定为 <tunnel-id>.cfargotunnel.com,proxied 必须 true)
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"type":"CNAME","name":"<sub>","content":"<tunnel-id>.cfargotunnel.com","proxied":true}'

# 查 / 删
curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=<sub>.billq.cc" -H "Authorization: Bearer $CF_TOKEN"
curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/<record-id>" -H "Authorization: Bearer $CF_TOKEN"
```

## Playbook ③ Access 应用与策略

```bash
A="https://api.cloudflare.com/client/v4/accounts/615eeb815d72cee51fdd879085bc54d2"
curl -s "$A/access/apps" -H "Authorization: Bearer $CF_TOKEN"        # 列应用
curl -s "$A/access/policies" -H "Authorization: Bearer $CF_TOKEN"    # 列可复用策略
# 新建"仅允许某邮箱"的可复用策略(通常不需要,先看能否复用 allow-owner-email)
curl -s -X POST "$A/access/policies" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"<name>","decision":"allow","include":[{"email":{"email":"<who>@example.com"}}]}'
```

## 坑

- **本地管理隧道**:`PUT /cfd_tunnel/<id>/configurations` 对它无效,ingress 只认机器上的 config.yml;改完必须重启 cloudflared(launchd unload/load),会有几秒全部 hostname 断连。
- **macOS 26 本地网络权限**:Air 上新跑的第三方二进制若要访问局域网其他机器,会被静默拦截(连 127.0.0.1 正常、连 192.168.x.x 超时、无任何报错日志)。需在 Air 的 GUI 上点允许(系统设置 → 隐私与安全性 → 本地网络)。
- **Access 邮箱 OTP**:白名单邮箱要收验证码,填不存在的邮箱会把自己锁在门外。所有者邮箱是 `fanglaiq@gmail.com`(即 Cloudflare 登录邮箱)。
- 端口占用(Air):3000 chat、8091 beszel;新服务换别的端口。
- 改 ingress 前先 `cp config.yml config.yml.bak`,坏了能一秒回滚。
