<img src="assets/brand/logo-preview.png" width="96" alt="Virtual Location logo">

# 虚拟定位 · Virtual Location

中文 | [English](README.en.md)

通过 USB 将 Mac 与 iPhone 连接，在原生 macOS 地图界面中选择、修改和还原手机定位。界面使用 SwiftUI / MapKit，设备通信由独立的 Python 后台和 pymobiledevice3 提供。

当前桌面版：**0.2.3**。这是需要在本机从源码构建的开发版，生成的 `.app` 仍依赖项目目录与 Python 环境。

## 功能

- **地图选点与搜索**：点击地图、输入经纬度或搜索地点；支持地址联想、清空搜索、回到选点，选点时保持当前地图缩放。
- **坐标系设置**：手工输入默认 GCJ-02，可在设置中切换 WGS84；地图、搜索和收藏保留各自的坐标来源，发送前适配为设备 GPS 坐标。
- **随机偏移**：首次默认关闭，可选 30、50、100、200 米，重启后恢复上次的开关和范围。数值表示以选点为中心的正方形边长。200 米对应 200×200 米，东西、南北各最多偏移 100 米。每次点击「修改定位」都从原选点重新取样。
- **位置收藏**：最多保存 5 个位置，支持重命名和删除，按最新到最老排列；满额时可确认覆盖最老收藏。
- **设备状态与恢复**：自动发现并连接 USB iPhone，显示连接阶段和具体错误，提供还原定位、待清理记录及设置内的诊断导出。
- **外观与语言**：跟随系统／白色／暗黑，中文／英文；菜单栏入口可重新显示窗口。
- **隔离预览**：使用模拟设备走相同后台协议，不连接手机、不申请 Apple 签名。

## 支持范围

| 项目 | 当前要求或验证范围 |
| --- | --- |
| Mac | 已在 Apple Silicon Mac 验证；部署目标为 macOS 14+，最低系统及 Intel Mac 未逐项验收 |
| Swift | Swift 6 工具链；本机验证版本为 Swift 6.4.2 |
| Python | 3.14，版本范围固定为 `>=3.14,<3.15` |
| 依赖管理 | [uv](https://docs.astral.sh/uv/getting-started/installation/)，按 `uv.lock` 安装 |
| iPhone | 仅启用 iOS 26.x；已验证设备为 iPhone 13 / iOS 26.6 |
| 连接 | USB、信任此电脑、解锁手机并开启开发者模式 |

已完成特定设备上的固定位置设置、清除和恢复确认，以及公开地标的地图取点到手机新定位样本对照。其他机型、系统、地区、长时间保持、锁屏和断线行为仍需单独验证。随机偏移已通过范围、发送模型和界面检查，尚未单独实机验收。路线、GPX 和持续移动不在当前功能范围内。

## 构建与预览

获取源码：

```sh
git clone https://github.com/forgeyao/virtual-location.git
cd virtual-location
```

先安装 Xcode Command Line Tools 和 uv，然后在本仓库根目录执行：

```sh
xcode-select --install  # 已安装时可跳过
sh scripts/setup.sh
sh scripts/build-app.sh
```

`setup.sh` 使用 `uv sync --frozen` 创建项目 `.venv`，不会向系统全局安装 Python 包。首次安装依赖需要网络；构建使用本地临时签名，不向 Apple 发送设备硬件标识。

先以模拟设备预览：

```sh
open dist/虚拟定位.app --args --preview
```

预览不访问真实手机；地图和搜索仍可能联网。若已有应用进程，请先通过应用菜单或 `⌘Q` 完整退出，再以预览参数启动。

构建脚本使用 SwiftPM 的 `--build-system native` 适配当前工具链，该参数已有弃用提示，工具链升级后可能需要调整。更多说明见 [使用与验证](docs/使用与验证.md)。

## 连接真实 iPhone

**当前桌面版没有单独的 Apple 签名授权弹窗。** 普通模式会自动准备已接入的设备；若需要个性化开发镜像，将向 Apple 官方服务发送设备硬件标识和 nonce。请先阅读下方「隐私与网络访问」，接受这一行为后再连接设备并启动普通模式。只想查看界面时使用 `--preview`。

```sh
open dist/虚拟定位.app
```

1. 用 USB 连接 iPhone，解锁并信任电脑，按系统要求开启开发者模式。
2. 等待左下角显示绿色「手机已连接」。多台设备同时接入时按稳定顺序连接第一台。
3. 搜索、地图选点或输入坐标；输入 GPS/WGS84 数值时先在设置中选择 WGS84。需要时开启随机偏移并选择范围。
4. 点击「修改定位」。青绿色「定位修改已发送」表示指令已发送，仍需在手机地图核对实际位置。
5. 点击「还原定位」，再在手机地图确认回到真实位置。

连接与重连不会自动应用上次选点；存在未清理会话时会先尝试清除。关闭窗口仍会继续运行，退出应用会尽力清理会话。**拔掉数据线不保证立即恢复真实定位**；断线后请重新连接、还原并在手机上核对。桌面功能没有固定 90 秒自动恢复计时；命令行短时测试的计时与桌面功能不同。

更新应用后要完整退出并重开；仅关闭窗口、再次打开仍可能使用旧进程。移动项目目录后请重新构建，不要把当前 `dist/虚拟定位.app` 当作可独立分发的软件包。

## 坐标说明

GCJ-02 与 WGS84 的选择取决于数值来源。不能仅凭地点在中国或地图品牌为 Apple，就假定所有入口需要相同转换。地图和搜索会核对当前来源；无法确认时阻止发送，避免静默猜测。收藏保存坐标系，旧收藏缺少标记时需确认。

随机偏移在设备 WGS84 坐标上按地面米数计算，原输入、图钉、收藏和视野保持不变。当前短距离球面算法与椭球距离近似差小于 1 米，这不是对手机实际定位精度的承诺。

## 隐私与网络访问

| 场景 | 数据与去向 |
| --- | --- |
| 地图、地点搜索与坐标来源核对 | 由 Apple MapKit / Core Location 服务处理；搜索词、相关坐标和地图区域可能发送给对应服务 |
| 下载开发镜像 | 从配置在源码中的公开 GitHub 镜像下载资源，缓存在 `.state/ddi/` |
| Apple 个性化签名 | 通过 HTTPS 向 `gs.apple.com` 发送所需硬件标识（如 ECID、芯片／主板信息）及 nonce，保持证书校验 |
| 本地数据 | `.state/` 包含收藏坐标、偏好、会话恢复标记及可能涉及设备信息的诊断／签名缓存；不应公开上传 |

项目没有自建的遥测或广告服务，也不要求 Apple 账户密码。签名请求不包含目标经纬度，但地图功能的联网行为与签名请求分开。已挂载合适开发镜像时会跳过签名；重启或开发环境变化后可能再次需要签名，并非一次性操作。详见 [开发镜像说明](docs/开发镜像说明.md)。

命令行通过显式参数允许 Apple 签名：

```sh
# 只读设备发现；输出为派生设备标识，仍不建议公开原始输出
sh scripts/device.sh doctor

# 必要时申请签名并准备设备，不设置目标位置
sh scripts/device.sh --allow-apple-signing prepare
```

## 开发与检查

```sh
.venv/bin/python -m pytest -q
sh scripts/check-swift.sh

# 原生地图点击检查：会打开测试窗口，不访问手机；地图可能联网
sh scripts/check-map-clicks.sh

# 模拟后台完整流程，不访问真实手机
dist/虚拟定位.app/Contents/MacOS/VirtualLocation --preview --ui-smoke

# 检查将被 Git 纳入的文件，不打印匹配到的敏感值
python3 scripts/check-publication.py
```

离线／模拟检查不能替代手机端验收。`.gitignore` 排除了本地状态、构建产物、环境和开发过程记录；已经被 Git 跟踪的敏感文件不会因为新增忽略规则自动消失。检查脚本包含这类文件，但不扫描历史提交。

## 项目结构与文档

```text
Sources/VirtualLocation/  SwiftUI 界面、地图与状态模型
backend/virtual_location/ Python 设备后台、会话与恢复管理
scripts/                  环境、构建、检查与打包脚本
tests/                    Python 离线与模拟测试
tests-swift/              Swift 模型和原生地图点击检查
assets/brand/             应用 logo 与图标
docs/                     使用说明、状态清单和发布检查
```

- [使用与验证](docs/使用与验证.md)
- [状态文案与颜色](docs/状态文案与颜色.md)
- [开发镜像与 Apple 签名](docs/开发镜像说明.md)
- [开源发布检查](docs/开源发布检查.md)

反馈问题时请提供系统版本、操作步骤与脱敏错误信息，不要附上完整 `.state/`、配对文件、签名凭据、设备唯一标识或私人收藏位置。

## 许可证与致谢

本项目采用 **GNU General Public License v3.0 or later（GPL-3.0-or-later）**，许可全文见 [LICENSE](LICENSE)。允许个人及商业使用、修改和再分发；对外分发原版或修改版时，须按 GPL 要求提供对应源码、保留许可声明，并遵守相同许可证等条件。仅自行使用或在组织内部修改，不因此要求向公众发布源码。说明见 [GNU 官方 FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#GPLCommercially)。

- 设备通信依赖 `pymobiledevice3==11.49.0`，其安装包声明许可证为 **GPL-3.0-or-later**；项目许可证不替代第三方许可。
- 坐标转换方程参考 `wandergis/coordtransform`，MIT 许可原文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 应用图标由本项目矢量代码生成；地图内容由 Apple 及其数据提供方提供。

如需分发带依赖的应用或安装包，请另行核对所有第三方依赖及资源的分发要求。
