# ZCode → 飞牛 fnOS 原生 fpk：可行性评估与落地方案（v2）

- 评估对象：[zai-org/ZCode](https://github.com/zai-org/ZCode)（Apache-2.0，`main` 为 `3.14.0`，官方 CDN 在发 `3.14.1`）
- 目标：飞牛 fnOS 原生应用包，**不使用 Docker**，**一个包同时支持 x86_64 与 arm64**
- 本地可复用资产：`C:\Users\User\Desktop\FNOS\`（fnpack 1.2.3、demoapp 模板）、`NAS-NEM\packaging\fnOS\`（生产级 Node 应用打包模板）、`coolapk-nas\scripts\build_fpk.py`（构建管线）
- 日期：2026-09-22

---

## 1. 结论

**可以做，而且不需要把 Electron 搬上飞牛。更关键的是：这条路你已经在两个 Node 应用上跑通并真机验收过了，ZCode 只是把同一套做法套到另一个纯 Node 服务上。**

ZCode 仓库自带一条「无 Electron」的运行时链路：

```
zcode --web --host 0.0.0.0 --port <PORT> --workspace <目录> --no-open [--token <T>]
```

它由 `web/`（Vite+React 前端，**与桌面端共用 `@zcode/ui`**）+ `server/`（Hono HTTP/WebSocket 服务）+ `agent/zcode.cjs`（agent 子进程）组成，`pnpm build:zcode` 就是官方产出这套运行时的命令。

对照你 `NETEASE_CLOUD_MUSIC` 的成熟形态：**同样是"纯 Node 服务端 + 浏览器前端 + `install_dep_apps = nodejs_v22` + `platform = all` 一包通吃双架构"**。区别只有一个：ZCode 的包里带了原生模块（`node-pty`，以及 TUI 路径用的 koffi / opentui 预编译件），而你之前两个 Node 应用是"包内原生模块数量为 0"。这个差异是**本方案唯一需要真机验证的核心风险**，其余环节你都有现成代码。

**不要**把 Electron 本体塞进 fpk：虽然官方**已经提供 Linux x64/arm64 的现成桌面安装包**（实测 AppImage 195 MB、deb 148–155 MB，无需编译），但要在没有桌面环境的 NAS 上显示窗口，必须再打包 Xvfb + x11vnc + noVNC 和一整套 X11/GTK/NSS 库——而 fpk 不能 `apt install`，这些库只能自己塞进去；再加上无 GPU 软件渲染、体验退化成远程桌面。收益只有"界面 1:1"，而方案 A 的界面本来就来自同一套组件。

---

## 2. 关键事实

### 2.1 ZCode 侧（已核实）

| 事实 | 出处 |
|---|---|
| server 端唯一原生模块是 `node-pty`，且直接依赖 `@lydell/node-pty-linux-x64`、`-linux-arm64` **预编译包** | `packages/server/package.json` |
| 其余依赖全是纯 JS：hono、@hono/node-ws、ssh2、undici、ws、yaml、yauzl/yazl、node-forge、axios | 同上 |
| runtime 包会收录 **6 个平台**的原生资源（`@mbears/opentui-core-<os>-<arch>`、`build/koffi/<triplet>/koffi.node`、`prebuilds/<os>-<arch>/unsafe-pointer.glibc.node`），按架构分目录互不冲突 → **tarball 本身是多架构的** | `scripts/zcode-distribution/assets.mjs` |
| 打包 node_modules 时用 `dereference: true` 拷贝 → **产物里没有符号链接**（这一点很关键，见 §4.2 fnpack 权限说明） | 同上 |
| 启动器 `bin/zcode.mjs` 会 spawn 一个子进程跑 server，并再 spawn agent（共 **3 个进程**：runner / server / agent） | `scripts/zcode-distribution/runner.mjs` |
| 绑非本机地址时**默认自动生成 token**；token 通过 URL `?token=` 传给前端 | 同上 |
| server 只认 4 个环境变量：`PORT` / `ZCODE_SERVER_HOST` / `ZCODE_WEB_STATIC_ROOT` / `ZCODE_SERVER_AUTH_TOKEN`，**不支持 Unix socket** | `packages/server/src/entry-http.ts` |
| 开发态工具链钉 Node **24.14.0** + pnpm 10.33.2 | `mise.toml` |
| 仓库**没有 Release / tag**，CLI/Web runtime 包无公开下载地址；官网只公开桌面版 | GitHub API + 站点探测 |
| 官方 CDN 上**公开可读**按架构的远程运行时清单：`.../electron/releases/3.14.1/manifest-linux-{x64,arm64}.json`，列出 7 个组件与 sha256，其中 **`node-runtime` = Node v22.16.0** | CDN 实测 |
| 但组件 tarball 本身取不到（各种路径/编码均 404） | 多轮探测 |

> **Node 版本口径**：仓库开发态钉 24.14.0，而官方发给远程 Linux 主机的运行时是 **Node 22.16.0**。两个产物不是一回事。你商店里现成能用的、且已被你两个应用在 x86+arm 真机验收过的是 **`nodejs_v22`**。所以默认走 v22，除非实测发现 ZCode runtime 的非 N-API 原生模块在 22 上加载失败。

### 2.2 飞牛 fnOS 侧（含你真机踩出来的坑）

| 事实 | 来源 |
|---|---|
| `fpk` = `tar.gz`；布局：`manifest`、`ICON.PNG`、`ICON_256.PNG`、`cmd/`、`config/` 在**包根**；应用内容树放 **`app/`**；**`app/ui/config` 必须在 `app/` 内** | 你的 `NAS-NEM/packaging/fnOS/scripts/build.sh` |
| **fnpack 会把 `app.tgz` 里的文件权限拍平成 0666、目录 0777**（与官方模板、线上包一致）；`cmd/*` 由 fnOS 在装机时补 0755 | 同上 |
| **fnpack 不认预制的 `app.tgz`，只认 `app/` 目录** | 同上 |
| `ui/config` 里残留 `{port}` / `{display_name}` 占位符 → 桌面图标点了没反应 | 同上自检规则 |
| **`TRIM_SYS_ARCH` 取值是 `x86` / `arm`，不是 `x86_64`/`aarch64`**；写错会导致安装中止，**错误码 10238** | `MiyoQian` 1.0.2 changelog、`coolapk-nas` cmd/main 注释 |
| **`install_init` 阶段 `TRIM_APPDEST` 还不存在**，此时检查它会以 **10237「应用目录不存在」**中止安装 | `coolapk-nas/scripts/build_fpk.py` |
| `install_dep_apps = nodejs_v22` 已被你的 `NETEASE_CLOUD_MUSIC`、`frog-nas` 使用并发布；frog-nas 注明 **x86 与 arm 真机均已验收** | `NAS-NEM/packaging/fnOS/manifest`、`fndepot/README.md` |
| **Node 运行时查找不能写死 `/vol1`**：应用可能装在存储空间2，`find_node` 要先走 `/var/apps` 统一视图，再全卷 glob 兜底 | `NETEASE_CLOUD_MUSIC` 0.4.1 changelog + cmd/main |
| **不能用 `kill -0` 判活**：非属主调用会返回 EPERM，与"不存在"在 shell 里无法区分，会误删 pidfile（而 pidfile 是 fnOS 判状态的依据）→ 用 `/proc` + cmdline 绝对路径匹配 | `NAS-NEM/packaging/fnOS/cmd/main` |
| **进程匹配串必须是绝对路径**：NAS 上常驻着 cwd=/app、cmdline 也叫 `node src/index.js` 的容器进程，短串匹配会误判成自己人 → status 谎报运行 → start 跳过 → 端口不监听 → 桌面白屏，且 stop 的 pkill 会杀掉无关容器 | 同上 |
| `runuser` 会清掉外层环境 → 环境变量必须写在 `bash -c` 内部（`exec env VAR=... node ...`） | 同上 |
| 启动后要等端口真正监听再交差（`/proc/net/tcp` 里查 `:%04X` 的十六进制端口） | 同上 |
| 应用代码放 `TRIM_APPDEST`（只读、升级整体覆盖），用户数据放 `TRIM_PKGVAR` | 同上 |
| `status`：运行 exit 0，未运行 **exit 3**（不是 1） | 飞牛规范 + 你的脚本 |
| 系统是 **Debian 12 (bookworm)**，glibc 2.36（真机 `lsb_release -a` 实证，fnOS v0.8.37） | CSDN 实测帖 |
| ARM 上 `nodejs_v22` 可用（frog-nas 真机验收）；`nodejs_v24` 存在但**未见 arm 实证** | 你的仓库记录 |
| 目录授权（用户自选目录）**要求飞牛 ≥ 1.2.0604**，低于该版本系统不会把授权下发给第三方应用 | `CompareShare` 1.1.7 changelog |
| 面板 UI 只有三种呈现：端口服务 / `index.cgi` / 统一网关（Unix socket） | 官方 `app-entry` 文档 |
| fpk 无签名要求：应用中心「手动安装」或 `appcenter-cli install-fpk` | 官方文档 |
| 大包（>100MB）走 GitHub Releases 分发，不进版本库 | 你的 `fndepot` 做法 |

---

## 3. 方案对比

| | **A. Node 服务化（推荐，有你现成模板）** | B. Electron + Xvfb + noVNC | C. Electron 只当 Node 用 |
|---|---|---|---|
| 做法 | runtime 解包进 `app/`，`cmd/main` 用商店 `nodejs_v22` 起 `zcode --web`，面板 iframe 打开 | 官方 Linux 制品 + Xvfb + x11vnc + noVNC | `ELECTRON_RUN_AS_NODE=1` 跑 server |
| 编译成本 | 需产出一次 runtime（官方 runtime 包无公开地址） | **零编译**（官方 AppImage/deb 实测可下） | 同 A |
| 体积 | 估 60–120 MB | 195 MB(AppImage) / 155 MB(deb)＋X 库 | 更大且无收益 |
| 系统库依赖 | 无 | X11/GTK/NSS/ALSA 一大套，须自行打包 | 无 |
| arm64 | 商店 Node 已在你两个应用上验收 | 有制品，但 X 依赖更难凑 | 同 A |
| 结论 | **选它** | 仅在必须 1:1 桌面界面时考虑 | 淘汰 |

---

## 4. 落地方案

### 4.1 包结构（严格按 fnpack 的实测布局）

```
<stage>/                        # 交给 fnpack build -d 的目录
├── manifest
├── ICON.PNG / ICON_256.PNG
├── cmd/{main,install_init,install_callback,upgrade_init,upgrade_callback,
│        uninstall_init,uninstall_callback,config_init,config_callback}
├── config/{privilege,resource}
└── app/                        # → app.tgz，装机解到 /vol1/@appcenter/zcode
    ├── runtime/                # 官方 zcode-<ver>.tar.gz 解包后的内容
    │   ├── bin/zcode.mjs  server/  agent/  web/  node_modules/
    └── ui/config + ui/images/{icon_64,icon_256}.png
```

> `ui/` **必须在 `app/` 里**；`config/`、`cmd/` 在包根。`fnpack` 会自动把 `app/` 打成 `app.tgz`——不要自己预制。

### 4.2 manifest

```ini
appname               = zcode
version               = 3.14.1
display_name          = ZCode
desc                  = Z.ai 的 AI 编程工作台。原生 Node.js 运行，非 Docker，浏览器 / 飞牛桌面直接用；登录态与工作区保存在 NAS 上。
platform              = all
source                = thirdparty
maintainer            = ...
maintainer_url        = ...
distributor           = ...
distributor_url       = ...
license               = Apache-2.0
desktop_uidir         = ui
desktop_applaunchname = zcode.Application
service_port          = 8988
install_dep_apps      = nodejs_v22
ctl_stop              = true
checkport             = true
changelog             = 首个飞牛原生版本。
```

端口建议避开你已占用的 8140 / 8163 / 8966 / 8970 / 8980 / 11011。

### 4.3 cmd/main（照搬 NAS-NEM 的硬化写法，按 ZCode 的三进程结构改两处）

直接以 `NAS-NEM/packaging/fnOS/cmd/main` 为基线，需要改动/注意的只有：

1. **`find_node()` 原样保留**（跨卷解析：`/var/apps/nodejs_v22/{target/,}bin/node` → `/vol1/@appcenter/nodejs_v22/bin/node` → `command -v node` → `/vol*/@appcenter/nodejs_v*/bin/node`），失败时写 `TRIM_TEMP_LOGFILE` 提示"请确认应用中心已安装 Node.js v22"。

2. **进程识别串换成 ZCode 的**。ZCode 一个服务有 3 个进程，argv 里都会出现 `${APP_DIR}/runtime/...`：

```sh
SERVICE_JS="runtime/bin/zcode.mjs"
PATTERN="${APP_DIR}/runtime"          # 覆盖 runner + server + agent 三个进程
```

   - `pid_alive()` 仍按 NAS-NEM 的写法：查 `/proc/<pid>`、排除僵尸态 `Z`、再核对 `cmdline` 含 `${APP_DIR}/runtime/`。
   - `own_pids()` → `pgrep -f -- "${PATTERN}"`（`--` 必须有，否则 procps 会当成选项）。
   - `stop` 的兜底清理用 `pkill -TERM -f -- "${PATTERN}"` 再 `-KILL`。**注意 runuser 包装导致 pidfile 里记的是 wrapper 的 PID**，所以这条 pattern 兜底不是可选项，是必需品。

3. **启动命令（环境变量写在 `bash -c` 内部，因为 runuser 会清环境）**：

```sh
CMD="cd '${APP_DIR}' && exec env \
HOME='${TRIM_PKGVAR}' \
ZCODE_FPK_APP='${TRIM_APPNAME}' \
'${node}' '${APP_DIR}/runtime/bin/zcode.mjs' --web \
  --host 0.0.0.0 --port '${PORT}' \
  --workspace '${WORKSPACE}' --no-open ${TOKEN_ARG}"
```

   - `${WORKSPACE}`：优先 wizard 里用户填的路径，其次 `TRIM_DATA_SHARE_PATHS`，最后兜底 `${TRIM_PKGVAR}/workspace`。
   - `HOME=${TRIM_PKGVAR}`：让 ZCode 的配置/凭据落在应用数据目录，升级重装不丢（与 coolapk-nas 同款做法）。
   - `${TOKEN_ARG}`：见 §4.4。

4. **端口就绪探测保留**（`grep -q ":$(printf '%04X' "${PORT}")" /proc/net/tcp`，最多等 30 s）。ZCode 首启要拉起 3 个进程，比你的 Python/Node 单进程应用慢，**建议把等待放宽到 45–60 s**，并注意飞牛应用中心的启动健康门限（社区实测约 60 s，超时会判失败并重试 → 因此 `start` 必须幂等，避免起出第二份实例，重复实例会互抢端口）。

### 4.4 访问控制（ZCode 的特殊性：它等于一台能执行 shell 的机器）

你的其他应用是"登录态在应用内"的形态，ZCode Web 则是**直接暴露 agent + 终端**。三个选项：

1. **wizard token（建议默认）**：`wizard/` 放一个 `wizard_token` 字段，`ui/config` 里写 `"url": "/?token=${wizard_token}"`，`cmd/main` 用同一个值传 `--token`。飞牛支持 `${wizard_*}` 占位符（需确认你目标系统版本上的实际行为与字段命名规则）。
2. **固定 token**：构建期生成一个写入 `ui/config` 和脚本（所有安装实例相同，弱，但零依赖）。
3. **不加 token**：绑 `0.0.0.0` 直接开放，靠内网 + 防火墙。**与你的其他应用一致但风险最高**，ZCode 的能力边界远大于音乐/游戏应用，不建议。

进阶（v2）：改用飞牛**统一网关**（Unix socket + `gatewayPrefix=/app/zcode`）复用面板登录态、免端口免 token，但 `entry-http.ts` 只支持 TCP，需要写约 50 行的自定义启动器。

### 4.5 app/ui/config

```json
{
  ".url": {
    "zcode.Application": {
      "title": "ZCode",
      "icon": "images/icon_{0}.png",
      "type": "iframe",
      "protocol": "http",
      "port": "8988",
      "url": "/?token=${wizard_token}",
      "allUsers": true
    }
  }
}
```

注意两点：端口写成**具体数字字符串**（与你的既有应用一致，避免占位符未替换导致图标点了没反应——你的构建脚本已有这条自检）；面板启用 HTTPS 时 iframe 加载 `http://` 会被按混合内容拦掉，此时改 `"type": "url"` 新标签页打开（你在 Telegram 那个应用里处理过自签证书下的类似问题）。

### 4.6 payload 从哪来

1. **自己构建（当前确定可行）**：Node 24.14.0 + pnpm 10.33.2，`pnpm install && pnpm build:zcode` → `dist/zcode/releases/<ver>/zcode-<ver>.tar.gz`。注意：
   - 该命令是**跨平台产出**（`tar -czf` + 按目标平台收集资源），但为避开 Windows 上的 `tar`/权限/软链差异，**建议在 WSL 或 CI 里构建**；
   - 产物里 node_modules 已 `dereference`，无符号链接（对 fnpack 友好）。
2. **抓包试一次**：官方 CDN 上 `manifest-linux-{x64,arm64}.json` 是公开的（已验证），若能从桌面端实际请求里拿到 `components/*.tar.gz` 的可用 URL，就能零编译组装（按 manifest 的 `mount` 字段拼目录 + 校验 sha256）。
3. 有合作渠道的话直接要 CLI/Web 版发行包地址（`ZCODE_DIST_BASE_URL` 在仓库里是空值）。

### 4.7 Node 运行时选择

| 首选 | `install_dep_apps = nodejs_v22`（与你两个已发布应用一致，arm 已验证） |
|---|---|
| 前提 | ZCode runtime 在 Node 22.16.0 上能跑（koffi / opentui / node-pty 能否加载） |
| 若 ABI 不匹配 | 查商店是否有 `nodejs_v24` 且 arm 可用；仍不行则退回"自带 Node"（`app/bin/{x86_64,aarch64}/node`，由 `install_callback` 按 `TRIM_SYS_ARCH` 选一份并 `chmod +x`，与 coolapk-nas 的双架构二进制同款做法） |

**为什么 v22 优先**：官方发给远程 Linux 主机的 `node-runtime` 组件就是 **v22.16.0**，这是最接近"ZCode 官方认可的 Linux Node 版本"的证据；而你仓库的 24.14.0 是开发态口径。koffi 若走 Node-API（N-API）则跨主版本 ABI 稳定，22 与 24 都能加载——这正是要真机实测的那一项。

---

## 5. 工作量（比 v1 评估显著下降，因为模板现成）

| 阶段 | 内容 | 预估 |
|---|---|---|
| P0 真机摸底 | §6 前 5 项：runtime 能否跑、Node 22 能否加载原生模块、端口/终端、iframe 打开 | 0.5–1 天 |
| 抓包探路（可选） | 试一次官方组件能否直接下载，成了就省掉构建链 | 0.5 天 |
| 构建 runtime | `pnpm build:zcode`（WSL/CI） | 0.5–1 天（首次装依赖较久） |
| fpk 打包 | 照 `NAS-NEM/packaging/fnOS/scripts/build.sh` 改一版（含 manifest/cmd/config/ui/图标/自检），fnpack 1.2.3 本机可用 | 0.5–1 天 |
| 生命周期脚本 | 以 NAS-NEM 的 `cmd/main` 为基线改 3 进程识别 + 就绪等待 + 工作区选择 | 0.5–1 天 |
| 双架构真机联调 | x86 + arm：安装/启动/重启自启/升级/卸载 | 1–1.5 天 |
| **合计** | | **约 3–5 天**（不含上架沟通） |

打包机侧你已有全套能力：Windows Git Bash 跑 `fnpack`（注意 `cygpath -w` 转换路径，你 build.sh 里已处理）、`ui/` 占位符自检、`-cli` 变体（去掉 `install_dep_apps` 做对照验收）。

---

## 6. 真机验证清单（P0）

1. `uname -m`、`lsb_release -a`、`ldd --version`（预期 Debian 12 / glibc 2.36，arm 上同样要验）。
2. 商店装 `nodejs_v22`，确认 `find_node` 的各级路径在**非默认卷**上也能解析到。
3. **原生模块 ABI**：用 nodejs_v22 的 node 跑 `require()` koffi、`@mbears/opentui-core-*`、`node-pty`，并打印 `process.versions.modules`。**这是全案唯一的硬风险点。**
4. 官方 runtime 直接跑起来：`node bin/zcode.mjs --web --no-open --port 8988`，浏览器能开、能对话、终端能用（`node-pty` 在非 root、无 TTY 的服务进程里能否 spawn）。
5. 出网：NAS 能否访问 z.ai / bigmodel 等模型 API。
6. 面板 iframe（HTTP / HTTPS 两套面板配置各试一次）能否打开、token 是否生效。
7. **启动健康门限**：冷启动到端口就绪要多久？是否在门限内？重复触发 start 会不会起出第二份实例？
8. **进程回收**：`stop` 后三个进程（runner/server/agent）是否都没了、端口是否释放；`uninstall` 是否干净。
9. 重启 NAS 后自启（注意 `trim_app_center` 的卷挂载时序），`status` 是否准确。
10. 升级：只换 `app/` 里的 runtime，确认 `${TRIM_PKGVAR}` 里的配置/登录态与工作区都保留。
11. 业务冒烟：跑一轮真实长任务（agent 执行命令）时关掉浏览器，回来看任务是否继续（服务端权威，不依赖前端存活）。

---

## 7. 风险登记

| 风险 | 等级 | 应对 |
|---|---|---|
| **原生模块（koffi/opentui/node-pty）与商店 Node 22 的 ABI 不匹配** | **中高** | P0 第 3 项先测；不行则查 `nodejs_v24`（含 arm），再不行自带 Node 双架构 |
| ZCode runtime 版本与 Node 版本口径不一致（仓库 24 / 官方 remote 22.16） | 中 | 以实测为准；v22 有官方 remote 运行时背书 |
| 官方 runtime 包无公开地址，必须自建一次构建链 | 中 | 接受一次性成本；先花半天试抓包 |
| 三进程 + `runuser` 包装导致 pidfile 指向 wrapper、stop 收不干净 | 中 | 以绝对路径 pattern 兜底（NAS-NEM 已验证的写法），ZCode 用 `${APP_DIR}/runtime` 覆盖三进程 |
| 启动慢于飞牛健康门限 → 判失败重试 → 重复实例互抢端口 | 中 | `start` 幂等 + 端口就绪等待；必要时先起轻量占位监听再换真身 |
| ZCode 迭代快（无 release、3.14.x 持续演进） | 中 | 包设计成"壳 + 可替换 runtime"：升级只换 `app/runtime/`，数据和配置在 `TRIM_PKGVAR` |
| 面板 HTTPS 时 iframe 混合内容 | 低 | 入口改 `"type": "url"`，或给服务加 TLS |
| 浏览器自动化（CUA）在 NAS 上不可用 | 低 | 依赖本机 Chromium；属可接受降级 |
| 授权目录需系统 ≥ 1.2.0604 | 低 | 一期用 `data-share` 或 `TRIM_PKGVAR/workspace` 兜底，授权目录作为增强 |

---

## 8. 与 Electron 桌面版的差异（需向用户说明）

- **界面**：同一套 `@zcode/ui` 渲染，主体功能一致；缺桌面外壳特性（系统托盘、原生菜单/快捷键、自动更新、原生文件选择器）。
- **终端**：服务端 `node-pty`，浏览器内可用，体验与桌面端一致。
- **SSH / 远程项目**：不受影响，服务端本来就能 ssh；官方 remote 链路本身就支持部署到 POSIX Linux 主机。
- **浏览器自动化 / CUA**：桌面端内置，NAS 上默认不可用。
- **无 GPU 依赖**：前端是 Web，不涉及。

---

## 附录 A：现成可复用资产清单

| 资产 | 路径 | 用途 |
|---|---|---|
| fnpack 1.2.3 | `C:\Users\User\Desktop\FNOS\fnpack` | 打包（`fnpack build -d <stage>`，产物写在 CWD） |
| 官方模板 | `FNOS\demoapp\` | manifest / config / wizard / cmd 骨架 |
| **生产级 Node 应用模板** | `NAS-NEM\packaging\fnOS\`（cmd/main、manifest、build.sh、ui/config） | **主要基线**：跨卷 find_node、/proc 判活、端口就绪、runuser 环境、自检 |
| 构建管线 | `coolapk-nas\scripts\build_fpk.py`、`NAS-NEM\...\build.sh` | 组织 stage 目录 + 自检 + 调 fnpack |
| 双架构选型范例 | `MiyoQian`（uv/Python）、`coolapk-nas`（Rust musl，`app/bin/{x86_64,aarch64}`） | 需要自带运行时/二进制时照抄 |
| 发布通道 | `fndepot\fnpack.json`（schema v2）+ GitHub Releases | >100MB 的包走 Release 资源 |

## 附录 B：如果一定要保留真 Electron（方案 B）

- 官方制品实测可下：`https://cdn-zcode.z.ai/zcode/electron/releases/3.14.1/linux-x64/ZCode-3.14.1-linux-x64.AppImage`（195 MB）及 `linux-arm64` 版；deb 可用 `dpkg-deb -x` 静态解包，AppImage 用 `--appimage-extract`（无 FUSE 也可）。仓库侧也可 `pnpm bundle:desktop -- --os linux --arch x64|arm64`。
- 额外打包 Xvfb + x11vnc + noVNC + 网关，并把 GTK/NSS/ALSA/X11 依赖库一并塞进 `app/`（fpk 不能 `apt install`）——**这是该方案的主要工作量与最大不确定性**。
- 非 root 跑 Chromium 需处理 sandbox；无 GPU 走软件渲染。
- 参考你 `fndepot` 里 Telegram 应用处理自签证书/ServiceWorker 的经验。
