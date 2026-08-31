---
name: cc-capture
description: One-command capture of Claude Code's plaintext HTTPS traffic to api.anthropic.com via Surge MITM, for protocol/request-body analysis. Starts a scoped Surge capture session, triggers a real CC request through a fresh MITM'd connection, reads the decrypted request/response from disk, and restores the privacy baseline automatically. Use when the user wants to inspect, analyze, or debug what Claude Code sends to the Anthropic API, or says things like '抓一下 CC 的请求明文', '看看 Claude Code 发了什么', '分析 CC 客户端流量', '抓包 api.anthropic.com', 'capture claude traffic', 'mitm claude code', 'surge 抓 claude'.
---

# cc-capture · 抓 Claude Code 请求明文

一条命令,把 Claude Code 发给 `api.anthropic.com` 的 HTTPS 流量解密落地成明文,供做协议/请求体分析。

## 前提(本机已配好,首次或异常时才需检查)

- `~/surge-root-ca.pem` —— 三证书 bundle(rixCloud ECC CA + 两张 Surge Generated),让 Node/claude 信任 Surge 的 MITM 叶子证书。缺它 claude 会 `SELF_SIGNED_CERT_IN_CHAIN` 断开。
- `surge-cli` 可用(`/opt/homebrew/bin/surge-cli`),Surge 正在运行。
- Surge profile 的 `[MITM] hostname` 含 `api.anthropic.com`(作用域已收窄到路由/anthropic 几个域名,不动其他 App)。

快速自检:`test -f ~/surge-root-ca.pem && surge-cli --raw environment | head -c 80`

## 怎么用

跑本 skill 目录下的脚本(路径相对 skill 基目录),两种模式:

```bash
scripts/cc-capture.sh                 # probe:另起 headless claude 抓一条最小请求
scripts/cc-capture.sh "自定义提示词"   # probe:让请求体带特定内容
scripts/cc-capture.sh --session       # 会话筛选:抓「当前在线会话」的实时请求(默认 messages>=8)
scripts/cc-capture.sh --session 20    # 会话筛选:自定义 messages 阈值
```

不论哪种模式:起收窄抓包会话(只 MITM api.anthropic.com)→ 校验 MitM 没被打回 0 → 捞 `rep=true` 的 `/v1/messages` → 解码(response 解 gzip)落地到 `~/cc-captures/<时间戳>-<模式>/` → **trap EXIT/INT/TERM 自动恢复隐私基线**(报错/中断/被 kill 都会还原)。

落地三件套:
- `request.json` —— 明文请求体(model / system / messages / tools 全在里面)
- `response.sse` —— 已解 gzip 的 SSE 响应流
- `model.json` —— Surge 路由链

**关键差异(见下节「两种模式」):**
- `probe` 用 `claude -p` **另起新进程** → 全新连接直接被抓,几秒出结果,但抓到的是**最小上下文**。
- `--session` **不触发任何请求**,后台守株、按 messages 数**筛出你当前会话**的实时请求。需要**在后台运行**(`run_in_background`)并让用户继续正常对话来产生请求。

## 跑完后要做的

1. 读 `~/cc-captures/<时间戳>/request.json`,按用户的分析目标解析(结构、字段、system prompt、tools 定义、token 用量等),**结构化总结给用户**,不要原样倾倒 300KB。
2. 把落地目录路径告诉用户,附 `open "<目录>"`。

## 两种模式,怎么选、怎么跑

### probe(默认)—— 看协议/字段结构

`scripts/cc-capture.sh` 一条命令,几秒出结果。抓到的是 `claude -p` 新进程的**最小 CC 请求**(如 2 messages / 10 tools)。做协议、字段、system prompt 结构、fallback 机制分析足够。**同步跑**即可。

### --session(会话筛选)—— 抓用户当前在线会话的实时上下文

抓的是**用户正在聊的这个会话**的实时请求(几十条 messages 的完整上下文)。要点:

1. **必须后台跑**:用 `run_in_background` 启动 `scripts/cc-capture.sh --session`。它不触发请求,而是开着抓包**守株等待**。
2. **让用户继续正常对话**:每一轮对话都会发一条带完整历史的 `/v1/messages`;脚本按 messages 数筛出「当前会话」的那条,一旦某次实时请求落在新连接上就抓下来落地。
3. 抓到后 `~/cc-captures/<时间戳>-session/` 出现文件,读它做分析。若几分钟没命中,说明进程一直复用旧连接。

**关键认知**(向用户讲清):抓的是「往后的下一条」请求,不是回溯历史;但 CC 每轮**重发全量历史**,所以那一条里就含截至当刻的**完整上下文**。已发出的历史请求抓不回来。

**想「确定性、立刻」拿到完整上下文** → 先起会话再重启续接:
```bash
surge-cli --raw set MitMEnabled=1 Replica=1 ReplicaSessionParameters.mitmOverride=1 ReplicaSessionParameters.mitmOverrideHostnames=api.anthropic.com
# 另开终端(或退出当前会话后):
NODE_EXTRA_CA_CERTS=~/surge-root-ca.pem claude --continue   # 载入完整历史,第一条请求即含全上下文、必被抓
# 用完:surge-cli --raw set Replica=0 MitMEnabled=0
```

> ⚠️ 别用 killer 循环强制当前进程重连 —— CC 响应是 SSE 流式,kill 会中途掐断要抓的请求,反而抓不到。详见 references/troubleshooting.md。

## 排障

抓不到 / rep 一直 False / MitM 被打回 0 等,见 [references/troubleshooting.md](references/troubleshooting.md)。核心三条:Replica 会话 180s 会过期(每次重开)、claude 复用旧连接会 rep=False(要全新连接)、别 kill 流式请求(会破坏捕获)。
