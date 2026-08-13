#!/bin/bash
# X 剪贴板 -> Android 剪贴板 的自动推送。
#
# 背景: scrcpy 的剪贴板同步是**半自动**的 ——
#   * Android -> 电脑: 默认开启(--clipboard-autosync), 设备剪贴板一变就自动写进 X 的 CLIPBOARD, 无需人工;
#   * 电脑 -> Android: 上游只提供快捷键 MOD+v(设置设备剪贴板并粘贴) / MOD+Shift+v(只设置不粘贴),
#                      没有"自动推"的选项。
# 对"在浏览器里复制一段文字, 想粘到 Android 里"这个主场景, 每次让用户去按 Alt+Shift+v 太别扭,
# 所以这里轮询 X 的 CLIPBOARD, 一旦内容变化就用 xdotool 给 scrcpy 窗口发一次 Alt+Shift+v。
#
# 注意:
#  * 必须用 XTEST(不带 --window 的 xdotool key)。SDL 会忽略 XSendEvent 伪造的按键,
#    带 --window 的方式发过去 scrcpy 收不到。
#  * 该组合键会被 scrcpy 当作快捷键吃掉, 不会透传给 Android, 不会污染输入。
#  * 反向回环不会发散: 推给设备后设备剪贴板变化会被 autosync 推回来, 内容相同 -> 不再触发。
#  * 不想要这个行为就把环境变量 AUTO_PUSH_CLIPBOARD 设成 0。
set -uo pipefail

export DISPLAY="${DISPLAY:-:1}"
: "${CLIPBOARD_POLL_INTERVAL:=1}"

last=""
echo "[clip] $(date -Is) X CLIPBOARD -> Android auto-push started (interval ${CLIPBOARD_POLL_INTERVAL}s)"

while true; do
  sleep "${CLIPBOARD_POLL_INTERVAL}"
  cur=$(xclip -o -selection clipboard 2>/dev/null) || continue
  [ -z "$cur" ] && continue
  [ "$cur" = "$last" ] && continue

  wid=$(xdotool search --class scrcpy 2>/dev/null | head -1)
  if [ -z "$wid" ]; then
    continue   # scrcpy 窗口还没起来, 下一轮再说(不更新 last, 起来后会补推)
  fi
  xdotool windowactivate --sync "$wid" >/dev/null 2>&1
  xdotool key --clearmodifiers alt+shift+v >/dev/null 2>&1
  last="$cur"
  echo "[clip] $(date -Is) pushed ${#cur} chars to device"
done
