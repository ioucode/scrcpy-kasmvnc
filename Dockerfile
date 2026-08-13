# KasmVNC + 原生 scrcpy 的 linux/arm64 镜像。
# 用途: 给 redroid(容器化 Android 14 arm64)提供"浏览器里操作 Android"的入口,
#       取代 ws-scrcpy —— 后者内置的是 2021 年的 scrcpy server 1.19, 剪贴板在 Android 13+ 上彻底不可用。
#
# 架构: 浏览器 --HTTP/WS--> KasmVNC(Xvnc, 端口 3001) --> X11 :1 --> fluxbox + scrcpy(SDL 窗口)
#                                                                    |
#                                                        adb(TCP) --> redroid
#
# ============================ 踩坑记录(必读) ============================
#
# 1) **scrcpy 版本必须 >= 2.1.1, 这里用 3.3.4**
#    老 scrcpy(<=2.1)的 server 用反射调用
#      IClipboard.addPrimaryClipChangedListener(IOnPrimaryClipChangedListener, String, int)
#    Android 13/14 给这个方法加了 attributionTag/deviceId 参数, 签名对不上, 直接抛
#      java.lang.NoSuchMethodException: android.content.IClipboard$Stub$Proxy.addPrimaryClipChangedListener
#    并且 **server 进程当场退出**("Server exited")。upstream 在 2.1.1 修好(按参数个数动态匹配)。
#    => 剪贴板双向同步是本镜像存在的唯一理由, 版本不能降。
#
# 2) **不能直接 `apt install scrcpy`**
#    Debian bookworm 仓库里是 scrcpy 1.25(2022 年), 一样中招; trixie 主仓库根本没有 scrcpy;
#    只有 trixie-backports 才有 3.3.4。为了不依赖 backports 的存活(backports 里的版本会被新版顶掉,
#    旧版从归档消失后构建就断了), 这里**从源码构建客户端 + 下载官方预编译 scrcpy-server**:
#      - 客户端: GitHub 上的 v3.3.4 源码, meson/ninja 编译(C 代码, arm64 上 1~2 分钟)
#      - server: release 资产 scrcpy-server-v3.3.4(一个 dex jar), 带 sha256 校验
#        (自己编 server 要 Android SDK + JDK, 没必要; 官方 release 的这个文件永久可用且可校验)
#    客户端与 server 的版本必须**严格一致**, scrcpy 启动时会校验。
#
# 3) **基底必须是 Debian trixie**
#    - KasmVNC 的 deb 是按发行版编译的, 装错发行版的包会因为 libjpeg/libssl 等 soname 不匹配起不来。
#      v1.5.0 提供了 kasmvncserver_trixie_*_arm64.deb, 正好对上 trixie 基底。
#      (chrome-kasmvnc 那个镜像用的是 bookworm 基底 + bookworm deb, 同理。)
#    - adb: Google 官方 platform-tools 没有 arm64 版, 只能用发行版自带的。
#      bookworm 只有 adb 29.0.6(2019 年), trixie 是 34.0.5, 明显更稳。
#    - ffmpeg: trixie 是 7.1(libavcodec61 等), scrcpy 3.x 支持。
#
# 4) **Xvnc 里没有 GLX**, SDL 的 opengl renderer 建不起来会退化并打一堆警告,
#    所以运行期显式 `--render-driver=software`(见 start.sh)。
#
# 5) v4l2 / USB(OTG) 两个特性对本场景没用(设备是 TCP 接入), 编译时关掉,
#    省掉 libusb 运行期依赖。

ARG SCRCPY_VERSION=3.3.4
# scrcpy-server-v3.3.4 的官方 SHA256(取自 release 的 SHA256SUMS.txt)
ARG SCRCPY_SERVER_SHA256=8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e

# ---------------------------------------------------------------- 构建阶段
FROM debian:trixie-slim AS scrcpy-build
ARG SCRCPY_VERSION
ARG SCRCPY_SERVER_SHA256
ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git \
      gcc pkgconf meson ninja-build \
      libsdl2-dev libavcodec-dev libavdevice-dev libavformat-dev libavutil-dev libswresample-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN set -eux; \
    git clone --depth 1 --branch "v${SCRCPY_VERSION}" https://github.com/Genymobile/scrcpy.git .; \
    curl -fsSL -o /src/scrcpy-server \
      "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}"; \
    echo "${SCRCPY_SERVER_SHA256}  /src/scrcpy-server" | sha256sum -c -

# prebuilt_server: 跳过 gradle/Android SDK, 直接用上面校验过的 release server
RUN set -eux; \
    meson setup build \
      --buildtype=release --strip -Db_lto=true \
      -Dprebuilt_server=/src/scrcpy-server \
      -Dv4l2=false -Dusb=false; \
    ninja -C build; \
    DESTDIR=/out ninja -C build install; \
    find /out -type f | sort

# ---------------------------------------------------------------- 运行阶段
FROM debian:trixie-slim
ARG SCRCPY_VERSION
ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/config \
    KASMVNC_VERSION=1.5.0 \
    SCRCPY_VERSION=${SCRCPY_VERSION}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tini procps dbus-x11 ssl-cert jq \
      fluxbox xterm x11-utils x11-apps netpbm \
      xdotool xclip \
      fonts-dejavu fonts-noto-cjk \
      adb \
      libsdl2-2.0-0 libavcodec61 libavdevice61 libavformat61 libavutil59 libswresample5; \
    curl -fsSL -o /tmp/kasmvnc.deb \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_trixie_${KASMVNC_VERSION}_arm64.deb"; \
    apt-get install -y --no-install-recommends /tmp/kasmvnc.deb; \
    rm -f /tmp/kasmvnc.deb; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    adb version

# scrcpy 客户端 + /usr/local/share/scrcpy/scrcpy-server
COPY --from=scrcpy-build /out/usr/local /usr/local
RUN ldconfig && scrcpy --version

# dbus/X 相关程序会读 machine-id
RUN dbus-uuidgen --ensure=/etc/machine-id \
    && ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

# 非 root 用户; adb 需要可写 HOME 生成 ~/.android/adbkey, KasmVNC 需要可写 ~/.vnc
RUN useradd -u 1000 -m -d /config -s /bin/bash scrcpy \
    && usermod -aG ssl-cert scrcpy

COPY rootfs/ /
RUN chmod +x /opt/scrcpy/*.sh

EXPOSE 3001
USER scrcpy
WORKDIR /config
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scrcpy/start.sh"]
