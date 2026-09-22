#!/usr/bin/env bash
#
# 构建飞牛 fnOS 原生应用包（.fpk）
# ================================
# 产物：packaging/fnOS/dist/zcode-<version>.fpk
#
# payload 不是本仓库的源码，而是 ZCode 官方的 Web 运行时包
# （zcode-<version>.tar.gz，由上游 `pnpm build:zcode` 产出）：
#     runtime/bin/zcode.mjs + server/ + agent/ + web/ + node_modules/
#
# 运行期用应用中心的 nodejs_v22（manifest install_dep_apps 声明），
# node_modules 里是官方预编译的 node-pty 等原生件（linux-x64 + linux-arm64），
# 因此单个包即可通吃 x86_64 / arm64（platform = all）。
#
# 用法：
#   bash packaging/fnOS/scripts/build.sh                       # 用 dist/runtime/ 里已就位的 runtime
#   bash packaging/fnOS/scripts/build.sh --runtime <tar.gz>    # 指定官方运行时包
#   ZCODE_VERSION=3.14.1 bash packaging/fnOS/scripts/build.sh  # 覆盖版本号
#
# ⚠ fnpack 打 app.tgz 时会把权限拍平成 0666/0777（官方模板同款行为），
#   可执行位由 cmd/install_callback 在装机时补回。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${HERE}/.." && pwd)"                 # packaging/fnOS
REPO="$(cd "${PKG_DIR}/../.." && pwd)"              # 仓库根
APP="zcode"

DIST="${PKG_DIR}/dist"
STAGE="${PKG_DIR}/.build-staging/${APP}"            # 交给 fnpack 的目录
APP_DIR="${STAGE}/app"                              # 应用内容树（会打成 app.tgz）

FNPACK="${FNPACK:-C:/Users/User/Desktop/FNOS/fnpack}"
NODE="${NODE:-node}"

### 本机 Windows 的 Git Bash shim 关闭了 MSYS 路径转换：
### 传给原生 exe（node / fnpack）的 /c/Users/... 会被原样理解成 C:\c\Users\...。
### 凡是跨到原生进程的路径，一律先转 Windows 形式。
winpath() {
    cygpath -w "$1" 2>/dev/null || echo "$1"
}

# ── 定位官方运行时包 ─────────────────────────────────────────
RUNTIME_TGZ="${1:-}"
if [ "${1:-}" = "--runtime" ]; then
    RUNTIME_TGZ="${2:-}"
fi
if [ -z "${RUNTIME_TGZ}" ]; then
    # 默认取 dist/runtime/ 下最新的官方包
    RUNTIME_TGZ="$(ls -t "${DIST}"/runtime/zcode-*.tar.gz 2>/dev/null | head -n 1 || true)"
fi
if [ -z "${RUNTIME_TGZ}" ] || [ ! -f "${RUNTIME_TGZ}" ]; then
    echo "✗ 未找到官方运行时包（zcode-<version>.tar.gz）"
    echo "  获取方式（二选一）："
    echo "  1. 上游构建：clone zai-org/ZCode，Node 24.14.0 + pnpm 10.33.2，"
    echo "     pnpm bootstrap && pnpm build:zcode --base-url http://localhost/"
    echo "     产物在 dist/zcode/releases/<ver>/zcode-<ver>.tar.gz"
    echo "  2. GitHub Actions：本仓库 workflow 会自动构建并作为 artifact 上传"
    echo "  然后放到 packaging/fnOS/dist/runtime/ 或用 --runtime 传入"
    exit 1
fi
echo "[build] 运行时包：${RUNTIME_TGZ} ($(du -h "${RUNTIME_TGZ}" | cut -f1))"

# ── 版本号：官方包内 package.json 是单一事实来源 ───────────────
VERSION="${ZCODE_VERSION:-}"
if [ -z "${VERSION}" ]; then
    VERSION="$("${NODE}" -e "
const { createRequire } = require('module');
const { execSync } = require('child_process');
const out = execSync('tar -xOzf ' + JSON.stringify(process.argv[1]) + ' zcode/package.json', {maxBuffer: 1<<24});
process.stdout.write(JSON.parse(out.toString()).version);
" "$(winpath "${RUNTIME_TGZ}")")"
fi
echo "[build] 版本 ${VERSION}"

# ── 干净重建 ─────────────────────────────────────────────────
rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${APP_DIR}" "${DIST}"

# ── 1. 应用内容树：解包官方 runtime ──────────────────────────
echo "[build] 解包官方 runtime → app/runtime"
mkdir -p "${APP_DIR}/runtime"
tar -xzf "${RUNTIME_TGZ}" -C "${APP_DIR}/runtime" --strip-components=1
# tar（Windows 的 bsdtar）会把顶层条目解出来；上游包内是 zcode/ 顶层目录
if [ ! -f "${APP_DIR}/runtime/bin/zcode.mjs" ] && [ -d "${APP_DIR}/runtime/zcode" ]; then
    mv "${APP_DIR}/runtime/zcode/"* "${APP_DIR}/runtime/"
    rmdir "${APP_DIR}/runtime/zcode"
fi

for f in bin/zcode.mjs server/entry-http.js agent/zcode.cjs web/index.html package.json; do
    if [ ! -e "${APP_DIR}/runtime/${f}" ]; then
        echo "✗ 官方 runtime 缺少必需文件: ${f}"
        exit 1
    fi
done
echo "[build] runtime 完整性 ✓ ($(du -sh "${APP_DIR}/runtime" | cut -f1))"

# ── 2. 桌面入口（ui 必须在 app/ 内）──────────────────────────
mkdir -p "${APP_DIR}/ui/images"
cp "${PKG_DIR}/ui/config" "${APP_DIR}/ui/config"
cp "${PKG_DIR}/ui-images/icon_64.png"  "${APP_DIR}/ui/images/icon_64.png"
cp "${PKG_DIR}/ui-images/icon_256.png" "${APP_DIR}/ui/images/icon_256.png"
cp "${PKG_DIR}/ui-images/ICON.PNG"     "${STAGE}/ICON.PNG"
cp "${PKG_DIR}/ui-images/ICON_256.PNG" "${STAGE}/ICON_256.PNG"

# ── 3. 自检 ──────────────────────────────────────────────────
# ui/ 下不得残留 fnpack 模板占位符（否则桌面图标点了没反应）
if grep -rn -e '{port}' -e '{display_name}' "${APP_DIR}/ui" > /dev/null 2>&1; then
    echo "✗ ui/ 里仍有 {port} / {display_name} 占位符 → 桌面图标会点了没反应"
    exit 1
fi
# 双架构预编译件必须都在（platform=all 的底气）
for arch in linux-x64 linux-arm64; do
    if ! find "${APP_DIR}/runtime/node_modules" -path "*${arch}*" | grep -q .; then
        echo "✗ runtime 里缺少 ${arch} 的预编译件，platform=all 不成立"
        exit 1
    fi
done

# ── 4. manifest / cmd / config（都在根目录）──────────────────
echo "[build] 写 manifest"
sed "s/^version  *=.*/version               = ${VERSION}/" \
    "${PKG_DIR}/manifest" > "${STAGE}/manifest"

cp -r "${PKG_DIR}/cmd"    "${STAGE}/cmd"
cp -r "${PKG_DIR}/config" "${STAGE}/config"
chmod 755 "${STAGE}/cmd/"*

# ── 5. 打包 ──────────────────────────────────────────────────
# fnpack 把产物写在它自己的 CWD，所以 cd 到 dist 再调用
FINAL="${DIST}/zcode-${VERSION}.fpk"
rm -f "${FINAL}"
echo "[build] fnpack build → ${FINAL}"
( cd "${DIST}" && "${FNPACK}" build -d "$(winpath "${STAGE}")" )

if [ ! -f "${FINAL}" ] && [ -f "${DIST}/zcode.fpk" ]; then
    mv "${DIST}/zcode.fpk" "${FINAL}"
fi
if [ ! -f "${FINAL}" ]; then
    echo "✗ 没有产出 ${FINAL}"
    ls -la "${DIST}"
    exit 1
fi

echo "[build] ✓ ${FINAL}"
ls -la "${FINAL}"
