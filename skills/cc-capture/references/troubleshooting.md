# cc-capture 排障 & 原理

抓 Claude Code → `api.anthropic.com` 明文时,踩过的坑和判据。按「现象 → 原因 → 处理」组织。

## 关键机制(先理解这个,大部分坑自明)

- **标准 MITM(`MitMEnabled`)** 让 Surge 能解密并在 Dashboard 显示 URL/路径 —— 但这**不等于**落盘。
- **Replica 落盘** 需要连接是在**当前 replica 会话期间**、由 replica 的 `mitmOverride` 接管建立的。只有这类请求 `replica=true` 并写 `request.dump`/`response.dump` 到磁盘。
- 因此:能在 dump 里看到 `/v1/messages` 完整 URL(说明标准 MITM 生效了),但 `replica=false`(没落盘)—— 这是正常且常见的组合,不是 bug。

## 现象:开关显示 Replica=1,但完全不落盘(rep 全 False)

- **原因**:Replica 会话有 `timeLimit`(默认 180s),过期后开关仍显示 `1` 但已停止捕获。**这是当年误判成「配置错/CA 错」的真凶。**
- **处理**:每次抓之前 `surge-cli --raw set Replica=0` 再 `set Replica=1` 起新会话。脚本已内置这一步,并把 `timeLimit` 放宽到 600s、`requestCountLimit` 到 500。

## 现象:抓不到 claude 自己的请求(它的 /v1/messages 一直 rep=False)

- **原因**:Claude Code(Node/undici)复用「开 MITM 之前」建立的 HTTP/2 长连接;这条老隧道 Surge 无法回溯解密,走它的请求永远 rep=False。
- **处理**:要一条**在会话内新建**的连接。两条路:
  1. 脚本用 `claude -p` 起**新进程** → 全新连接 → 直接 rep=true(推荐,确定性最高)。
  2. 抓交互会话:先起会话,**再重启交互 claude**,让它启动时第一条连接就落在会话内。
- **反面教训**:别写 killer 循环去 kill 老连接逼重连 —— claude 响应是 **SSE 流式**、请求会持续活跃数秒,killer 会把要抓的流式请求中途掐断,导致 replica 永远无法完成落盘(rep 恒 False),纯帮倒忙。

## 现象:MitMEnabled 一 set 就被自动打回 0

- **原因**:这才是真正的 CA 问题 —— Surge 判定当前签发/信任链无效。检查 `~/surge-root-ca.pem` 是否为三证书 bundle(rixCloud ECC CA + 两张 Surge Generated),以及系统钥匙串信任。
- 注意区分:MitMEnabled 稳在 1、只是 rep=False,那是会话/连接问题,**不是** CA 问题。

## 现象:retrieve-data 取不到正文

- `retrieve-data <id> request|response` 一直返回 `Data does not exist` / `(null)`,**别用它**。正文其实都在磁盘上,直接读文件。

## 落盘位置

- `dump request` 顶层 `persistent-store` 字段 = capture 根目录(**仅会话活跃时非空**)。
- 单条目录:`/var/folders/.../T/Surge Catpure/<yyyy-mm-dd-HHMMSS>/Requests/<id> - HH.MM.SS - POST - https%3A%2F%2Fapi.anthropic.com%2Fv1%2Fmessages.../`(Surge 自己把 "Capture" 拼成了 "Catpure",别当成 typo 改路径)。
- 三件套:`request.dump`(纯请求体明文,无 header)、`response.dump`(**gzip**,SSE 流,需解压)、`model.json`(路由链,如 `RULE-SET Claude.list` → 中转节点智能组_Dmit → hysteria2)。
- 每条请求记录里 `replicaDirectoryPath` 直接给出该请求的落盘目录,比拼顶层字段更省事。

## 安全 / 隐私

- profile `[MITM] hostname` 已收窄到 `router.com, www.router.com, api.anthropic.com`,标准 MITM 只解密这几个域名。
- Replica 的 `mitmOverrideHostnames` 默认是 `*`(全系统,只排除 icloud/apple 等)。脚本把它收窄成 `api.anthropic.com`,避免对 cursor/figma/微信/浏览器等落盘明文。
- **务必善后**:用完 `set Replica=0 MitMEnabled=0`。脚本用 `trap EXIT` 保证退出/报错/Ctrl-C 都会恢复。
- 落地的明文含完整 system prompt / 对话,注意别外传。`~/cc-captures/` 建议定期清。
