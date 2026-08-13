/*
 * cursorprobe —— 打印当前 X 指针光标的位图信息, 用来验证"光标到底可不可见"。
 *
 * 为什么需要它: xwd/import 截图**不包含指针**, 所以"截个图看看有没有箭头"这条路走不通。
 * X 的 XFIXES 扩展提供 XFixesGetCursorImage(), 能直接把当前正在显示的光标(指针所在窗口
 * 生效的那个 Cursor)的 ARGB 位图取出来。这里统计其中 alpha != 0 的像素数:
 *   opaque > 0  -> 光标有实际可见像素
 *   opaque == 0 -> 光标是全透明/空光标(也就是"没有光标")
 * 退出码: 0 = 可见, 1 = 全透明, 2 = 连不上 X, 3 = 没有 XFIXES, 4 = 取不到光标。
 *
 * 用法: DISPLAY=:1 cursorprobe
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>
#include <stdio.h>

int main(void) {
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "cursorprobe: cannot open display\n"); return 2; }

    int event_base, error_base;
    if (!XFixesQueryExtension(d, &event_base, &error_base)) {
        fprintf(stderr, "cursorprobe: no XFIXES extension\n");
        return 3;
    }

    XFixesCursorImage *c = XFixesGetCursorImage(d);
    if (!c) { fprintf(stderr, "cursorprobe: XFixesGetCursorImage returned NULL\n"); return 4; }

    unsigned long total = (unsigned long)c->width * (unsigned long)c->height;
    unsigned long opaque = 0;
    for (unsigned long i = 0; i < total; i++) {
        /* pixels 是 unsigned long 数组, 每个元素低 32 位是 ARGB */
        if ((unsigned long)((c->pixels[i] >> 24) & 0xffUL)) opaque++;
    }

    printf("cursor at (%d,%d) size=%ux%u hotspot=(%u,%u) pixels=%lu opaque=%lu -> %s\n",
           c->x, c->y, c->width, c->height, c->xhot, c->yhot,
           total, opaque, opaque ? "VISIBLE" : "EMPTY/INVISIBLE");

    XFree(c);
    XCloseDisplay(d);
    return opaque ? 0 : 1;
}
