#!/usr/bin/env bash
# =============================================================================
# run_bench.sh — OhEngine 标准性能 Bench（便携 / 流程化）
#
# 目标：任意开发机 + 任意 HarmonyOS 设备（真机或 DevEco 模拟器）用同一套命令、
#       同一套语料、同一套口径，得到可对比的性能开销数字。
#
# 流程：0 自检 → 1 语料(本机) → 2 构建(main + ohosTest) → 3 部署 → 4 语料注入
#       (设备内 ohosTest) → 5 场景采集 → 6 解析 → 7 报告
#
# 用法:
#   bash tests/bench/run_bench.sh                        # 全流程
#   bash tests/bench/run_bench.sh --skip-build           # 复用已构建 HAP
#   bash tests/bench/run_bench.sh --skip-inject          # 复用设备上已有语料
#   bash tests/bench/run_bench.sh --only txt-m,epub-s    # 只跑指定样例
#   bash tests/bench/run_bench.sh --scenarios cold,warm
#   DEVICE=127.0.0.1:5555 bash tests/bench/run_bench.sh  # 指定设备
#
# 环境变量（可覆盖，便于换机）:
#   DEVECO_HOME  DevEco 安装根（默认 /Applications/DevEco-Studio.app/Contents）
#   DEVICE       hdc 目标（默认自动取第一个）
#   BUNDLE       应用包名（默认 com.example.ohrengine）
#   WAIT_SEC     小样例采集等待秒数（默认 12；>8MB 的样例自动 ×5）
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
# 兼容：环境里的 DEVECO_HOME 可能指向 .app 根目录（缺 Contents），自动补正
if [ -d "$DEVECO_HOME/Contents" ]; then DEVECO_HOME="$DEVECO_HOME/Contents"; fi
HDC_BIN="${HDC:-$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc}"
NODE="${NODE:-$DEVECO_HOME/tools/node/bin/node}"
HVIGOR="${HVIGOR:-$DEVECO_HOME/tools/hvigor/bin/hvigorw.js}"
BUNDLE="${BUNDLE:-com.example.ohrengine}"
DEVICE="${DEVICE:-}"
WAIT_SEC="${WAIT_SEC:-12}"
MODULE="${MODULE:-entry}"
TEST_MODULE="${TEST_MODULE:-entry_test}"
CORPUS_DIR="$HERE/corpus"
OUT_DIR="$HERE/results"

MAIN_HAP="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
TEST_HAP="$ROOT/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap"

SCENARIOS="cold,warm"
ONLY=""
SKIP_BUILD=0
SKIP_INJECT=0
SKIP_DEPLOY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build)  SKIP_BUILD=1; shift ;;
    --skip-inject) SKIP_INJECT=1; shift ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --scenarios)   SCENARIOS="$2"; shift 2 ;;
    --only)        ONLY="$2"; shift 2 ;;
    --out)         OUT_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUT_DIR/$STAMP"
mkdir -p "$RUN_DIR/logs"
LOG="$RUN_DIR/run.log"

say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
die()  { say "❌ $*"; exit 1; }
step() { say ""; say "──── $* ────"; }

# ---------------------------------------------------------------- 0 自检
step "0 环境自检"
[ -x "$HDC_BIN" ] || die "hdc 不存在: ${HDC_BIN}（用 HDC=... 覆盖）"
[ -x "$NODE" ]    || die "node 不存在: ${NODE}（用 NODE=... 覆盖）"
if [ -z "$DEVICE" ]; then
  DEVICE="$("$HDC_BIN" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | head -1)"
  if [ -z "$DEVICE" ]; then
    die "无设备。模拟器：$DEVECO_HOME/tools/emulator/Emulator -start \"Mate 70 Pro+\" 然后 hdc tconn 127.0.0.1:5555"
  fi
fi
hdc() { "$HDC_BIN" -t "$DEVICE" "$@"; }
DEV_MODEL="$(hdc shell "param get const.product.model" 2>/dev/null | tr -d '\r' | xargs)"
DEV_API="$(hdc shell "param get const.ohos.apiversion" 2>/dev/null | tr -d '\r' | xargs)"
DEV_VER="$(hdc shell "param get const.product.software.version" 2>/dev/null | tr -d '\r' | xargs)"
KIND="真机"; [ "$DEV_MODEL" = "emulator" ] && KIND="DevEco 模拟器（虚拟机）"
say "设备     : $DEVICE"
say "型号     : $DEV_MODEL"
say "API/版本 : $DEV_API / $DEV_VER"
say "类型     : $KIND"
say "输出目录 : $RUN_DIR"

cat > "$RUN_DIR/meta.json" <<EOF
{
  "stamp": "$STAMP",
  "device": "$DEVICE",
  "model": "$DEV_MODEL",
  "kind": "$KIND",
  "api": "$DEV_API",
  "softwareVersion": "$DEV_VER",
  "bundle": "$BUNDLE",
  "scenarios": "$SCENARIOS",
  "waitSec": $WAIT_SEC
}
EOF

# 双视图路径：host = shell 视角（ls / rm），app = 应用视角（bookPath 参数）
FILES_HOST="/data/app/el2/100/base/$BUNDLE/haps/$MODULE/files"
FILES_APP="/data/storage/el2/base/haps/$MODULE/files"

# ---------------------------------------------------------------- 1 语料
step "1 语料（本机生成）"
"$NODE" "$HERE/make_corpus.mjs" 2>&1 | tee -a "$LOG"
say "语料目录 : $CORPUS_DIR"

# ---------------------------------------------------------------- 2 构建
if [ "$SKIP_BUILD" = "1" ]; then
  step "2 构建（跳过）"
else
  step "2 构建（main HAP + ohosTest HAP）"
  ( cd "$ROOT" && DEVECO_SDK_HOME="$DEVECO_HOME/sdk" "$NODE" "$HVIGOR" \
      assembleHap --mode module -p product=default --no-daemon ) >>"$RUN_DIR/build-main.log" 2>&1
  grep -E "BUILD SUCCESSFUL|ERROR" "$RUN_DIR/build-main.log" | tail -3 | tee -a "$LOG"
  ( cd "$ROOT" && DEVECO_SDK_HOME="$DEVECO_HOME/sdk" "$NODE" "$HVIGOR" \
      assembleHap --mode module -p module=entry@ohosTest -p product=default --no-daemon ) >>"$RUN_DIR/build-test.log" 2>&1
  grep -E "BUILD SUCCESSFUL|ERROR" "$RUN_DIR/build-test.log" | tail -3 | tee -a "$LOG"
fi
[ -f "$MAIN_HAP" ] || die "主 HAP 不存在: $MAIN_HAP"
say "主 HAP   : $(ls -l "$MAIN_HAP" | awk '{print $5" B  "$6" "$7" "$8}')"

# ---------------------------------------------------------------- 3 部署
step "3 部署"
if [ "$SKIP_DEPLOY" = "1" ]; then
  say "（--skip-deploy：复用设备上已安装的 HAP 与已注入语料）"
else
# 覆盖安装（不卸载）以保留设备上已注入的语料；失败时回退到 干净安装。
INST="$(hdc install -r "$MAIN_HAP" 2>&1 | tail -3)"
if ! echo "$INST" | grep -q "successfully"; then
  say "覆盖安装未成功，回退到干净安装"
  hdc uninstall "$BUNDLE" >/dev/null 2>&1 || true
  INST="$(hdc install -r "$MAIN_HAP" 2>&1 | tail -3)"
fi
say "$INST"
echo "$INST" | grep -q "successfully" || die "主 HAP 安装失败"
if [ -f "$TEST_HAP" ]; then
  INST_T="$(hdc install -r "$TEST_HAP" 2>&1 | tail -3)"
  echo "$INST_T" | grep -q "successfully" || die "测试 HAP 安装失败"
  say "测试 HAP 安装成功"
fi
fi

# ---------------------------------------------------------------- 4 语料注入
step "4 语料注入（设备内，走 ohosTest）"
if [ "$SKIP_INJECT" = "1" ]; then
  say "（--skip-inject：复用设备上已有语料；注意重装 HAP 会清空应用沙箱）"
  hdc shell "ls $FILES_HOST/books" >/dev/null 2>&1 || die "设备上没有语料，去掉 --skip-inject"
else
  hdc shell "hilog -r" >/dev/null 2>&1
  RES="$(hdc shell "aa test -b $BUNDLE -m $TEST_MODULE -s unittest OpenHarmonyTestRunner -s class BenchCorpusTest -s timeout 600000" 2>&1)"
  echo "$RES" | grep -E "Tests run|invalid" | tee -a "$LOG"
  echo "$RES" | grep -q "Tests run: 1, Failure: 0" || die "语料注入用例未通过（见 ${LOG}）"
  hdc shell "hilog -x" 2>/dev/null | grep "BENCH_CORPUS_DONE" | tail -1 | tee -a "$LOG"
fi
say "设备语料目录（host 视图）: $FILES_HOST/books"
hdc shell "ls -l $FILES_HOST/books" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------- 5 场景
echo "id,scenario,bookPath,start_epoch_ms,end_epoch_ms,rss_kb" > "$RUN_DIR/scenarios.csv"

bench_one() { # $1=样例文件名 $2=场景
  local name="$1" scen="$2"
  local base="${name%.*}"
  local out="$RUN_DIR/logs/${base}-${scen}.txt"
  local wait="$WAIT_SEC"
  local size
  # 设备侧文件大小（本机可能没有该文件，如设备内生成的 cbz-l）
  size="$(hdc shell "ls -l $FILES_HOST/books/$name" 2>/dev/null | tr -d '\r' | awk '{print $5}' | tail -1)"
  size="${size:-0}"
  [ "$size" -gt 8388608 ] && wait=$((WAIT_SEC * 5))

  if [ "$scen" = "cold" ]; then
    # 深度冷：L2/L3 页缓存 + TXT 索引 + EPUB/CBZ 解压产物（否则 EPUB/CBZ 只是"伪冷"）
    hdc shell "rm -rf $FILES_HOST/cache" >/dev/null 2>&1
    hdc shell "rm -rf $FILES_HOST/books/*_extracted" >/dev/null 2>&1
    hdc shell "rm -rf $FILES_HOST/books/*.extracted" >/dev/null 2>&1
  fi
  hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1
  sleep 2
  hdc shell "hilog -r" >/dev/null 2>&1
  local t0 t1
  t0="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  hdc shell "aa start -a EntryAbility -b $BUNDLE --ps bookPath $FILES_APP/books/$name" >/dev/null 2>&1
  local waited=0
  while [ "$waited" -lt "$wait" ]; do sleep 3; waited=$((waited+3)); done
  t1="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  hdc shell "hilog -x" > "$out" 2>/dev/null
  local pid rss="n/a"
  pid="$(hdc shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r')"
  [ -n "$pid" ] && rss="$(hdc shell "cat /proc/$pid/status" 2>/dev/null | tr -d '\r' | awk '/VmRSS/{print $2}')"
  rss="${rss:-n/a}"
  local lines
  lines="$(wc -l < "$out" | tr -d ' ')"
  local open_ms first_frame
  open_ms="$(grep -o "openMs=[0-9]*" "$out" | tail -1 | cut -d= -f2)"
  first_frame="$(grep -o "txtLazyIdxMs=[0-9]*" "$out" | tail -1 | cut -d= -f2)"
  echo "$base,$scen,$FILES_APP/books/$name,$t0,$t1,$rss" >> "$RUN_DIR/scenarios.csv"
  say "  ✓ ${base}/${scen}  openMs=${open_ms:-—} txtLazyIdxMs=${first_frame:-—} rss=${rss}KB  lines=$lines"
}

step "5 场景采集（scenarios=${SCENARIOS}）"
# 场景书单以「设备上实际存在的语料」为准（含设备内生成档，如 cbz-l）
DEVICE_BOOKS="$(hdc shell "ls $FILES_HOST/books" 2>/dev/null | tr -d '\r')"
for name in $DEVICE_BOOKS; do
  case "$name" in bench_*) ;; *) continue ;; esac
  case "$name" in *_extracted|*.zip|*.work|*.json) continue ;; esac
  base="${name%.*}"
  if [ -n "$ONLY" ]; then
    matched=0
    oldIFS="$IFS"; IFS=','
    for o in $ONLY; do
      o2="${o//-/_}"
      case "$base" in *"$o2"*) matched=1 ;; esac
    done
    IFS="$oldIFS"
    [ "$matched" = "1" ] || continue
  fi
  case ",$SCENARIOS," in *,cold,*) bench_one "$name" cold ;; esac
  case ",$SCENARIOS," in *,warm,*) bench_one "$name" warm ;; esac
done

# ---------------------------------------------------------------- 6 解析
step "6 解析埋点 → 指标"
"$NODE" "$HERE/parse_bench.mjs" "$RUN_DIR" 2>&1 | tee -a "$LOG"

# ---------------------------------------------------------------- 7 报告
step "7 结果"
say "运行目录 : $RUN_DIR"
say "报告     : $RUN_DIR/report.md"
say "指标     : $RUN_DIR/metrics.json"
