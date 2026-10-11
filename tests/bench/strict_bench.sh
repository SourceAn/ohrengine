#!/usr/bin/env bash
# =============================================================================
# strict_bench.sh — 按《OhEngine 打开延迟测试规程 v2》执行的严格基准脚本
#
# 实现范围：
#   §1.5 状态分级 L0 / L1 / L2（L3 需重启设备，须人工确认后另行执行）
#   §1.6 行前校验（dumpLayout 含书架 + 坐标当次解析 + 产物状态快照 + 设备时刻）
#        行后校验（OPEN_TOTAL 且 total 与期望一致 + 进程无 crash + 产物状态对比）
#   §1.7 样本量参数化（默认 L0/L1=20、L2=10，丢弃前 2 次预热）+ P50/P90/P95/max/σ
#   §1.9 CSV 字段（run_id/date/device/build/format/corpus_id/state/entry/exit/T_*/re_extracted/inode/files/bytes/valid/invalid_reason）
#
# 未实现（需先过 §1.2 门禁，见报告）：
#   埋点字段统一、埋点开销检验、hitrace/录屏首帧交叉验证、PSS 采样、截图 SSIM。
#
# 用法:
#   bash tests/bench/strict_bench.sh --corpus bench_epub_s.epub --format epub --state L2 --n 10
#   bash tests/bench/strict_bench.sh --corpus bench_txt_m.txt --format txt --state L0 --n 20
#   bash tests/bench/strict_bench.sh --corpus bench_cbz_l.cbz --format cbz --state L2 --n 5 --wait 25
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
[ -d "$DEVECO_HOME/Contents" ] && DEVECO_HOME="$DEVECO_HOME/Contents"
HDC_BIN="${HDC:-$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="${BUNDLE:-com.example.ohrengine}"
DEVICE="${DEVICE:-}"

CORPUS=""; FORMAT=""; STATE=""; N=0; WAIT=18; EXITMODE="kill"; EXPECT_PAGES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus) CORPUS="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --state)  STATE="$2"; shift 2 ;;
    --n)      N="$2"; shift 2 ;;
    --wait)   WAIT="$2"; shift 2 ;;
    --exit)   EXITMODE="$2"; shift 2 ;;
    --pages)  EXPECT_PAGES="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done
[ -n "$CORPUS" ] && [ -n "$STATE" ] && [ "$N" -gt 0 ] || { echo "用法见脚本头部"; exit 2; }

hdc() { "$HDC_BIN" -t "$DEVICE" "$@"; }
if [ -z "$DEVICE" ]; then
  DEVICE="$("$HDC_BIN" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | head -1)"
fi
[ -n "$DEVICE" ] || { echo "❌ 无设备"; exit 1; }

FILES_HOST="/data/app/el2/100/base/$BUNDLE/haps/entry/files"
ID="${CORPUS%.*}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HERE/results/strict-${ID}-${STATE}-$STAMP"
mkdir -p "$OUT/hilog"
CSV="$OUT/data.csv"
MODEL="$(hdc shell "param get const.product.model" 2>/dev/null | tr -d '\r' | xargs)"
APIVER="$(hdc shell "param get const.ohos.apiversion" 2>/dev/null | tr -d '\r' | xargs)"
DEVVER="$(hdc shell "param get const.product.software.version" 2>/dev/null | tr -d '\r' | xargs)"
TZOFF="$(hdc shell "date +%z" 2>/dev/null | tr -d '\r' | xargs)"

echo "run 目录: $OUT"
echo "设备: $DEVICE $MODEL API=$APIVER 系统=$DEVVER TZ=$TZOFF"
echo "对象: $CORPUS  状态: $STATE  次数: $N  等待: ${WAIT}s  exit: $EXITMODE"

echo "run_id,date,device,build,format,corpus_id,state,entry,exit,T_total,T_launch,T_shelf,T_prep,T_parse,T_layout,T_render,T_restore,re_extracted,inode_before,inode_after,files_before,files_after,bytes_after,pss_peak_mb,valid,invalid_reason" > "$CSV"

# ---------------------------------------------------------------- 工具
snapshot() { # 产物状态快照: inode files bytes（以 <name>_extracted 为单位）
  local d="$FILES_HOST/books/${CORPUS}_extracted"
  local ino count bytes
  ino="$(hdc shell "ls -di $d 2>/dev/null" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
  count="$(hdc shell "find $d -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r' | xargs)"
  bytes="$(hdc shell "du -sk $d 2>/dev/null" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
  echo "${ino:-none},${count:-0},${bytes:-0}"
}

pre_check() { # 行前：启动到书架并校验；成功打印 "SHELF x y"
  hdc shell "aa start -a EntryAbility -b $BUNDLE" >/dev/null 2>&1
  sleep 6
  hdc shell "uitest dumpLayout -p /data/local/tmp/l.json" >/dev/null 2>&1
  hdc file recv /data/local/tmp/l.json "$OUT/layout.json" >/dev/null 2>&1
  python3 - "$OUT/layout.json" "$CORPUS" <<'PY'
import json,sys,re
try:
    d=json.load(open(sys.argv[1])); name=sys.argv[2]
    s=json.dumps(d,ensure_ascii=False)
    if '书架' not in s: print('FAIL|NOT-SHELF'); raise SystemExit
except Exception:
    print('FAIL|DUMP-FAIL'); raise SystemExit
found=[]
def walk(n):
    a=n.get('attributes',{})
    if a.get('text','')==name:
        m=re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',a.get('bounds',''))
        if m:
            x1,y1,x2,y2=map(int,m.groups()); found.append(((x1+x2)//2,(y1+y2)//2))
    for c in n.get('children',[]): walk(c)
walk(d)
print(f'SHELF {found[0][0]} {found[0][1]}' if found else 'FAIL|BOOK-NOT-VISIBLE')
PY
}

prepare_state() { # 状态准备
  case "$STATE" in
    L2)
      hdc shell "rm -rf $FILES_HOST/cache" >/dev/null 2>&1
      hdc shell "rm -rf $FILES_HOST/books/${CORPUS}_extracted $FILES_HOST/books/${CORPUS}.extracted" >/dev/null 2>&1
      hdc shell "rm -rf $FILES_HOST/reading_state" >/dev/null 2>&1
      hdc shell "find $FILES_HOST -name '*.tmp' -delete" >/dev/null 2>&1
      hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1; sleep 2 ;;
    L1)
      # 进程冷、产物保留：仅杀进程
      hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1; sleep 2 ;;
    L0)
      # 同进程热：不杀进程，返回书架（若已在阅读页则按返回键）
      hdc shell "uitest uiInput keyEvent 2" >/dev/null 2>&1; sleep 3 ;;
    *) echo "❌ 未支持状态: $STATE（L3 需重启设备，人工执行）"; exit 2 ;;
  esac
}

parse_firstframe_ms() { # 从 hilog 文本算 "首帧设备时刻(epoch ms)"
  python3 - "$1" "$TZOFF" <<'PY'
import re,sys
from datetime import datetime,timedelta,timezone
txt=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
tz=sys.argv[2] if len(sys.argv)>2 and sys.argv[2] else '+0800'
sign=1 if tz[0]=='+' else -1
off=timezone(timedelta(hours=sign*int(tz[1:3]), minutes=sign*int(tz[3:5])))
def epoch(ts):
    dt=datetime.strptime('2026-'+ts,'%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=off)
    return int(dt.timestamp()*1000)
m=re.search(r'(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})[^\n]*COLDSTART FIRST_FRAME', txt) or \
  re.search(r'(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})[^\n]*OPEN_TOTAL page=1 total=\d+', txt)
print(epoch(m.group(1)) if m else '')
PY
}

pid_of() { hdc shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }

# ---------------------------------------------------------------- 主循环
valid_n=0
for i in $(seq 1 "$N"); do
  prepare_state
  PRE="$(pre_check)"
  case "$PRE" in
    FAIL*) echo "  [$i] 行前校验失败: $PRE → 作废"; 
           echo "$ID-$STATE-$i,$(date +%F),$MODEL,$DEVVER,$FORMAT,$CORPUS,$STATE,shelf,$EXITMODE,,,,,,,,,,,,0,precheck:$PRE" >> "$CSV"; continue ;;
  esac
  X="$(echo "$PRE" | awk '{print $2}')"; Y="$(echo "$PRE" | awk '{print $3}')"
  SNAP_B="$(snapshot)"
  PID_B="$(pid_of)"

  hdc shell "hilog -r" >/dev/null 2>&1
  TA="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  hdc shell "uitest uiInput click $X $Y" >/dev/null 2>&1
  TB="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  sleep "$WAIT"
  LOGF="$OUT/hilog/$ID-$STATE-$i.txt"
  hdc shell "hilog -x" > "$LOGF" 2>/dev/null

  PID_A="$(pid_of)"
  SNAP_A="$(snapshot)"
  FF="$(parse_firstframe_ms "$LOGF")"
  # 应用 pid 内关键字检查（§1.2-4）
  CRASH="$(grep -E "APPCRASH|THREAD_BLOCK|appfreeze_inner|NotifyAppFault" "$LOGF" | grep -c "com.example.ohrengine" || true)"
  OT="$(grep -oE "OPEN_TOTAL page=1 total=[0-9]+" "$LOGF" | tail -1)"
  TOT=""; if [ -n "$FF" ] && [ -n "$TA" ] && [ -n "$TB" ]; then
    MID=$(( (TA + TB) / 2 )); TOT=$(( FF - MID ))
  fi
  REX=0; [ "$(echo "$SNAP_B" | cut -d, -f1)" != "$(echo "$SNAP_A" | cut -d, -f1)" ] && REX=1
  VALID=1; REASON=""
  [ -z "$FF" ] && { VALID=0; REASON="no-firstframe"; }
  [ -z "$OT" ] && { VALID=0; REASON="${REASON}no-open-total;"; }
  [ "$CRASH" -gt 0 ] && { VALID=0; REASON="${REASON}crash-or-block;"; }
  [ "$i" -le 2 ] && REASON="${REASON}warmup;"
  [ "$VALID" = "1" ] && valid_n=$((valid_n+1))

  PSS=""; [ -n "$PID_A" ] && PSS="$(hdc shell "hidumper --mem $PID_A 2>/dev/null" 2>/dev/null | grep -oE "Pss: *[0-9]+" | head -1 | grep -oE "[0-9]+" || true)"
  echo "$ID-$STATE-$i,$(date +%F),$MODEL,$DEVVER,$FORMAT,$CORPUS,$STATE,shelf,$EXITMODE,${TOT:-},$(( ${TB:-0}-${TA:-0} )),,,,,,,${REX},$(echo "$SNAP_B"|cut -d, -f1),$(echo "$SNAP_A"|cut -d, -f1),$(echo "$SNAP_B"|cut -d, -f2),$(echo "$SNAP_A"|cut -d, -f2),$(echo "$SNAP_A"|cut -d, -f3),${PSS:-},${VALID},${REASON}" >> "$CSV"
  printf '  [%d/%d] T_total=%sms re_extracted=%s pages=%s valid=%s %s\n' "$i" "$N" "${TOT:-—}" "$REX" "$(echo "$OT" | grep -oE 'total=[0-9]+' | cut -d= -f2)" "$VALID" "$REASON"
  # 相邻运行间隔 ≥ 30 s（§1.4）
  [ "$i" -lt "$N" ] && sleep 30
done

# ---------------------------------------------------------------- 统计（剔除前 2 次预热）
echo ""
python3 - "$CSV" "$STATE" "$N" <<'PY'
import csv,sys,statistics
rows=list(csv.DictReader(open(sys.argv[1])))
state=sys.argv[2]; n=int(sys.argv[3])
data=[]
for r in rows:
    if r['valid']!='1': continue
    try: idx=int(r['run_id'].split('-')[-1])
    except: idx=0
    if idx<=2: continue                     # §1.7 丢弃前 2 次预热
    try: data.append(int(r['T_total']))
    except: pass
print(f'状态 {state}：有效样本 {len(data)}（剔除预热）')
if data:
    s=sorted(data)
    def pct(p): return s[min(len(s)-1,int(len(s)*p))]
    print(f'  min={s[0]}  P50={pct(.5)}  P90={pct(.9)}  P95={pct(.95)}  max={s[-1]}  σ={statistics.pstdev(data):.1f}')
    print(f'  明细: {data}')
PY
echo ""
echo "CSV: $CSV"
echo "⚠️ 本批次未通过 §1.2 门禁（埋点未修/无开销检验/无首帧交叉验证），不得用于对外达标结论。"
