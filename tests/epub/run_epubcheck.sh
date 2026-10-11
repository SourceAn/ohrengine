#!/bin/bash
# EPUB 兼容性校验脚本（ENG-010）
#
# 用 EPUBCheck 对样本 EPUB 做规格合规校验，并输出结构化结果。
#
# 用法：
#   ./run_epubcheck.sh [epubcheck.jar 路径] [样本目录]
#
# 默认：
#   - epubcheck.jar：由 EPUBCHECK_JAR 环境变量或参数 1 指定
#   - 样本目录：项目根目录 *.epub + entry/src/main/resources/rawfile/*.epub
#
# 输出：tests/epub/results/<样本名>.txt + 汇总 tests/epub/results/summary.txt
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

EPUBCHECK_JAR="${1:-${EPUBCHECK_JAR:-}}"
SAMPLE_DIR="${2:-$PROJECT_DIR}"

if [ -z "$EPUBCHECK_JAR" ] || [ ! -f "$EPUBCHECK_JAR" ]; then
  echo "ERROR: epubcheck.jar not found. Usage: $0 /path/to/epubcheck.jar [样本目录]"
  echo "下载：https://github.com/w3c/epubcheck/releases"
  exit 2
fi

OUT_DIR="$SCRIPT_DIR/results"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.txt"
rm -f "$SUMMARY"

echo "=== OhEngine EPUB 兼容性校验（EPUBCheck $(java -jar "$EPUBCHECK_JAR" --version 2>/dev/null | head -1)）===" | tee "$SUMMARY"
echo "样本目录: $SAMPLE_DIR" | tee -a "$SUMMARY"
echo "" | tee -a "$SUMMARY"

FAIL=0
PASS=0

# 收集样本：项目根目录 + rawfile
SAMPLES=()
for f in "$SAMPLE_DIR"/*.epub; do
  [ -f "$f" ] && SAMPLES+=("$f")
done
for f in "$PROJECT_DIR/entry/src/main/resources/rawfile"/*.epub; do
  [ -f "$f" ] && SAMPLES+=("$f")
done

for epub in "${SAMPLES[@]}"; do
  base="$(basename "$epub")"
  echo "---- $base ----" | tee -a "$SUMMARY"
  java -jar "$EPUBCHECK_JAR" "$epub" > "$OUT_DIR/$base.txt" 2>&1
  rc=$?
  # 提取结果
  errors=$(grep -c "ERROR(" "$OUT_DIR/$base.txt" || true)
  warnings=$(grep -c "WARNING(" "$OUT_DIR/$base.txt" || true)
  errors=${errors:-0}
  warnings=${warnings:-0}
  if [ $rc -eq 0 ] && [ "$errors" -eq 0 ]; then
    echo "  [PASS] errors=$errors warnings=$warnings" | tee -a "$SUMMARY"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] rc=$rc errors=$errors warnings=$warnings" | tee -a "$SUMMARY"
    FAIL=$((FAIL+1))
  fi
done

echo "" | tee -a "$SUMMARY"
echo "通过: $PASS  失败: $FAIL" | tee -a "$SUMMARY"
echo "详细结果: $OUT_DIR/"
exit 0
