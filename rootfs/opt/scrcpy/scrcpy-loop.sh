#!/bin/bash
# scrcpy 监督循环 + 看门狗(写法参考 chrome-kasmvnc 的 renderer watchdog)。
#
# 为什么需要看门狗:
#   - redroid Pod 重建 / adb 断链时 scrcpy 会直接退出 —— 靠 while 循环重拉即可;
#   - 但也有"进程还在、窗口没起来或者流已经死了"的情况(设备侧 server 被杀、编码器卡住),
#     这时进程不退, 循环不会触发, 浏览器里就是一块死画面。所以额外periodic检查:
#       a) 设备是否还在 `adb devices` 的 device 状态;
#       b) scrcpy 的 X 窗口是否存在(启动宽限期内允许没有)。
#     任一条不满足就 kill 掉 scrcpy, 交给外层循环重来。
set -uo pipefail

export DISPLAY="${DISPLAY:-:1}"
: "${ADB_SERIAL:=redroid.redroid.svc.cluster.local:5555}"
: "${SCRCPY_MAX_FPS:=30}"
: "${SCRCPY_VIDEO_BIT_RATE:=4M}"
: "${SCRCPY_MAX_SIZE:=0}"
: "${SCRCPY_EXTRA_ARGS:=}"
: "${WATCHDOG_INTERVAL:=15}"      # 巡检间隔(秒)
: "${WINDOW_GRACE:=90}"           # 启动后多久还没窗口就判定为挂了(秒)

device_ready() {
  adb devices 2>/dev/null | awk -v s="$ADB_SERIAL" '$1==s && $2=="device"{found=1} END{exit !found}'
}

while true; do
  # 等设备上线(start.sh 里有 adb connect 循环在后台不断重连)
  if ! device_ready; then
    echo "[loop] $(date -Is) waiting for ${ADB_SERIAL} ..."
    for _ in $(seq 1 60); do device_ready && break; sleep 2; done
  fi
  if ! device_ready; then
    echo "[loop] $(date -Is) device still offline, retry"
    continue
  fi

  echo "[loop] $(date -Is) launching scrcpy -> ${ADB_SERIAL}"
  # --render-driver=software : Xvnc 没有 GLX, 必须软件渲染
  # --no-audio               : redroid 没有音频设备, 开着只会反复报错并浪费 CPU
  # --window-borderless      : 配合 fluxbox 的 apps 规则铺满桌面
  # 剪贴板: Android -> 电脑 由 --clipboard-autosync 默认开启, 不要加 --no-clipboard-autosync;
  #         电脑 -> Android 由用户在画面里按 Alt+V 触发(scrcpy 3.x 没有自动推送的选项)
  scrcpy \
    --serial="${ADB_SERIAL}" \
    --no-audio \
    --render-driver=software \
    --window-borderless \
    --window-x=0 --window-y=0 \
    --max-fps="${SCRCPY_MAX_FPS}" \
    --video-bit-rate="${SCRCPY_VIDEO_BIT_RATE}" \
    --max-size="${SCRCPY_MAX_SIZE}" \
    ${SCRCPY_EXTRA_ARGS} &
  SCRCPY_PID=$!
  STARTED=$(date +%s)

  while kill -0 "$SCRCPY_PID" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL"
    kill -0 "$SCRCPY_PID" 2>/dev/null || break
    if ! device_ready; then
      echo "[watchdog] $(date -Is) device ${ADB_SERIAL} gone -> killing scrcpy"
      kill "$SCRCPY_PID" 2>/dev/null; sleep 3; kill -9 "$SCRCPY_PID" 2>/dev/null
      break
    fi
    if ! xdotool search --class scrcpy >/dev/null 2>&1; then
      if [ $(( $(date +%s) - STARTED )) -gt "$WINDOW_GRACE" ]; then
        echo "[watchdog] $(date -Is) no scrcpy window after ${WINDOW_GRACE}s -> killing scrcpy"
        kill "$SCRCPY_PID" 2>/dev/null; sleep 3; kill -9 "$SCRCPY_PID" 2>/dev/null
        break
      fi
    fi
  done

  wait "$SCRCPY_PID" 2>/dev/null
  echo "[loop] $(date -Is) scrcpy exited (rc=$?), relaunching in 3s"
  sleep 3
done
