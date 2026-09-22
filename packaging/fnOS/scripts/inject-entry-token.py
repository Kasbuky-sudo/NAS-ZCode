#!/usr/bin/env python3
"""给打包进 fpk 的 web/index.html 注入入口令牌脚本。

为什么需要：fnOS 面板入口 URL 会用向导值替换 ${wizard_path}，但它把该值当
**路径**处理（实测查询串会被丢掉），所以不能写 `/?token=${wizard_path}`。
改成 `/${wizard_path}`：入口路径本身就是令牌，页面加载后由本脚本把路径首段
写进 `zcode_lite_token` cookie。

服务端（entry-http.js）对 /ws、/ws/*、/api/* 的鉴权同时接受 cookie 与
`?token=`，且是**从请求里取值比对**，因此：

  面板 iframe → GET /<token>  → 注入脚本种 cookie
             → fetch /api/server-info  ✓
             → ws://host:8988/ws       ✓（浏览器自动带 cookie）

没有令牌时（服务端未启用鉴权）脚本是空操作；未带令牌的局域网设备拿到的
路径段不匹配，服务端照旧 401。
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "zcode-fnos-entry-token"

SNIPPET = (
    "<script>"
    "/* " + MARKER + ": 用入口路径里的令牌种鉴权 cookie */"
    "(function(){try{"
    "var seg=location.pathname.replace(/^\\/+/,'').split('/')[0];"
    "if(!seg)return;"
    "if(/(^|;\\s*)zcode_lite_token=/.test(document.cookie))return;"
    "document.cookie='zcode_lite_token='+encodeURIComponent(seg)+'; path=/; SameSite=Lax';"
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
        print("[build] index.html 已注入过入口令牌脚本，跳过")
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
