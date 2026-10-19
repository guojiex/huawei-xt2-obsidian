#!/usr/bin/env bash
# Start and inspect the Huawei TripleFold emulator on macOS.
# Usage: ./tools/emu.sh [--run|--scenario|--start|--shot|--ui|--probe-fold|--shell CMD]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVECO_CONTENTS="${DEVECO_CONTENTS:-/Applications/DevEco-Studio.app/Contents}"
EMULATOR="$DEVECO_CONTENTS/tools/emulator/Emulator"
HDC="$DEVECO_CONTENTS/sdk/default/openharmony/toolchains/hdc"
HVIGOR="$DEVECO_CONTENTS/tools/hvigor/bin/hvigorw"
NODE_HOME="$DEVECO_CONTENTS/tools/node"
JAVA_HOME="$DEVECO_CONTENTS/jbr/Contents/Home"
INSTANCE="${EMU_INSTANCE:-Huawei_TripleFold}"
PORT="${EMU_HDC_PORT:-15001}"
TAG="emu"
MODE="run"
FOLD_LIST="single,double,triple"
SHELL_CMD=""
BUILD=1

usage() {
  cat <<'EOF'
三折叠模拟器工具（macOS）

用法：tools/emu.sh [选项]

  --run              启动模拟器，构建（默认）、安装并拉起应用
  --scenario         拉起应用并切换 single/double/triple，各保存截图
  --start            只启动模拟器，不构建或安装
  --shot             对当前屏幕截图
  --ui               安装并拉起应用，导出 UI 控件树
  --probe-fold       探测模拟器支持的折叠态参数
  --fold STATE       切换到指定折叠态
  --shell COMMAND    在模拟器中执行一条 hdc shell 命令
  --fold-list LIST   --scenario 的状态列表，逗号分隔
  --tag NAME         截图 / UI 文件名前缀（默认 emu）
  --port PORT        hdc 端口（默认 15001）
  --no-build         使用已有 HAP，不重新构建
  --help             显示帮助

可用环境变量：DEVECO_CONTENTS、EMU_INSTANCE、EMU_HDC_PORT
截图和 UI 树写入仓库 .local/shots/。
模拟器进程可能在脚本结束时被执行环境回收；完整验证请用 --scenario 一次跑完。
EOF
}

while (($#)); do
  case "$1" in
    --run) MODE="run" ;;
    --scenario) MODE="scenario" ;;
    --start) MODE="start" ;;
    --shot) MODE="shot" ;;
    --ui) MODE="ui" ;;
    --probe-fold) MODE="probe-fold" ;;
    --fold) shift; MODE="fold"; FOLD_LIST="${1:-}" ;;
    --shell) shift; MODE="shell"; SHELL_CMD="${1:-}" ;;
    --fold-list) shift; FOLD_LIST="${1:-}" ;;
    --tag) shift; TAG="${1:-emu}" ;;
    --port) shift; PORT="${1:-15001}" ;;
    --no-build) BUILD=0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知选项：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for tool in "$EMULATOR" "$HDC"; do
  if [[ ! -x "$tool" ]]; then
    echo "找不到可执行文件：$tool" >&2
    echo "可用 DEVECO_CONTENTS 指向 DevEco-Studio.app/Contents" >&2
    exit 1
  fi
done

TARGET="127.0.0.1:$PORT"
SHOT_DIR="$REPO_ROOT/.local/shots"
OUT_DIR="$REPO_ROOT/entry/build/default/outputs/default"
mkdir -p "$SHOT_DIR"

is_online() {
  "$HDC" list targets 2>/dev/null | tr -d '\r' | grep -Fxq "$TARGET"
}

ensure_emulator() {
  if is_online; then
    echo "模拟器已在线：${TARGET}"
    return
  fi
  echo "启动 ${INSTANCE}（hdc ${TARGET}）…"
  nohup "$EMULATOR" -start "$INSTANCE" -hdcPort "$PORT" \
    >"$SHOT_DIR/emulator.log" 2>&1 </dev/null &
  for _ in $(seq 1 90); do
    if is_online; then
      echo "模拟器已在线：${TARGET}"
      return
    fi
    sleep 2
  done
  echo "等待模拟器超时；启动日志：$SHOT_DIR/emulator.log" >&2
  tail -50 "$SHOT_DIR/emulator.log" >&2 || true
  exit 1
}

build_app() {
  export JAVA_HOME
  export HOS_SDK_HOME="$DEVECO_CONTENTS/sdk"
  export DEVECO_SDK_HOME="$DEVECO_CONTENTS/sdk"
  export PATH="$JAVA_HOME/bin:$NODE_HOME/bin:$DEVECO_CONTENTS/tools/ohpm/bin:$PATH"
  echo "构建 HAP…"
  (
    cd "$REPO_ROOT"
    "$HVIGOR" assembleHap --mode module -p product=default --node-home "$NODE_HOME"
  )
}

latest_hap() {
  local hap="" candidate candidate_mtime latest_mtime
  latest_mtime=0
  if [[ -d "$OUT_DIR" ]]; then
    while IFS= read -r -d '' candidate; do
      candidate_mtime="$(stat -f %m "$candidate")"
      if ((candidate_mtime >= latest_mtime)); then hap="$candidate"; latest_mtime="$candidate_mtime"; fi
    done < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*.hap' -print0)
  fi
  printf '%s' "$hap"
}

install_launch() {
  local hap start_output
  hap="$(latest_hap)"
  if [[ "$BUILD" -eq 1 || -z "$hap" ]]; then
    build_app
    hap="$(latest_hap)"
  fi
  if [[ -z "$hap" ]]; then
    echo "构建后没有找到 HAP：$OUT_DIR" >&2
    exit 1
  fi
  echo "安装：$hap"
  "$HDC" -t "$TARGET" install "$hap"
  echo "拉起应用…"
  start_output="$("$HDC" -t "$TARGET" shell aa start -a EntryAbility -b com.jxg.huaweiobsidian 2>&1 || true)"
  if grep -qi 'screen is locked' <<<"$start_output"; then
    echo "屏幕锁定，尝试上滑解锁后重试…"
    "$HDC" -t "$TARGET" shell uitest uiInput swipe 1592 2100 1592 600 600
    sleep 2
    start_output="$("$HDC" -t "$TARGET" shell aa start -a EntryAbility -b com.jxg.huaweiobsidian 2>&1 || true)"
  fi
  printf '%s\n' "$start_output"
  if ! grep -qi 'start ability successfully' <<<"$start_output"; then
    echo "应用启动失败，请检查 .local/shots/emulator.log 和 DevEco hilog。" >&2
    return 1
  fi
  sleep 8
}

take_shot() {
  local name="$1" latest dest candidate mtime latest_mtime before_file previous_candidate previous_size size
  before_file="$(mktemp "${TMPDIR:-/tmp}/xt2-emu-shots.XXXXXX")"
  # The emulator timestamps Screenshot_*.png to the second; avoid a same-name overwrite.
  sleep 1
  find "$SHOT_DIR" -maxdepth 1 -type f -name 'Screenshot_*.png' -exec basename {} \; >"$before_file"
  "$EMULATOR" -instance "$INSTANCE" -screenshot -screenshotPath "$SHOT_DIR"
  latest=""
  latest_mtime=0
  previous_candidate=""
  previous_size=0
  for _ in $(seq 1 15); do
    latest=""
    latest_mtime=0
    while IFS= read -r -d '' candidate; do
      if grep -Fxq "$(basename "$candidate")" "$before_file"; then continue; fi
      mtime="$(stat -f %m "$candidate")"
      if ((mtime >= latest_mtime)); then latest="$candidate"; latest_mtime="$mtime"; fi
    done < <(find "$SHOT_DIR" -maxdepth 1 -type f -name 'Screenshot_*.png' -print0)
    if [[ -n "$latest" ]]; then
      size="$(stat -f %z "$latest")"
      if [[ "$latest" == "$previous_candidate" && "$size" -eq "$previous_size" && "$size" -gt 0 ]]; then
        dest="$SHOT_DIR/${name}_$(date +%Y%m%d_%H%M%S).png"
        cp "$latest" "$dest"
        rm -f "$before_file"
        echo "截图 → $dest"
        return
      fi
      previous_candidate="$latest"
      previous_size="$size"
    fi
    sleep 1
  done
  rm -f "$before_file"
  echo "模拟器没有生成截图" >&2
  exit 1
}

export DEVECO_CONTENTS
case "$MODE" in
  start)
    ensure_emulator
    ;;
  run)
    ensure_emulator
    install_launch
    ;;
  shot)
    ensure_emulator
    take_shot "$TAG"
    ;;
  ui)
    ensure_emulator
    install_launch
    "$EMULATOR" -instance "$INSTANCE" -uiLayout -i >"$SHOT_DIR/${TAG}_ui.md"
    echo "UI 树 → $SHOT_DIR/${TAG}_ui.md"
    ;;
  shell)
    if [[ -z "$SHELL_CMD" ]]; then echo "--shell 需要命令" >&2; exit 2; fi
    ensure_emulator
    "$HDC" -t "$TARGET" shell "$SHELL_CMD"
    ;;
  fold|probe-fold|scenario)
    ensure_emulator
    if [[ "$MODE" == "scenario" ]]; then install_launch; fi
    if [[ "$MODE" == "probe-fold" ]]; then
      for state in folded expanded half half_folded single double triple FOLDED EXPANDED 1 2 3 0; do
        printf '%-12s ' "$state"
        "$EMULATOR" -instance "$INSTANCE" -foldedState "$state" 2>&1 || true
      done
    elif [[ "$MODE" == "fold" ]]; then
      "$EMULATOR" -instance "$INSTANCE" -foldedState "$FOLD_LIST"
    else
      IFS=',' read -r -a states <<<"$FOLD_LIST"
      for state in "${states[@]}"; do
        state="$(echo "$state" | xargs)"
        echo "切换形态：$state"
        "$EMULATOR" -instance "$INSTANCE" -foldedState "$state"
        sleep 6
        take_shot "${TAG}_${state}"
      done
    fi
    ;;
  *)
    echo "无效模式：$MODE" >&2
    exit 2
    ;;
esac
