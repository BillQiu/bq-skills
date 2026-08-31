#!/usr/bin/env bash
# cc-capture.sh — 抓取 Claude Code 到 api.anthropic.com 的请求明文
#
# 两种模式:
#
#   probe(默认)—— 用 headless `claude -p` 另起新进程触发一条全新连接的请求,
#                   立即抓到并落地。抓到的是最小上下文(约 2 messages),适合看协议/字段结构。
#
#   --session   —— 会话筛选模式:不触发任何请求,开着收窄的 MITM+Replica 后台守株,
#                   专门筛出「属于你当前在线会话」(messages 数 >= 阈值)的实时请求并落地。
#                   你只需继续正常对话;等你的进程某次实时请求落在新连接上就被抓到。
#                   注意:抓的是「往后的下一条」请求 —— 但 CC 每轮重发全量历史,
#                   所以那一条里就含截至当刻的完整上下文。已发出的历史请求抓不回来。
#                   想「确定性、立刻」拿完整上下文:先跑本模式,再 `claude --continue` 重启会话。
#
# 用法:
#   ./cc-capture.sh                    # probe:默认提示词
#   ./cc-capture.sh "提示词"           # probe:自定义触发内容
#   ./cc-capture.sh --session          # 会话筛选:默认 messages>=8 视为当前会话
#   ./cc-capture.sh --session 20       # 会话筛选:自定义 messages 阈值
#
# 前置:~/surge-root-ca.pem(三证书 bundle)、surge-cli、claude 均已就绪。
set -uo pipefail

CA="${NODE_EXTRA_CA_CERTS:-$HOME/surge-root-ca.pem}"
SURGE="$(command -v surge-cli || echo /opt/homebrew/bin/surge-cli)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# ---------- 解析模式 ----------
MODE="probe"; PROMPT="reply with the single word: ok"; MIN_MSGS=8
case "${1:-}" in
  --session) MODE="session"; [ -n "${2:-}" ] && MIN_MSGS="$2" ;;
  "")        : ;;
  *)         PROMPT="$1" ;;
esac

log(){ printf '\033[36m[cc-capture]\033[0m %s\n' "$*"; }
err(){ printf '\033[31m[cc-capture] ERROR:\033[0m %s\n' "$*" >&2; }
envget(){ "$SURGE" --raw environment 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['environment'].get('$1',''))" 2>/dev/null; }

# ---------- 前置检查 ----------
[ -x "$SURGE" ] || { err "找不到 surge-cli"; exit 1; }
[ -f "$CA" ]    || { err "找不到 CA bundle: $CA"; exit 1; }
command -v claude >/dev/null || { err "找不到 claude CLI"; exit 1; }

# ---------- 记录基线,善后恢复 ----------
BASE_MITM="$(envget MitMEnabled)"; BASE_REPL="$(envget Replica)"
cleanup(){ log "恢复隐私基线 (Replica=${BASE_REPL:-0}, MitMEnabled=${BASE_MITM:-0})"; "$SURGE" --raw set "Replica=${BASE_REPL:-0}" "MitMEnabled=${BASE_MITM:-0}" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# ---------- 起抓包会话(收窄到 api.anthropic.com)----------
if [ "$MODE" = "session" ]; then TL=1800; RCL=3000; POLL_MAX=900; else TL=600; RCL=500; POLL_MAX=60; fi
log "启动 Surge 抓包会话 (作用域: api.anthropic.com, timeLimit=${TL}s)"
"$SURGE" --raw set Replica=0 >/dev/null 2>&1
"$SURGE" --raw set MitMEnabled=1 Replica=1 \
  ReplicaSessionParameters.mitmOverride=1 \
  ReplicaSessionParameters.mitmOverrideHostnames=api.anthropic.com \
  ReplicaSessionParameters.timeLimit=$TL \
  ReplicaSessionParameters.requestCountLimit=$RCL >/dev/null 2>&1
[ "$(envget MitMEnabled)" = "1" ] || { err "MitMEnabled 被自动打回 0 —— CA bundle 有问题,claude 不信任 Surge 叶子证书"; exit 1; }

# ---------- 触发前最大请求 id(只认更新的捕获)----------
BASELINE_ID="$("$SURGE" --raw dump request 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except: print(0); sys.exit()
allr=(d.get("active-requests") or [])+(d.get("recent-requests") or [])
print(max([r.get("id",0) for r in allr] or [0]))')"

# ---------- 触发(仅 probe 模式)----------
if [ "$MODE" = "probe" ]; then
  log "probe 模式:触发 headless claude 请求..."
  NODE_EXTRA_CA_CERTS="$CA" claude -p "$PROMPT" >/dev/null 2>&1 &
  CLAUDE_PID=$!
else
  log "会话筛选模式:请继续正常对话。我在后台守到一条「当前会话」(messages>=$MIN_MSGS)的实时请求就落地。"
  log "(想立刻确定性拿到完整上下文:另开终端跑 'claude --continue' 重启会话。)"
  CLAUDE_PID=""
fi

# ---------- 轮询:找 rep=true & id>基线 & 完成 & (session 模式)messages>=阈值 ----------
log "等待捕获落盘 (最多 ${POLL_MAX}s)..."
FOUND=""
for _ in $(seq 1 $((POLL_MAX*2))); do
  FOUND="$("$SURGE" --raw dump request 2>/dev/null | MIN_MSGS=$MIN_MSGS MODE=$MODE BASELINE=$BASELINE_ID python3 -c "
import sys,json,os
min_msgs=int(os.environ['MIN_MSGS']); mode=os.environ['MODE']; baseline=int(os.environ['BASELINE'])
try: d=json.load(sys.stdin)
except: print(''); sys.exit()
allr=(d.get('active-requests') or [])+(d.get('recent-requests') or [])
c=[r for r in allr if r.get('replica') and '/v1/messages' in r.get('URL','') and r.get('id',0)>baseline and r.get('completed')]
c.sort(key=lambda r:r.get('id',0),reverse=True)
for r in c:
    dir=r.get('replicaDirectoryPath','')
    if not dir: continue
    if mode!='session':
        print(dir); break
    # session 模式:读盘数 messages,按阈值筛「当前会话」
    try:
        j=json.load(open(os.path.join(dir,'request.dump')))
        if len(j.get('messages',[]))>=min_msgs:
            print(dir); break
    except: continue
" 2>/dev/null)"
  if [ -n "$FOUND" ]; then break; fi
  sleep 0.5
done
[ -n "$CLAUDE_PID" ] && wait "$CLAUDE_PID" 2>/dev/null || true

if [ -z "$FOUND" ]; then
  if [ "$MODE" = "session" ]; then
    err "${POLL_MAX}s 内没等到「当前会话」的实时请求落在新连接上(进程一直复用旧连接)。最稳妥:另开终端 'claude --continue' 重启会话,它的第一条请求就带完整上下文、必被抓。"
  else
    err "${POLL_MAX}s 内没抓到 rep=true 的 /v1/messages,直接重跑一次即可。"
  fi
  exit 1
fi
log "命中捕获目录: $FOUND"

# ---------- 解码落地 + 摘要 ----------
OUTDIR="$HOME/cc-captures/${STAMP}-${MODE}"
mkdir -p "$OUTDIR"
python3 - "$FOUND" "$OUTDIR" <<'PY'
import sys,os,gzip,shutil,json
src,out=sys.argv[1],sys.argv[2]
shutil.copy(os.path.join(src,'request.dump'), os.path.join(out,'request.json'))
shutil.copy(os.path.join(src,'model.json'),   os.path.join(out,'model.json'))
b=open(os.path.join(src,'response.dump'),'rb').read()
if b[:2]==b'\x1f\x8b': b=gzip.decompress(b)
open(os.path.join(out,'response.sse'),'wb').write(b)
j=json.load(open(os.path.join(out,'request.json')))
m=json.load(open(os.path.join(out,'model.json')))
print('  model     =', j.get('model'), '| fallbacks =', j.get('fallbacks'))
print('  messages  =', len(j.get('messages',[])), '| tools =', len(j.get('tools',[])), '| system 块 =', len(j.get('system',[])))
print('  路由链    =', m.get('rule'), '->', m.get('originalPolicyName'), '->', m.get('policyName'))
print('  request.json  =', os.path.getsize(os.path.join(out,'request.json')), 'bytes (明文)')
print('  response.sse  =', os.path.getsize(os.path.join(out,'response.sse')), 'bytes (已解 gzip)')
PY

log "完成 ✅  明文已落地: $OUTDIR"
echo "  open \"$OUTDIR\""
