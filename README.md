# scrcpy-kasmvnc

KasmVNC + 原生 scrcpy 的 **linux/arm64** 容器镜像，用来在浏览器里操作 [redroid](https://github.com/remote-android/redroid-doc)（容器化 Android）。

```
浏览器 ──HTTP/WS:3001──> KasmVNC(Xvnc :1) ──> fluxbox + scrcpy(SDL) ──adb/TCP──> redroid(Android 14)
```

镜像：`ghcr.io/ioucode/scrcpy-kasmvnc:<commit-sha>`（每次 push 到 main 由 Actions 的 `ubuntu-24.04-arm` runner 原生构建）。

## 为什么不用 ws-scrcpy

ws-scrcpy 内置的 scrcpy server 是 2021 年的 **1.19-ws7**。它用反射调用
`IClipboard.addPrimaryClipChangedListener(listener, String, int)`，而 Android 13/14 给这个方法
加了 `attributionTag` / `deviceId` 参数，签名对不上：

```
java.lang.NoSuchMethodException: android.content.IClipboard$Stub$Proxy.addPrimaryClipChangedListener
  [interface android.content.IOnPrimaryClipChangedListener, class java.lang.String, int]
Server exited: ...
```

结果是剪贴板完全不可用、server 直接退出。upstream 在 **scrcpy 2.1.1** 修复（按参数个数动态匹配签名）。
本镜像用 **scrcpy 3.3.4**。

## 关键取舍

| 点 | 结论 |
|---|---|
| scrcpy 版本 | **3.3.4**，源码构建客户端 + 官方预编译 `scrcpy-server`（带 sha256 校验）。不能用 `apt install scrcpy`：bookworm 是 1.25、trixie 主仓库没有、trixie-backports 的 3.3.4 会被新版顶掉导致构建不可复现 |
| 基底 | `debian:trixie-slim`。KasmVNC deb 必须与发行版匹配（用 `kasmvncserver_trixie_1.5.0_arm64.deb`）；adb 34.0.5（bookworm 只有 29.0.6）；ffmpeg 7.1 |
| 渲染 | Xvnc 没有 GLX，固定 `--render-driver=software` |
| 编译开关 | 关掉 v4l2 / USB(OTG)，设备是 TCP 接入，用不上，还能少一个 libusb 运行期依赖 |

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VNC_USER` / `VNC_PW` | `scrcpy` / `scrcpy` | KasmVNC basic auth，线上从 k8s secret 注入 |
| `KASM_PORT` | `3001` | web 端口（明文 HTTP，TLS 由 ingress 终结） |
| `SCREEN_GEOMETRY` | `720x1280` | X 桌面分辨率，建议对齐设备分辨率做 1:1 |
| `ADB_SERIAL` | `redroid.redroid.svc.cluster.local:5555` | 一定用 Service DNS 名，Pod 重建后能自愈 |
| `SCRCPY_MAX_FPS` / `SCRCPY_VIDEO_BIT_RATE` / `SCRCPY_MAX_SIZE` | `30` / `4M` / `0` | 限流，控制 CPU |
| `SCRCPY_EXTRA_ARGS` | 空 | 追加给 scrcpy 的参数 |
| `AUTO_PUSH_CLIPBOARD` | `1` | 自动把 X 剪贴板推给 Android，见下 |

## 剪贴板

- **Android → 浏览器**：scrcpy 默认开启 `--clipboard-autosync`，设备剪贴板一变就写进 X 的 `CLIPBOARD`，
  KasmVNC 再同步到浏览器。全自动。
- **浏览器 → Android**：scrcpy 上游只给了快捷键 `Alt+v`（设置设备剪贴板并粘贴）/ `Alt+Shift+v`（只设置）。
  本镜像的 `clipboard-push.sh` 轮询 X 剪贴板，内容变化时用 xdotool 通过 XTEST 给 scrcpy 窗口补一次
  `Alt+Shift+v`，等效于自动推送。设 `AUTO_PUSH_CLIPBOARD=0` 可关掉，改回手动按键。

## 看门狗

`scrcpy-loop.sh` 负责：进程退出即重拉；另外定期巡检 —— 设备掉出 `adb devices` 或启动 90s 后仍无
scrcpy 窗口，就 kill 掉进程让外层循环重来（覆盖“进程还在但流已经死了”这种循环拉不动的情况）。
