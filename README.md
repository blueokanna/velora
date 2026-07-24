# Velora

<p align="center">
  <img src="assets/light.png" width="112" height="112" alt="Velora logo">
</p>

<p align="center">
  Flutter + Rust · Material Design 3 · Local books · Legado sources · Comics · Audio · Markdown + LaTeX
</p>

Velora 是一个以 Flutter 和 Rust 构建的本地及在线阅读器。Flutter 负责 Material Design 3 界面、响应式布局、动画、阅读交互和平台插件；Rust 负责本地书籍解析、章节索引、在线书源规则、网络可靠性和书架持久化。

Velora is a local and online reader built with Flutter and Rust. Flutter owns the Material Design 3 interface, responsive layout, motion, reading interactions, and platform plugins. Rust owns local-book parsing, chapter indexes, online source rules, network reliability, and bookshelf persistence.

> Velora 只应用于用户依法拥有或获准访问的内容。项目不附带书源、小说、漫画或音频，也不授权绕过 DRM、验证码、付费墙或站点访问控制。
>
> Velora is only for content that the user owns or is authorized to access. The project ships no sources or copyrighted media and does not authorize bypassing DRM, CAPTCHAs, paywalls, or access controls.

## 中文说明

### 已实现能力

- 本地文本书：TXT、EPUB、未加密 MOBI/AZW3。
- 本地 Markdown：`.md` 和 `.markdown`，保留原始标记并按一级/二级标题生成目录。
- Markdown 渲染：GFM 表格、任务列表、引用、代码块、链接、网络图片和相对路径本地图片。
- 数学公式：行内 `$...$` 与块级 `$$...$$`，由 `flutter_math_fork` 解析和排版。
- 本地漫画：CBZ 或包含图片的 ZIP；图片按自然文件名排序，单页惰性解压，支持缩放和前后页导航。
- 本地音频：MP3、M4A、AAC、OGG、OPUS、WAV、FLAC，支持播放/暂停、15 秒跳转、进度拖动和倍速。
- 在线小说：兼容常见 Legado/阅读书源 JSON 的搜索、详情、目录、正文、封面和发现规则。
- 在线漫画与有声漫画：识别标准 `bookSourceType`，类型 `1` 为音频，类型 `2` 为图片；同一章节可同时携带图片和旁白音频。
- 书架：本地书和在线书均可保存，阅读章节/页进度持久化，支持书签、分享和封面更新。
- 封面：优先使用书内封面；缺失时先按书名和作者查询已导入且启用的书源，再回退到公开元数据页面。
- 字体：可搜索 `google_fonts` 当前版本提供的完整字体目录；只下载并缓存用户选中的字体。
- 第三方字体：导入 TTF/OTF，复制到应用支持目录并按需注册；单文件最大 32MB，最多登记 24 个本地字体。
- 主题：Material Design 3、亮色/暗色/跟随系统、Pantone Cloud Dancer、Monet 动态色和 AMOLED。
- 动画：Material 3 motion token、路由转场、列表入场、加载骨架、滑动/覆盖/淡入淡出/仿真翻页。
- 大文件：TXT 使用流式编码探测、稀疏章节锚点、mmap/seek 范围读取和 sidecar 分页缓存。

### 支持格式与边界

| 类型 | 扩展名/来源 | 实现状态 | 明确边界 |
| --- | --- | --- | --- |
| 纯文本 | `.txt` | 支持 | 自动探测 UTF-8、UTF-16、GB18030/GBK、Big5、Shift_JIS 等常见编码 |
| EPUB | `.epub` | 支持 | 按 OPF spine 读取文本和嵌入封面；复杂脚本和 DRM 不支持 |
| Kindle | `.mobi`, `.azw3` | 有限支持 | 支持未加密、可直接解压的 PalmDOC 文本；DRM 和部分 HUFF/CDIC 不支持 |
| Markdown | `.md`, `.markdown` | 支持 | GFM + 数学公式；不是完整 TeX 文档编译器，不加载任意 LaTeX 宏包 |
| 漫画 | `.cbz`, `.zip` | 支持 | JPG/JPEG/PNG/WebP/GIF；每张解压页设有 64MB 安全上限 |
| 音频 | `.mp3`, `.m4a`, `.aac`, `.ogg`, `.opus`, `.wav`, `.flac` | 支持 | 实际编解码能力仍取决于目标系统媒体栈 |
| 在线文本 | Legado/阅读 JSON | 支持常用静态规则 | 任意 `@js`、Java API、登录 Cookie、浏览器验证和 DRM 不是通用兼容范围 |
| 在线媒体 | `bookSourceType: 1/2` | 支持 | 正文规则必须能直接解析出 HTTP(S) 图片或音频地址 |

“LaTeX 支持”指阅读 Markdown 时可渲染 TeX 数学表达式，包括常用分式、根式、矩阵、上下标、积分、求和、对齐和数学符号。它不等同于运行完整 LaTeX 发行版，因此不会执行文件 I/O、shell escape、自定义系统字体加载或任意第三方宏包。

### 导入与阅读

1. 在“书架”点击导入按钮。
2. 选择受支持的文本、电子书、Markdown、漫画或音频文件。
3. Android 也可以从系统文件管理器使用“打开方式”交给 Velora。
4. 导入后 Rust 会建立元数据和目录；缺少封面时会异步尝试补全。
5. TXT/EPUB/MOBI 使用分页阅读器；Markdown 使用纵向富文本阅读器；漫画使用图片阅读器；音频使用专用播放面板。

本地文件不会被上传。Android 的 `content://` 文档会以流式方式复制到应用私有目录，随后 Rust 只访问稳定的本地路径。

### Google Fonts 与本地字体

阅读设置和全局设置页都可以打开字体浏览器：

- Google 标签列出 `GoogleFonts.asMap()` 暴露的全部字体，可按名称即时搜索。
- 选择字体后，Velora 调用 `GoogleFonts.pendingFonts()` 等待必要字体完成下载/缓存，再保存设置。
- 没有网络或下载失败时不会静默应用半加载字体，而会显示错误并保留可用回退字体。
- 本地标签可导入 TTF/OTF。文件复制到应用支持目录，只有被选择时才通过 `FontLoader` 注册。
- Google Fonts 和第三方字体均可能有独立许可证；用户负责确认目标字体允许相应用途和分发方式。

应用不会一次下载全部 Google Fonts。一次性下载整个目录会造成巨大的存储、流量和启动成本；“完整访问”通过完整可搜索目录实现，“必要下载”通过按选择下载实现。

### 在线书源

书源页支持：

- 直接粘贴单个书源 JSON 或 JSON 数组。
- HTTP(S) JSON 地址、批量文本中的多个地址和常见在线导入链接。
- Legado 常见字段名及 `ruleSearch`、`ruleExplore`、`ruleBookInfo`、`ruleToc`、`ruleContent`。
- CSS selector、常见 XPath 子集、JSONPath 风格字段和正则捕获规则。
- GET/POST 请求描述、请求头、UTF-8/GBK 等响应字符集。
- 发现规则；没有可用发现规则时回退到搜索规则获取首批内容。
- 请求超时、取消、有限重试、每源并发限制、熔断和脱敏健康状态。

XIU2/Yuedu 可使用仓库地址或用户提供的代理地址导入：

```text
https://github.com/XIU2/Yuedu
https://wget.la/https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan
```

该仓库中的书源由第三方维护。规则是否可用取决于目标站点、地区、网络、规则版本和站点反爬策略。Velora 不保证每个第三方书源永久可用。

简化书源示例：

```json
{
  "bookSourceName": "Example",
  "bookSourceUrl": "https://example.com",
  "bookSourceType": 0,
  "enabled": true,
  "searchUrl": "/search?q={{key}}",
  "ruleSearch": {
    "bookList": ".book",
    "name": ".name",
    "author": ".author",
    "bookUrl": "a@href",
    "coverUrl": "img@src"
  },
  "ruleBookInfo": {
    "name": "h1",
    "author": ".author",
    "intro": ".intro",
    "coverUrl": ".cover img@src",
    "tocUrl": ".toc@href"
  },
  "ruleToc": {
    "chapterList": ".chapter",
    "chapterName": "a",
    "chapterUrl": "a@href"
  },
  "ruleContent": {
    "content": "#content"
  }
}
```

漫画源通常使用 `"bookSourceType": 2`，正文规则直接选择漫画图片或其容器。音频源通常使用 `"bookSourceType": 1`，正文规则直接解析音频 URL。图片源中同时出现 `<audio>`/`<source>` 时，Velora 会组成有声漫画章节。

### Material Design 3 与性能

- 所有主题都由 `ColorScheme` 和 `ThemeData(useMaterial3: true)` 构建。
- 主题组件覆盖 AppBar、NavigationBar、NavigationRail、按钮、卡片、Chip、Slider、SnackBar、Dialog 和 BottomSheet。
- 统一 motion token 位于 `lib/theme/motion.dart`，页面和内容动画使用有界时长与 Material 曲线。
- TXT 正文在 Android 上可使用原生 `StaticLayout` 分页和预绑定；动态 Google/本地字体使用 Flutter 文本通道，保证实际字体正确。
- 漫画只惰性解压当前页，列表缓存以视口倍数限制；Flutter 图片缓存仍受引擎全局上限控制。
- 章节文本缓存使用有界 LRU 窗口；在线请求在切换查询或销毁页面时取消。
- `TextEditingController`、`AnimationController`、Timer 和 `AudioPlayer` 均在对应生命周期中释放。

“无内存泄漏”不能只靠声明证明。当前代码明确释放应用自己创建的长期资源，并通过有界缓存避免无界增长；仍建议在目标设备上使用 Flutter DevTools Memory 和 Android Studio Profiler 对真实书籍、字体及媒体进行长时间压力测试。

### 开发环境

CI 固定版本：

- Flutter `3.44.6` stable
- Dart（随 Flutter）
- Rust `1.97.0`
- Java `17`
- `flutter_rust_bridge_codegen 2.12.0`

准备环境：

```powershell
flutter doctor -v
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked
flutter pub get
```

生成桥接代码：

```powershell
flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
```

仓库提交了生成后的 `lib/src/rust` 与 `rust/src/frb_generated.rs`。更改公开 Rust API 后必须使用同版本 codegen 重新生成并提交；只修改私有解析实现时不需要改变桥接 ABI。

运行与构建：

```powershell
flutter run
flutter build apk --debug
flutter build apk --release --split-per-abi
```

### 静态分析与测试

```powershell
flutter analyze --fatal-infos
flutter test test
cargo test --locked --manifest-path rust/Cargo.toml

Push-Location rust_builder/cargokit/build_tool
dart pub get
dart analyze --fatal-infos
Pop-Location
```

Cargokit 是独立 Dart 包，不能由根 Flutter 包在缺少其 `.dart_tool/package_config.json` 的情况下分析。否则会出现：

```text
Target of URI doesn't exist: package:ed25519_edwards/ed25519_edwards.dart
The method 'verify' isn't defined for VerifyBinaries
```

根目录的 `analysis_options.yaml` 排除 `rust_builder/cargokit/**`，工作流则分别分析：

1. 根应用的 `lib`、`test`、`integration_test`。
2. 在 `rust_builder/cargokit/build_tool` 中先执行 `dart pub get`，再独立执行严格分析。

这样根分析不会在错误的包上下文中扫描 Cargokit，而 Cargokit 自身的错误仍会由其独立严格分析捕获。

### GitHub Actions 与发布签名

`.github/workflows/android-release.yml` 在以下情况运行：

- 针对 `main` 的 Pull Request。
- 推送 `v*` 标签。
- 手动 `workflow_dispatch`。

工作流执行 Flutter/Rust 依赖获取、FRB 生成、Cargokit 分析、Rust 测试、Flutter 严格分析、Flutter 测试和分 ABI Release 构建。标签发布还会生成 SHA-256 校验文件并上传 GitHub Release。

标签发布必须配置：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

生成 keystore 的单行 Base64：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('.\velora-release.jks'))
```

未配置 release keystore 的本地构建会使用 debug 签名，仅用于开发验证，不能作为正式商店发布包。

### 当前验证基线

在 Windows 开发机上已实际执行：

- `flutter analyze --fatal-infos lib test integration_test`：零问题。
- `dart analyze --fatal-infos`（Cargokit 子包）：零问题。
- `flutter test test`：48 项通过。
- `cargo test --locked --manifest-path rust/Cargo.toml`：28 项单元测试、8 项格式集成测试通过。
- `flutter build apk --debug`：通过。
- `flutter build apk --release --split-per-abi`：通过，生成 armeabi-v7a、arm64-v8a、x86_64 APK。

本机 Windows 上 `flutter_rust_bridge_codegen generate` 可出现无日志长时间等待；Android Debug/Release 构建使用仓库中已提交且 ABI 未改变的绑定并已通过。GitHub Actions 使用 Ubuntu 和固定 codegen 版本继续执行生成步骤。公开 Rust API 发生变化时，不能用上述说明替代重新生成绑定。

### 目录结构

```text
lib/
  features/bookshelf/       本地导入、书架、封面与分享
  features/discover/        发现、搜索与在线书籍入架
  features/reader/          文本、Markdown、漫画、音频阅读器
  features/settings/        主题、语言与字体浏览器
  services/                 书源适配、元数据、字体与 Android 文档服务
  state/                    Riverpod 状态和 SharedPreferences 持久化
  theme/                    Material 3 主题与 motion token
rust/src/api/
  book_file.rs              TXT/EPUB/MOBI/Markdown/CBZ/音频元数据
  book_source.rs            Legado 规则、在线文本和媒体提取
  source_runtime.rs         超时、取消、重试、熔断和健康状态
  storage.rs                书架持久化
test/                       Flutter 与 Rust 格式集成测试
.github/workflows/          Android CI 和发布流程
```

### 已知限制

- 不支持 DRM 内容。
- 不承诺执行任意 Legado JavaScript、Java API 或浏览器自动化规则。
- 需要登录、Cookie 持久化、验证码或强浏览器指纹的网站可能不可用。
- MOBI/AZW3 仅覆盖当前 Rust 解析器能够安全解码的未加密格式。
- Markdown 数学渲染是 TeX 数学引擎，不是完整 LaTeX 文档系统。
- 在线媒体必须由书源规则直接给出可访问的媒体 URL；不绕过签名、DRM 或授权限制。
- 字体、音频格式和硬件解码最终兼容性受操作系统与设备能力影响。

## English Guide

### Implemented features

- Local text books: TXT, EPUB, and unencrypted MOBI/AZW3.
- Local Markdown: `.md` and `.markdown`, preserving source markup and building a table of contents from level-one and level-two headings.
- Markdown rendering: GFM tables, task lists, quotes, code blocks, links, remote images, and document-relative local images.
- Math: inline `$...$` and display `$$...$$`, parsed and laid out by `flutter_math_fork`.
- Local comics: CBZ or image ZIP archives, naturally sorted by path, lazily decompressed one page at a time, with zoom and chapter/page navigation.
- Local audio: MP3, M4A, AAC, OGG, OPUS, WAV, and FLAC with play/pause, 15-second seek, scrubber, and speed controls.
- Online novels: common Legado/Yuedu JSON rules for search, details, TOC, content, covers, and explore feeds.
- Online comics and narrated comics: standard `bookSourceType` values, where `1` is audio and `2` is image content. A chapter may contain both pages and narration.
- Bookshelf: local and online entries, persisted chapter/page progress, bookmarks, sharing, and cover updates.
- Covers: embedded cover first; imported enabled sources by title/author second; public metadata pages as the final fallback.
- Fonts: searchable access to every family exposed by the pinned `google_fonts` package, downloading and caching only the selected family.
- Third-party fonts: TTF/OTF import into application support storage and lazy runtime registration. Each file is capped at 32MB and the catalog at 24 local fonts.
- Theme: Material Design 3, light/dark/system, Pantone Cloud Dancer, Monet dynamic color, and AMOLED.
- Motion: Material motion tokens, route transitions, staged result entry, loading skeletons, and slide/cover/fade/curl page turns.
- Large TXT files: streaming encoding detection, sparse chapter anchors, mmap/seek range reads, and sidecar pagination caches.

### Format support and boundaries

| Type | Extension/source | Status | Boundary |
| --- | --- | --- | --- |
| Plain text | `.txt` | Supported | Common UTF-8, UTF-16, GB18030/GBK, Big5, Shift_JIS, and related encodings |
| EPUB | `.epub` | Supported | OPF spine text and embedded covers; no DRM or arbitrary script execution |
| Kindle | `.mobi`, `.azw3` | Limited | Unencrypted PalmDOC text that can be decoded safely; no DRM and incomplete HUFF/CDIC coverage |
| Markdown | `.md`, `.markdown` | Supported | GFM plus math; not a complete TeX distribution and does not load arbitrary LaTeX packages |
| Comics | `.cbz`, `.zip` | Supported | JPG/JPEG/PNG/WebP/GIF with a 64MB decompressed-page safety limit |
| Audio | `.mp3`, `.m4a`, `.aac`, `.ogg`, `.opus`, `.wav`, `.flac` | Supported | Codec availability still depends on the target OS media stack |
| Online text | Legado/Yuedu JSON | Common static rules | Arbitrary `@js`, Java APIs, authenticated cookies, browser challenges, and DRM are out of scope |
| Online media | `bookSourceType: 1/2` | Supported | Content rules must resolve directly accessible HTTP(S) image/audio URLs |

LaTeX support means TeX math expressions inside Markdown, including common fractions, roots, matrices, scripts, integrals, sums, alignment, and symbols. It does not execute a full LaTeX distribution, filesystem I/O, shell escape, arbitrary packages, or document-level typesetting.

### Import and reading

1. Use the import action on the Bookshelf page.
2. Select a supported text, ebook, Markdown, comic, or audio file.
3. On Android, files can also be sent to Velora through the system Open With action.
4. Rust builds metadata and a chapter index. Missing covers are resolved asynchronously when possible.
5. TXT/EPUB/MOBI use the paginated reader; Markdown uses the rich scrolling reader; comics and audio use dedicated media surfaces.

Local files are not uploaded. Android `content://` documents are streamed into private app storage so Rust receives a stable local path instead of a large in-memory byte array.

### Fonts

The font browser is available from reader settings and global settings:

- The Google tab lists all families returned by `GoogleFonts.asMap()` and supports live name search.
- Selecting a family waits for `GoogleFonts.pendingFonts()` before persisting the setting.
- A failed or offline fetch reports an error instead of silently selecting a half-loaded font.
- The Local tab imports TTF/OTF files. Files are copied into application support storage and registered with `FontLoader` only when selected.
- Google and third-party fonts have their own licenses. Users and distributors must verify that their intended use is permitted.

Velora intentionally does not download the entire Google Fonts catalog. Full access is provided as a searchable catalog; necessary assets are downloaded on selection to avoid unbounded traffic, storage, and startup cost.

### Online sources

The Sources page accepts direct JSON, JSON arrays, HTTP(S) JSON URLs, multiple URLs in pasted text, and common import links. The runtime covers common Legado field aliases, CSS selectors, a practical XPath subset, JSONPath-like rules, regular-expression captures, GET/POST descriptors, headers, and legacy response charsets.

Explore rules feed the Discover page. Sources without a usable explore rule fall back to their search rule for an initial batch. Requests have cancellation, timeouts, bounded retry, per-source concurrency limits, circuit breaking, and redacted health telemetry.

The XIU2/Yuedu repository can be imported through the URLs shown in the Chinese section. It is third-party content and its availability depends on target sites, region, network, rule age, and anti-bot changes. Velora cannot guarantee permanent compatibility with every source.

For text, use `bookSourceType: 0`. For audio, use `1`; for image chapters, use `2`. Image sources that also expose an `audio` or `source` element become narrated comic chapters.

### Material 3, performance, and lifecycle

- Every theme is built from `ColorScheme` and `ThemeData(useMaterial3: true)`.
- Component themes cover navigation, app bars, buttons, cards, chips, sliders, snack bars, dialogs, and bottom sheets.
- Shared motion tokens live in `lib/theme/motion.dart` and use bounded durations and Material curves.
- Android may use native `StaticLayout` pagination for supported preset text fonts. Dynamic Google/local families use Flutter text rendering so the selected font is accurate.
- Comic decoding is page-lazy and viewport caching is bounded. Chapter text caches use bounded LRU windows.
- Source requests are cancelled when a query changes or a page is disposed.
- Controllers, animation controllers, timers, and audio players are disposed in their owning lifecycle.

No serious project should claim “zero leaks” based only on source inspection. Velora explicitly releases the long-lived resources it creates and bounds application caches. Real devices should still be profiled with Flutter DevTools Memory and Android Studio Profiler using representative books, fonts, comics, and long audio sessions.

### Development and verification

Use the pinned CI toolchain and commands listed in the Chinese sections above. The important distinction is that the root Flutter package and the nested Cargokit build tool are separate Dart packages. The root analyzer excludes `rust_builder/cargokit/**`, while CI resolves and strictly analyzes that package from `rust_builder/cargokit/build_tool`, so neither dependency-context false positives nor real Cargokit diagnostics are hidden.

The current verified baseline is:

- Strict Flutter analysis: no issues.
- Strict nested Cargokit analysis: no issues.
- Flutter tests: 48 passing.
- Rust tests: 28 unit tests and 8 format/integration tests passing.
- Android Debug APK: built successfully.
- Android Release split APKs: built successfully for armeabi-v7a, arm64-v8a, and x86_64.

On the current Windows development host, the standalone FRB codegen command can wait indefinitely without diagnostics. Android Debug and Release builds succeeded with the checked-in bindings, whose public ABI was not changed by the parser work in this revision. CI continues to run codegen on Ubuntu. Any future public Rust API change requires successful regeneration and committed binding updates.

### License and responsible use

Velora is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

AGPL-3.0 governs copying, modification, distribution, and network deployment of the software. It does not grant rights to books, comics, audio, websites, source rules, fonts, or other third-party material. Users, contributors, distributors, and hosted-service operators are responsible for copyright, privacy, data protection, platform rules, and all other laws that apply to their use.

Copyright (C) 2026-present blueokanna
