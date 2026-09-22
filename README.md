# ZCode · 飞牛 fnOS 原生版

把 [Z.ai 开源的 AI 编程工作台 ZCode](https://github.com/zai-org/ZCode) 打包成飞牛 fnOS 的**原生第三方应用**（非 Docker）：

- 服务端跑在 NAS 上，浏览器 / 飞牛桌面里直接用完整工作台——**Agent 对话、代码工作区、内置终端**
- 登录态与工作区保存在 NAS 上，手机 / 平板 / 电脑共用一份
- **非 Docker**：原生 Node.js 运行，复用应用中心的 **Node.js v22**（`install_dep_apps` 自动装）
- **一个包同时支持 x86_64 与 arm64**（`platform = all`，原生模块用官方预编译件）
- 基于 ZCode 官方 Web 运行时（`zcode --web`），与桌面版共用同一套前端组件

> 本仓库只做 NAS 侧的移植与打包，不修改 ZCode 本身。上游代码：[zai-org/ZCode](https://github.com/zai-org/ZCode)（Apache-2.0）。开发者：Z.ai；飞牛移植 / 打包 / 发布：[Kasbuky-sudo](https://github.com/Kasbuky-sudo)。

## 安装

1. 在飞牛应用中心先安装（或随本应用自动装上）**Node.js v22** 运行时；
2. 从 [Releases](https://github.com/Kasbuky-sudo/NAS-ZCode/releases) 下载 `zcode-<版本>.fpk`；
3. 应用中心 → 手动安装 → 选择 fpk 文件；
4. 安装完成后从桌面图标打开（iframe 内嵌）。

端口默认 **8988**。首个飞牛版本需要真机验收，请先在测试设备安装。

## 工作区

应用安装后会创建共享目录 `zcode/workspace` 作为默认工作区（文件管理器可见）。让 ZCode 操作已有目录（如某个共享文件夹）时，在「应用中心 → 已安装 → ZCode → 设置 → 访问权限」添加授权目录，然后重启应用。

## 与桌面版的差异

| | 桌面版 | NAS 版 |
|---|---|---|
| 界面 | Electron 窗口 | 浏览器 / 飞牛桌面 iframe（同一套前端组件） |
| 终端 | 本机 node-pty | 服务端 node-pty（浏览器内） |
| 浏览器自动化 | 内置 | 不可用（NAS 无桌面 Chromium） |
| 配置与凭据 | 本机用户目录 | NAS 应用数据目录（升级保留） |

## 构建

```bash
# 1. 获取官方 Web 运行时包（zcode-<ver>.tar.gz）：
#    a) GitHub Actions：本仓库 push 后自动构建（upstream.version 钉住上游版本）
#    b) 本地构建上游：clone zai-org/ZCode，Node 24.14.0 + pnpm 10.33.2
#       pnpm bootstrap && pnpm build:zcode --base-url http://127.0.0.1/zcode/
#       产物在 dist/zcode/releases/<ver>/zcode-<ver>.tar.gz
#    把 tar.gz 放到 packaging/fnOS/dist/runtime/

# 2. 打 fpk（Windows Git Bash / Linux 均可，需 fnpack）
bash packaging/fnOS/scripts/build.sh
# 产物：packaging/fnOS/dist/zcode-<ver>.fpk
```

也可以指定运行时包路径：`bash packaging/fnOS/scripts/build.sh --runtime /path/to/zcode-3.14.1.tar.gz`。

## 目录结构

```
packaging/fnOS/
├── manifest              # 应用元信息（platform=all、nodejs_v22 依赖、端口 8988）
├── cmd/                  # 生命周期脚本（main / install / upgrade / uninstall / config）
├── config/               # privilege（run-as: package）与 resource（工作区共享目录）
├── ui/config             # 飞牛桌面入口（iframe → :8988）
├── ui-images/            # 图标（取自 ZCode 官方桌面版资源）
└── scripts/build.sh      # 解包官方 runtime → 组装 stage → fnpack 打包
.github/workflows/build.yml  # 自动构建官方 runtime 并产出 fpk
upstream.version             # 钉住的 ZCode 版本
```

## 许可

- ZCode：[Apache-2.0](https://github.com/zai-org/ZCode/blob/main/LICENSE)（© Z.ai）
- 本仓库的移植与打包脚本：Apache-2.0
- 图标来自 ZCode 官方桌面版资源，版权归 Z.ai 所有
