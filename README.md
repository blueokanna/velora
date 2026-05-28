# Velora

<p align="center">
  <img src="assets/light.png" width="96" height="96" alt="Velora logo">
</p>

Velora 是一个面向生产环境的跨平台小说阅读器，使用 Flutter 负责界面、动效、导航和平台整合，使用 Rust 负责书籍解析、目录索引、正文读取、在线书源抓取和书架存储。项目围绕本地大文件阅读、Material Design 3 体验、跨语言界面和自动化验证链路进行了完整设计，当前覆盖 Android、iOS、macOS、Windows、Linux、Web。

## 法律与合规声明

本项目仅可用于处理、阅读、调试、研究和验证用户依法享有授权、许可或其他合法权利的内容。严禁将本项目或其任何衍生版本用于抓取、聚合、解析、传播、分享、引流、售卖、推广、镜像、规避保护措施，或以任何直接、间接方式协助获取、分发未经权利人授权的作品、站点资源、书源规则、深度链接规则及其他侵权内容。

请勿效仿、从事或传播任何侵权活动，切勿触碰法律红线，也不要抱有任何侥幸心理。法律底线不可逾越，违法违规必将付出代价；任何以“技术中立”“只做链接”“只提供规则”“仅供学习交流”为名实施的盗版聚合、深度链接侵权、非法引流或变现行为，均不构成免责理由。

结合公开案件披露的信息可见，侵权风险不仅存在于直接上传盗版内容的场景，也存在于通过软件、书源规则、解析逻辑、深度链接、社群传播和商业化引流等方式，对盗版内容进行聚合、适配展示和规模化传播的行为中。相关案件已经表明，此类行为一旦具有明确故意并造成实质性传播与获利后果，可能触及著作权侵权乃至刑事法律责任。

任何用户、开发者、贡献者或分发者在使用、修改、部署、传播本项目时，均应自行确保其行为完全符合所在地及目标市场适用的著作权法、网络安全法、数据合规规则、平台规则及其他法律法规。因将本项目用于任何侵权、违法或违规活动而产生的一切风险、责任、损失与法律后果，均由行为人自行承担，与本项目作者及贡献者无关。

## 产品图

| 亮色主题设置 | 暗色主题设置 |
| --- | --- |
| <img src="assets/image.png" width="260" alt="Velora README preview"> | <img src="assets/image-3.png" width="260" alt="Velora settings preview"> |
| 书源导入 | 书源管理 |
| <img src="assets/image-1.png" width="260" alt="Velora source import preview"> | <img src="assets/image-2.png" width="260" alt="Velora source management preview"> |

## 产品能力

- 本地阅读支持 TXT、EPUB、MOBI、AZW3。
- TXT 自动识别 UTF-8、GBK、Big5、Shift_JIS 等常见编码。
- EPUB 按 OPF spine 管理章节顺序并保留章节文本边界。
- MOBI/AZW3 支持未加密、可直接读取文本记录的文件；DRM、HUFF/CDIC 压缩或无法安全解码的输入会明确报错。
- 离线书籍会优先读取 EPUB 内嵌标题、作者和封面；TXT、MOBI、AZW3 等缺失元数据时，可基于书名从公开页面补全标题、作者、简介和封面 URL。
- 在线元数据查找面向 Qidian、Fanqie Novel、Qimao、Tadu、17K、Faloo、GoodNovel、Wuxiaworld、Royal Road 等公开小说页面，只处理书名、作者、简介、封面等基础元数据，不抓取正文内容。
- 在线阅读兼容 Legado 风格书源 JSON，支持搜索、详情、目录、正文抓取和封面 URL 提取。
- 书源导入支持直接粘贴 JSON、HTTP(S) 书源地址、阅读类 `yuedu://` 在线导入链接，以及常见社区聚合页面中的 JSON 片段。
- 阅读器使用渐进分页与阶段化加载，不在首开时一次性阻塞主线程。
- 打开书籍时展示共享容器过渡、骨架屏、进度条和百分比，减少感知卡顿。
- 阅读页支持点击翻页、拖拽跟手翻页、目录面板、书签面板、阅读设置和应用设置跳转。
- 仿真翻页支持实时拖拽跟手、非线性拖拽进度、卷页阴影、高光折痕和章节边界连续衔接。
- 阅读设置支持翻页效果、字号、行高、页边距、阅读字体等持久化配置。
- 主题系统支持浅色、深色、跟随系统、Pantone 2026 Cloud Dancer、Monet 动态色和 AMOLED。
- 多语言界面当前覆盖简体中文、繁体中文、英文、日文、韩文、德文，设置页只暴露已完整实现的语言。

## 架构概览

- Flutter 层负责应用壳、导航、Material Design 3 组件、响应式布局、状态持久化和平台集成。
- Rust 层负责书籍解析、目录提取、章节读取、在线书源请求与书架存储。
- Flutter 与 Rust 通过 flutter_rust_bridge 通信，阅读器和测试环境都能显式注入动态库、文档目录和 SharedPreferences。
- 阅读器首屏使用渐进分页策略，在帧间主动让出 UI，后续页面按需继续追加，避免大文件打开时整页冻结。

## 启动与测试注入机制

本项目的应用启动入口已经拆分为两层：

- `bootstrapVeloraApp` 负责正式启动应用、注入 SharedPreferences、运行 `beforeRun` 钩子并挂载应用树。
- `prepareVeloraBootstrap` 负责可测试的准备阶段，支持显式注入 Rust 外部库、文档目录、SharedPreferences 和存储初始化函数。

这套设计的目标是让集成测试和组件测试不依赖真实平台插件或固定目录：

- Windows VM 下的集成测试会显式加载 `rust/target/debug/deps/rust_lib_velora.dll`。
- 集成测试使用临时文档目录，避免污染真实阅读数据。
- 集成测试使用 mock SharedPreferences，避免缺失插件通道时直接失败。
- Google Fonts 在测试环境中关闭运行时抓取，避免因 `path_provider` 缓存路径缺失导致用例不稳定。

## 图标与品牌资源

仓库中的品牌主图位于 `assets/light.png` 和 `assets/dark.png`。

- `assets/light.png` 作为 Android、iOS、macOS、Windows、Linux、Web 的主应用图标源。
- `assets/dark.png` 作为 Web 深色 favicon 以及 Android adaptive monochrome 图标源。
- Android 已补齐 `roundIcon`、adaptive icon、monochrome icon 和背景色资源。
- Web 已补齐深浅主题 favicon 切换逻辑，并同步更新站点主题色。
- Windows 已生成主图标 `windows/runner/resources/app_icon.ico`，同时保留深色版本 `app_icon_dark.ico` 以便后续扩展原生切换逻辑。
- iOS 与 macOS 的 `AppIcon.appiconset` 已按各尺寸要求重新生成。

图标产物的标准生成入口是：

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\generate_icons.ps1
```

如果执行策略限制脚本运行，也可以在 PowerShell 会话中以内存脚本块方式执行：

```powershell
$script = Get-Content -Raw .\tool\generate_icons.ps1
& ([scriptblock]::Create($script)) -Root (Get-Location)
```

## 平台渲染与图形适配

Velora 不会也不能通过应用仓库直接安装、升级或替换系统级显卡驱动。生产环境里的图形驱动由目标设备操作系统和 GPU 厂商维护，应用侧只能保证渲染链路、资源尺寸、硬件加速开关和引擎接入方式正确。

当前项目采用的渲染适配原则如下：

- Android 由 Flutter 引擎按设备能力在 Vulkan 与 OpenGL ES 路径间选择合适后端，Activity 已开启硬件加速。
- iOS 与 macOS 使用 Flutter 的 Metal 渲染链路。
- Windows 使用 Flutter 桌面嵌入层和系统图形后端。
- Linux 使用 GTK 宿主与 Flutter Linux 嵌入层。
- Web 使用 Flutter Web 运行时与浏览器图形栈。

这意味着应用层已经完成了自己应该承担的适配工作：资源尺寸、图标链路、窗口尺寸、硬件加速、主题适配、阅读页阴影与排版都由仓库代码控制；真正的系统驱动升级仍然必须在操作系统层面完成。

## 目录结构

- `lib/app.dart`：应用根组件、主题注入、本地化与路由挂载。
- `lib/main.dart`：正式启动入口、测试可注入启动准备阶段。
- `lib/features/bookshelf`：书架、导入、封面卡片、打开入口。
- `lib/features/reader`：阅读器、渐进分页、目录、书签、阅读设置、加载过渡。
- `lib/features/settings`：主题、语言、翻页效果和全局配置。
- `lib/router`：主壳层导航与阅读器过渡路由。
- `lib/state`：Riverpod 状态与 SharedPreferences 持久化。
- `lib/theme`：主题色、字体、Motion token 和阅读排版。
- `lib/widgets/page_turn.dart`：翻页状态机、拖拽跟手、卷页阴影和转场表现。
- `rust/src/api/book_file.rs`：本地书籍格式解析与章节读取。
- `rust/src/api/storage.rs`：书架与元数据持久化。
- `integration_test`：设备级路径验证。
- `test`：Dart 单元与组件测试。
- `tool/generate_icons.ps1`：全平台图标生成脚本。

## 自动化测试覆盖

当前已经覆盖以下关键路径：

- 本地书籍打开到阅读页。
- 加载态与直接进入阅读页两种打开路径。
- 界面语言切换为德语后的导航与设置文案更新。
- 阅读页工具栏稳定跳转系统设置页。
- 阅读页阅读设置面板稳定打开并展示字体选项。
- 仿真翻页的点击、调试预览、实际拖拽完成翻页和边界回调。
- 设置页的语言、主题模式和翻页效果切换。
- 启动准备阶段的目录与 SharedPreferences 注入。
- Rust 层对 TXT、EPUB、MOBI 的格式边界验证。

## 开发命令

```powershell
flutter pub get
flutter_rust_bridge_codegen generate --config-file D:\RustProject\velora\flutter_rust_bridge.yaml
flutter analyze D:\RustProject\velora
flutter test D:\RustProject\velora\test
flutter test D:\RustProject\velora\integration_test\reader_flow_test.dart
flutter test D:\RustProject\velora\integration_test\simple_test.dart
cargo check --manifest-path D:\RustProject\velora\rust\Cargo.toml
cargo test --manifest-path D:\RustProject\velora\rust\Cargo.toml
powershell -ExecutionPolicy Bypass -File D:\RustProject\velora\tool\generate_icons.ps1
```

## 当前验证基线

- `flutter analyze D:\RustProject\velora` 通过。
- `flutter test D:\RustProject\velora\test` 通过。
- `flutter test D:\RustProject\velora\integration_test\reader_flow_test.dart` 通过。
- `flutter test D:\RustProject\velora\integration_test\simple_test.dart` 通过。
- `cargo test --manifest-path D:\RustProject\velora\rust\Cargo.toml` 通过。

## 书源 JSON 字段

Velora 当前支持以下核心字段：

```json
{
  "name": "书源名称",
  "url": "https://example.com",
  "enabled": true,
  "search_url": "https://example.com/search?q={key}",
  "search_list": ".book",
  "search_name": ".name",
  "search_author": ".author",
  "search_book_url": "a",
  "search_cover": "img.cover",
  "book_info_name": "h1",
  "book_info_author": ".author",
  "book_info_intro": ".intro",
  "book_info_cover": ".cover img",
  "book_info_toc_url": ".toc a",
  "toc_list": ".chapter",
  "toc_name": "a",
  "toc_url": "a",
  "content_selector": "#content"
}
```

CSS Selector 会基于响应 URL 自动解析相对链接，正文抓取结果进入统一阅读器分页与进度恢复流程。Velora 也兼容常见的 `bookSourceName`、`bookSourceUrl`、`searchUrl`、`ruleSearch`、`ruleBookInfo`、`ruleToc`、`ruleContent` 字段，并会把 `coverUrl` 映射为封面选择器。

## 许可证声明

本项目采用 GNU Affero General Public License v3.0 (AGPL-3.0) 进行许可，并在仓库根目录提供完整 `LICENSE` 文本。任何对本项目的复制、修改、再分发、二次开发、托管部署或通过网络向用户提供服务的行为，均应遵守 AGPL-3.0 的强制开源要求，并向接收者或服务使用者提供对应版本的完整源代码、修改说明及许可证文本。

本项目不授权任何人使用 Velora 或其衍生版本实施侵权、规避技术保护措施、聚合盗版资源、传播未经授权作品、非法引流或商业化变现。上述合规限制不削弱 AGPL-3.0 赋予的自由软件权利，而是作为项目用途边界、风险告知和附加合规声明存在。

Copyright (C) 2026-present blueokanna