#!/usr/bin/env python3
"""给打包进 fpk 的 web/index.html 注入入口令牌脚本。

为什么需要：fnOS 面板入口 URL 会用向导值替换 ${wizard_path}，但它把该值当
**路径**处理（实测查询串会被丢掉），所以不能写 `/?token=${wizard_path}`。
改成 `/${wizard_path}`：入口路径本身就是令牌，页面加载后由本脚本把路径首段
写进 `zcode_lite_token` cookie。

服务端（entry-http.js）对 /ws、/ws/*、/api/* 的鉴权同时接受 cookie 与
`?token=`，且是**从请求里取值比对**，因此：

  面板 iframe → GET /<token>  → 注入脚本写 cookie
             → fetch /api/server-info  ✓
             → ws://host:8988/ws       ✓（浏览器自动带 cookie）

⚠️ 必须**覆盖**已存在的旧 cookie，不能"有就跳过"：
重装/换令牌后，浏览器里往往还留着上一版的 `zcode_lite_token`，跳过写入会让
页面带着旧令牌握手 → /ws 401 → 前端显示「Web 启动失败 / WebSocket connection
failed」。真机踩过这个坑（旧令牌残留在 cookie 里）。

只把**单段路径**当成令牌，避免误伤应用自身的路由
（如 /share/callback、/cn/share/callback 这些 OAuth 回跳路径），
否则登录流程会被写坏。
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "zcode-fnos-entry-token"

SNIPPET = (
    "<script>"
    "/* " + MARKER + ": 用入口路径里的令牌刷新鉴权 cookie（含覆盖旧令牌）*/"
    "(function(){try{"
    "var p=location.pathname.replace(/^\\/+|\\/+$/g,'');"
    "if(!p||p.indexOf('/')!==-1)return;"          # 仅单段路径才是令牌
    "if(p==='share'||p==='cn'||p==='index.html')return;"
    "var m=document.cookie.match(/(?:^|;\\s*)zcode_lite_token=([^;]*)/);"
    "var cur=m?decodeURIComponent(m[1]):null;"
    "if(cur===p)return;"
    "document.cookie='zcode_lite_token='+encodeURIComponent(p)+'; path=/; SameSite=Lax';"
    "}catch(e){}})();"
    "</script>"
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: inject-entry-token.py <web/index.html>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"✗ 找不到 {path}", file=sys.stderr)
        return 1

    html = path.read_text(encoding="utf-8")
    if MARKER in html:
        # 已有旧版注入（可能有"跳过写入"的缺陷）：整体替换为最新片段
        start = html.find("<script>/* " + MARKER)
        end = html.find("</script>", start)
        if start != -1 and end != -1:
            html = html[:start] + SNIPPET + html[end + len("</script>"):]
            path.write_text(html, encoding="utf-8", newline="\n")
            print("[build] 已更新入口令牌脚本（覆盖旧版本注入）")
            return 0
        print("[build] 检测到标记但无法定位片段，保持原样")
        return 0

    if "<head>" in html:
        html = html.replace("<head>", "<head>" + SNIPPET, 1)
    else:
        html = SNIPPET + html

    # 统一 LF：该文件在 Linux 上由服务端读取，不需要 CRLF
    path.write_text(html, encoding="utf-8", newline="\n")
    print("[build] 已注入入口令牌脚本 → web/index.html")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
