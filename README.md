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

## 剪贴板

链路：`浏览器 ↔ KasmVNC ↔ X CLIPBOARD ↔ scrcpy ↔ Android`

- **Android → 浏览器：全自动。** scrcpy 默认开着 `--clipboard-autosync`，设备剪贴板一变就写进 X 的
  `CLIPBOARD`，KasmVNC 再同步给浏览器。
- **浏览器 → Android：在画面里按 `Alt+V`。** 这一下会把电脑（= X）剪贴板写进 **Android 的
  primary clip** 并执行粘贴。

⚠️ scrcpy **3.x** 的快捷键语义和网上很多老文档不一样（见 `app/src/input_manager.c`）：

| 快捷键 | 3.x 实际行为 |
|---|---|
| `Alt+V` | 设置**设备剪贴板** + 粘贴 |
| `Alt+Shift+V` | 把电脑剪贴板当作**按键序列注入**（legacy paste），**完全不碰设备剪贴板** |
| `Alt+C` / `Alt+X` | 向设备注入 COPY / CUT，再由 autosync 回传到电脑 |

因为没有“只设剪贴板、不粘贴”的快捷键，所以**没法在后台安全地自动推送**（后台自动按 `Alt+V`
会往用户当前焦点的输入框里乱贴东西）。上游也是有意不提供自动推送的。

浏览器那一段（浏览器 ↔ KasmVNC）依赖浏览器的异步剪贴板 API，需要 **HTTPS（secure context）**
并允许剪贴板权限；用 `http://<clusterip>:3001` 直连时浏览器会禁用该 API，只能用 KasmVNC 侧边栏的
剪贴板面板手工贴。

## 已验证（redroid Android 14 arm64）

- scrcpy 3.3.4 客户端 + 同版本 server 正常连上，日志里**没有** `NoSuchMethodException` / `Server exited`。
- X → Android：容器内 `xclip` 写入 `X2A_…_KLM` → 画面里 `Alt+V` → 设备侧清空输入框后单独 `Ctrl+V`
  粘出同一串，说明 Android 的 primary clip 确实被改写。
- Android → X：设备侧输入框里 `Ctrl+A`/`Ctrl+C` → 容器内 `xclip -o -selection clipboard` 立刻读到同一串。
- 注：redroid 这个 build 的 `ClipboardService` 没实现 shell dump，`adb shell dumpsys clipboard`
  永远是空输出（`cmd clipboard` 也是 `No shell command implementation`），验证只能靠“粘贴回读”。

## 看门狗

`scrcpy-loop.sh` 负责：进程退出即重拉；另外定期巡检 —— 设备掉出 `adb devices` 或启动 90s 后仍无
scrcpy 窗口，就 kill 掉进程让外层循环重来（覆盖“进程还在但流已经死了”这种循环拉不动的情况）。
