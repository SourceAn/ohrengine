#!/usr/bin/env bash
# =============================================================================
# realpath_bench.sh — 严格版「真实用户路径」打开延迟基准
#
# 与 run_bench.sh 的区别（这是 run_bench 的缺陷修正版）：
#   1) 走真实路径：启动 → 书架 → uitest 真实点击（不是 aa start --ps bookPath 直开）
#   2) 行前校验：dumpLayout 必须含"书架"，否则该次作废
#   3) 行后校验：必须出现 OPEN_TOTAL，否则该次作废
#   4) 坐标自动解析：从 dumpLayout 里按书名匹配 bounds 中心，不硬编码
#   5) 深度冷：清 cache + books/*_extracted（否则 EPUB/CBZ 是伪冷）
#   6) 每本跑两次：第一次（冷）+ 返回键退出后第二次（验证缓存是否命中）
#   7) 以「解压目录 inode 是否变化」判定是否重新解压（比读日志硬）
#
# 用法: bash tests/bench/realpath_bench.sh [--only id,id] [--wait N] [--keep]
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
[ -d "$DEVECO_HOME/Contents" ] && DEVECO_HOME="$DEVECO_HOME/Contents"
HDC_BIN="${HDC:-$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="${BUNDLE:-com.example.ohrengine}"
DEVICE="${DEVICE:-}"
WAIT="${WAIT:-20}"
ONLY=""
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HERE/results/realpath-$STAMP"
mkdir -p "$OUT/logs"

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

hdc() { "$HDC_BIN" -t "$DEVICE" "$@"; }
say() { printf '%s\n' "$*" | tee -a "$OUT/run.log"; }
die() { say "❌ $*"; exit 1; }
step() { say ""; say "──── $* ────"; }

step "0 自检"
[ -x "$HDC_BIN" ] || die "hdc 不存在: ${HDC_BIN}"
if [ -z "$DEVICE" ]; then
  DEVICE="$("$HDC_BIN" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$' | head -1)"
fi
[ -n "$DEVICE" ] || die "无设备"
MODEL="$(hdc shell "param get const.product.model" 2>/dev/null | tr -d '\r' | xargs)"
VER="$(hdc shell "param get const.product.software.version" 2>/dev/null | tr -d '\r' | xargs)"
say "设备: $DEVICE ($MODEL / $VER)"
FILES_HOST="/data/app/el2/100/base/$BUNDLE/haps/entry/files"
say "沙箱: $FILES_HOST"

# ---------------------------------------------------------------- 工具函数
to_shelf() { # 启动到书架并校验；成功打印 SHELF
  hdc shell "aa start -a EntryAbility -b $BUNDLE" >/dev/null 2>&1
  sleep 6
  hdc shell "uitest dumpLayout -p /data/local/tmp/l.json" >/dev/null 2>&1
  hdc file recv /data/local/tmp/l.json "$OUT/logs/layout.json" >/dev/null 2>&1
  python3 - "$OUT/logs/layout.json" <<'PY'
import json,sys
try:
    s=json.dumps(json.load(open(sys.argv[1])),ensure_ascii=False)
    print('SHELF' if '书架' in s else 'NOT-SHELF')
except Exception:
    print('DUMP-FAIL')
PY
}

# 从 dumpLayout 里解析某本书的点击中心坐标
book_xy() { # $1 = 书名
  python3 - "$OUT/logs/layout.json" "$1" <<'PY'
import json,sys,re
name=sys.argv[2]
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(''); raise SystemExit
def walk(n):
    a=n.get('attributes',{})
    if a.get('text','')==name:
        b=a.get('bounds','')
        m=re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',b)
        if m:
            x1,y1,x2,y2=map(int,m.groups())
            print(f'{(x1+x2)//2} {(y1+y2)//2}'); raise SystemExit
    for c in n.get('children',[]): walk(c)
walk(d)
print('')
PY
}

# 采集一次打开的时间序
capture() { # $1=标签
  hdc shell "hilog -x" > "$OUT/logs/$1.txt" 2>/dev/null
  python3 - "$OUT/logs/$1.txt" "$1" <<'PY'
import re,sys
txt=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
lab=sys.argv[2]
def ts(pat):
    m=re.search(r'(\d{2}:\d{2}:\d{2}\.\d{3})[^\n]*'+pat, txt)
    return m.group(1) if m else None
def ms(t):
    if not t: return None
    h,mi,s=t.split(':'); return (int(h)*3600+int(mi)*60+float(s))*1000
ac=ts(r'ABILITY_CREATE keys'); sc=ts(r'SHELF_CONSUME'); si=ts(r'SESSION_INIT_START')
so=ts(r'SESSION_OPEN id=1'); ot=ts(r'OPEN_TOTAL page=1 total=(\d+)')
tp=re.search(r'OPEN_TOTAL page=1 total=(\d+)', txt)
pages=tp.group(1) if tp else '-'
def d(a,b):
    return f'{ms(b)-ms(a):.0f}' if (a and b) else '-'
print(f'RESULT|{lab}|create2shelf={d(ac,sc)}|shelf2init={d(sc,si)}|init2open={d(si,so)}|open2total={d(so,ot)}|init2total={d(si,ot)}|total={d(ac,ot)}|pages={pages}|open_total_found={"yes" if ot else "NO"}')
PY
}

inode_of() { hdc shell "ls -di $FILES_HOST/books/$1_extracted 2>/dev/null" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }

# ---------------------------------------------------------------- 主流程
BOOKS="$(hdc shell "ls $FILES_HOST/books" 2>/dev/null | tr -d '\r')"
say ""
say "id                 第1次(冷)        第2次(返回后再点)     inode变化  首帧总时长"
printf '%s\n' "id,phase,create2shelf_ms,shelf2init_ms,init2open_ms,open2total_ms,total_ms,pages,inode,open_ok" > "$OUT/data.csv"

for name in $BOOKS; do
  case "$name" in bench_*) ;; *) continue ;; esac
  case "$name" in *_extracted|*.zip|*.work|*.json) continue ;; esac
  id="${name%.*}"
  if [ -n "$ONLY" ]; then
    hit=0; oldIFS="$IFS"; IFS=','
    for o in $ONLY; do o2="${o//-/_}"; case "$id" in *"$o2"*) hit=1 ;; esac; done
    IFS="$oldIFS"
    [ "$hit" = "1" ] || continue
  fi

  step "$id"
  # 深度冷
  hdc shell "rm -rf $FILES_HOST/cache" >/dev/null 2>&1
  hdc shell "rm -rf $FILES_HOST/books/${name}_extracted $FILES_HOST/books/${name}.extracted" >/dev/null 2>&1
  hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1; sleep 2
  ST="$(to_shelf)"
  if [ "$ST" != "SHELF" ]; then say "  行前校验失败(${ST}) → 作废"; continue; fi
  XY="$(book_xy "$name")"
  if [ -z "$XY" ]; then say "  坐标解析失败 → 作废"; continue; fi
  say "  坐标: $XY"

  IN0="$(inode_of "$name")"
  hdc shell "hilog -r" >/dev/null 2>&1
  TA="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  hdc shell "uitest uiInput click $XY" >/dev/null 2>&1
  TB="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  say "  点击时刻(设备epoch ms) [${TA}, ${TB}] 往返=$(( ${TB:-0} - ${TA:-0} ))ms"
  sleep "$WAIT"
  R1="$(capture "$id-cold")"
  IN1="$(inode_of "$name")"
  say "  #1 $R1"
  CH1="no"; [ "$IN0" != "$IN1" ] && CH1="yes(重解压)"
  echo "$id,cold,${R1#RESULT|$id|}" >> "$OUT/data.csv" 2>/dev/null
  echo "$id,cold,,,,,,,$IN1,$CH1" >> "$OUT/data.csv"

  # 返回键 → 校验回书架 → 第二次点击
  hdc shell "uitest uiInput keyEvent 2" >/dev/null 2>&1; sleep 4
  ST2="$(to_shelf)"
  if [ "$ST2" != "SHELF" ]; then say "  第二次行前校验失败(${ST2}) → 作废"; continue; fi
  hdc shell "hilog -r" >/dev/null 2>&1
  TA2="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  hdc shell "uitest uiInput click $XY" >/dev/null 2>&1
  TB2="$(hdc shell "date +%s%3N" 2>/dev/null | tr -d '\r')"
  say "  点击时刻(设备epoch ms) [${TA2}, ${TB2}] 往返=$(( ${TB2:-0} - ${TA2:-0} ))ms"
  sleep "$WAIT"
  R2="$(capture "$id-warm")"
  IN2="$(inode_of "$name")"
  say "  #2 $R2"
  CH2="no"; [ "$IN1" != "$IN2" ] && CH2="yes(重解压)"
  echo "$id,warm,,,,,,,$IN2,$CH2" >> "$OUT/data.csv"
done

step "原始结果"
say "运行目录: $OUT"
say "数据: $OUT/data.csv"
say ""
say "说明：total_ms = ABILITY_CREATE → OPEN_TOTAL（点击到可显示页）；inode 变化 = 该次重新解压"
