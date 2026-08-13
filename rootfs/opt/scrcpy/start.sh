#!/bin/bash
# 容器入口: 起 adb server + 自动 connect, 再起 KasmVNC(Xvnc), 由 xstartup 拉起 scrcpy(不跑 WM)。
# 参考自 ioucode/chrome-kasmvnc 的 start.sh(同一套 KasmVNC 用法), 把 Chrome 换成 scrcpy。
set -uo pipefail

# --- 网页鉴权 ---
# KASM_BASIC_AUTH=0(默认): 给 vncserver 加 -DisableBasicAuth 1, 打开页面不弹用户名/密码框。
#   线上前面有 Cloudflare Access + ingress 的 CF 回源网段白名单兜底, 所以不是裸奔。
#   想改回来就把这个变量设成 1(不需要重新构建镜像)。
# 注意: 这里**不是**"设个空密码"—— KasmVNC 用空密码要么起不来要么照样弹框, 必须用官方的
#       Xvnc 参数 DisableBasicAuth("Disable basic auth for websockets", 见 Xvnc -help)。
: "${KASM_BASIC_AUTH:=0}"
: "${VNC_USER:=scrcpy}"
# 即使关了 basic auth 也要生成一份密码文件: vncserver 找不到密码文件会走交互式设置流程,
# 容器里没有 tty 会直接失败。没显式给 VNC_PW 时随机生成一个(谁也不需要知道它)。
: "${VNC_PW:=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')}"
: "${KASM_PORT:=3001}"             # KasmVNC web 端口(TLS 由 ingress 终结, 这里跑明文)
: "${SCREEN_GEOMETRY:=720x1280}"   # X 桌面分辨率, 默认对齐 redroid 的 720x1280, 1:1 不缩放
: "${ADB_SERIAL:=redroid.redroid.svc.cluster.local:5555}"
: "${ADB_CONNECT_INTERVAL:=15}"
: "${SCRCPY_MAX_FPS:=30}"
: "${SCRCPY_VIDEO_BIT_RATE:=4M}"
: "${SCRCPY_MAX_SIZE:=0}"          # 0 = 不缩放
: "${SCRCPY_EXTRA_ARGS:=}"

export HOME=/config
export ADB_SERIAL ADB_CONNECT_INTERVAL SCREEN_GEOMETRY \
       SCRCPY_MAX_FPS SCRCPY_VIDEO_BIT_RATE SCRCPY_MAX_SIZE SCRCPY_EXTRA_ARGS
# 坑: **千万别设 ADB_SERVER_SOCKET**。一旦设成 tcp:127.0.0.1:5037, adb 就把它当"远端 server",
#     `adb start-server` / `adb connect` 都不会再 fork 出本地 daemon, 于是设备永远连不上,
#     scrcpy-loop 会一直卡在 "waiting for ..."。默认值本来就是本地 5037, 保持不设即可。
# SDL 在 Xvnc 上没有 GLX, 固定走软件渲染; WM_CLASS 固定成 scrcpy 方便 xdotool 精确匹配
export SDL_VIDEODRIVER=x11 SDL_VIDEO_X11_WMCLASS=scrcpy

mkdir -p /config/.vnc /config/.android

echo "[start] scrcpy $(scrcpy --version 2>/dev/null | head -1)"
echo "[start] $(adb version | head -1)"

# ---------------------------------------------------------------- adb
# redroid 是 TCP 设备, 不会自己出现在设备列表里, 必须 adb connect。
# redroid Pod 重建后 PodIP 会变, 所以一律用 Service DNS 名并循环重连(兼做自愈)。
adb start-server 2>&1 | sed 's/^/[adb] /'
(
  while true; do
    adb connect "${ADB_SERIAL}" >/dev/null 2>&1 || true
    sleep "${ADB_CONNECT_INTERVAL}"
  done
) &
echo "[start] adb auto-connect loop -> ${ADB_SERIAL} (every ${ADB_CONNECT_INTERVAL}s)"

# ---------------------------------------------------------------- KasmVNC 配置
printf '%s\n%s\n' "$VNC_PW" "$VNC_PW" | vncpasswd -u "$VNC_USER" -w -r || true

GEO_W="${SCREEN_GEOMETRY%x*}"; GEO_H="${SCREEN_GEOMETRY#*x}"
cat > /config/.vnc/kasmvnc.yaml <<YAML
network:
  protocol: http
  websocket_port: ${KASM_PORT}
  ssl:
    require_ssl: false
  udp:
    public_ip: 127.0.0.1
desktop:
  resolution:
    width: ${GEO_W}
    height: ${GEO_H}
  # 关掉动态改分辨率: scrcpy 的 SDL 窗口不会跟着桌面变大, 浏览器一拉伸就会露出黑边。
  # 桌面固定成设备分辨率, 由浏览器端做等比缩放。
  allow_resize: false
encoding:
  full_frame_updates: none
  rect_encoding_mode:
    min_quality: 6
    max_quality: 8
    consider_lossless_quality: 10
  video_encoding_mode:
    max_resolution:
      width: 1440
      height: 2560
YAML

# ---------------------------------------------------------------- xstartup
# 注意: **这里故意不跑窗口管理器**。桌面上只有 scrcpy 一个窗口, 且窗口尺寸被强制成桌面尺寸,
# 不需要 WM。一开始用的是 fluxbox(照抄 chrome-kasmvnc), 结果两个坑:
#   a) fluxbox 启动时会调 fbsetbg 设壁纸, 容器里没有壁纸程序, 它就弹一个 xmessage 窗口
#      ("fbsetbg: I can't find an app to set the wallpaper with")压在画面上还抢焦点。
#      rootCommand / styleOverlay(background: none) 都没能拦住。
#   b) 更严重: WM 的 reparent/map 与 SDL 的 SDL_RaiseWindow 抢跑, scrcpy 启动时偶发
#         X Error of failed request: BadMatch ... Major opcode 42 (X_SetInputFocus)
#      Xlib 默认错误处理直接把 scrcpy 打死(看门狗虽然能重拉, 但画面会闪一下)。
# 没有 WM 时 Xvnc 的输入焦点是 PointerRoot —— 键盘事件直接发给指针所在的窗口, 而 scrcpy
# 窗口铺满整个桌面, 所以键盘/快捷键(含 Alt+V 粘贴)照常工作。已实测验证。
cat > /config/.vnc/xstartup <<'XEOF'
#!/bin/bash
# vncserver 会在 :1 上执行本脚本, 环境变量从 start.sh 继承过来。
export DISPLAY="${DISPLAY:-:1}"
xsetroot -solid black 2>/dev/null || true
# 根窗口光标: 没有 WM 也没人设过根光标时, 根窗口的 cursor 是 None; 子窗口如果没自己定义
# 光标就会继承到 None -> 浏览器里看不到鼠标。显式设成 left_ptr 兜底。
xsetroot -cursor_name left_ptr 2>/dev/null || true
exec /opt/scrcpy/scrcpy-loop.sh >>/config/.vnc/scrcpy.log 2>&1
XEOF
chmod +x /config/.vnc/xstartup

# ---------------------------------------------------------------- 起 Xvnc
DISP=":1"
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix 2>/dev/null || true
vncserver -kill "$DISP" >/dev/null 2>&1 || true
rm -f "/tmp/.X${DISP#:}-lock" "/tmp/.X11-unix/X${DISP#:}" 2>/dev/null || true
rm -f /config/.vnc/*.pid /config/.vnc/*:1.log 2>/dev/null || true

term() { echo "[start] SIGTERM -> stopping"; vncserver -kill "$DISP" >/dev/null 2>&1 || true; exit 0; }
trap term TERM INT

VNC_ARGS=(-geometry "$SCREEN_GEOMETRY" -depth 24 -select-de manual)
if [ "$KASM_BASIC_AUTH" = "1" ]; then
  echo "[start] web basic auth: ENABLED (user ${VNC_USER})"
else
  echo "[start] web basic auth: DISABLED (-DisableBasicAuth 1)"
  VNC_ARGS+=(-DisableBasicAuth 1)
fi

echo "[start] starting KasmVNC on ${DISP} (web ${KASM_PORT}, geom ${SCREEN_GEOMETRY}, device ${ADB_SERIAL})"
vncserver "$DISP" "${VNC_ARGS[@]}"

# PID1 挂在日志上; wait 让 trap 能生效
tail -F /config/.vnc/scrcpy.log 2>/dev/null &
wait
