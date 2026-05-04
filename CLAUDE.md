# Near (lan_chat) — 项目速览

跨平台（macOS / iOS / Android）局域网点对点聊天工具。零配置发现 + WebSocket P2P 传输 + 文本/图片/文件三类消息，无服务器、不落库。

应用展示名 **Near**，包/模块名仍为 `lan_chat`（见 `pubspec.yaml`、`main.dart` 中 `MaterialApp.title`）。

> **构建/启动约定**：在 mac 上要测试时，**直接 `flutter build macos --release` + `open .../Release/lan_chat.app`**。Debug build 跟 Release 是不同 binary，会被 macOS 视为新 app，Local Network / mDNS 权限要重新弹窗授权——容易出现"粘贴 OK 但连不上 peer"这种假阳性。Release build 跟用户日常双击的是同一签名同一路径，权限沿用，所见即所得。

---

## 一、技术栈

- Flutter SDK ^3.11.5，Material 3 + 自定义 Cupertino 路由
- 发现：`bonsoir` ^5.1.0（mDNS / Bonjour）
- 传输：`shelf` + `shelf_web_socket` 当 server，`web_socket_channel` 当 client
- 持久化：`shared_preferences`（仅 myId / myName，不存历史消息）
- 媒体：`image`（压缩）、`file_picker`、`gal`（保存相册）、`open_filex`、`share_plus`、`super_clipboard`、`flutter_linkify` + `url_launcher`
- 字体：`google_fonts`（Hanken Grotesk + JetBrains Mono）

---

## 二、模块划分（lib/）

| 文件 | 职责 |
| --- | --- |
| `main.dart` | App entrypoint。劫持 `debugPrint` 把 `[xxx]` 前缀日志注入 `AppLog`；macOS 用 `MethodChannel('near.window/ready')` 通知原生窗口就绪 |
| `theme.dart` | `AppColors` 调色板 + `AppFonts.body()` / `AppFonts.mono()` 工厂 |
| `discovery.dart` | mDNS 广播 + 监听。服务类型 `_lanchat._tcp`，attributes 携带 `id` / `name`。`updateName()` 通过 stop+start 重新广播触发对端刷新 |
| `transport.dart` | WebSocket 连接管理。dual-stack server、IPv4 lookup、ID 去重、keepalive、redial、文件分块传输 |
| `peer.dart` | `Peer` 模型（id/name/host/port + `online` flag + `lastActiveAt` 用于 LRU 排序）+ `ChatMessage` 模型（含 `SendStatus`、图片 base64 缓存、文件元信息、`bytesTransferred`、offer 三态 flag、`fanout` per-peer 状态表）+ `FanoutState` / `FanoutEntry`（仅 sender 端用，不进 wire format） |
| `chat.dart` | `Chat extends ChangeNotifier`：粘合 discovery + transport，维护 `messages` / `peers` / ack timer / 文件接收 sink；Android 通过 `MethodChannel('lanchat/files')` 走 MediaStore |
| `home_page.dart` | 单文件大屏：Splash / NamePrompt / PeerList / Conversation 全在这里。约 2400 行，是后续优化的主战场 |
| `settings_page.dart` | 改昵称 + 查看调试日志 |
| `log.dart` | 内存环形缓冲，给 settings 页展示 |

---

## 三、关键技术决策（这些是 trial-and-error 沉淀下来的，改之前先理解原因）

### 连接去重 / 双向拨号竞态
两端互相 mDNS 发现后会同时尝试拨号，导致两条 channel。`transport.dart:59`：

```dart
if (!force && myId.compareTo(peerId) > 0) {
  // 我 ID 较大，让对方拨过来；自己不拨
  return;
}
```

服务端在 `hello` 阶段也会做一次 dedupe（`_channels.containsKey(id)` 则关闭新连接）。重连（redial）时也只有 ID 较小的一方负责，避免对称重连风暴。

### IPv4 lookup
mDNS 解析出的主机名（`xxx.local.`）在某些网络下会优先解析到 IPv6 或被系统代理截胡，导致 dial 失败。`transport.dart:67` 强制 `InternetAddress.lookup(..., type: IPv4)` 拿到地址再拨号；server 端用 `anyIPv6` dual-stack 监听以兼容两边。

### Keepalive + 后台恢复探活
- 每条 channel 10s 周期 ping，token 携带时间戳
- App 从后台 resume：`Chat.onAppResumed()` 对所有 connected peer 发 1s 超时的 probe ping，挂的丢弃 + redial。这是修过的实战 bug —— iOS 切后台几秒回来 socket 已经死了但没收到 close frame
- `_keepAliveInterval = 10s` 定在 `transport.dart:26`

### mDNS lost 抖动
改名重广播会触发对端 `lost` 事件。`chat.dart` 里加了护栏：channel 还活着就忽略 lost，避免 peer 列表抖一下消失再出现。

### Peer 生命周期 / LRU 排序
Peer 下线（mDNS lost 且 channel 也已断）**不从 `peers` map 删除**，仅把 `peer.online = false`。这样：
- 用户依然能进入该 peer 的 conversation 看历史聊天记录
- UI 把 presence dot 从绿色 (`AppColors.presence`) 切到灰色 (`AppColors.inkFaint`)
- conversation header sub-line 显示 `@xxxx · offline` 替代 IP

`_onPeerFound` 重新发现旧 peer 时**保留**其 `lastActiveAt`（不重置），保持 LRU 顺序在重连后稳定。

PeerList 排序两层：
1. 有 `lastActiveAt` 的 peer 在前，按时间倒序（最近聊过最上 = LRU）
2. 无 `lastActiveAt` 的 peer 在后，保持 mDNS 发现顺序（新 found 加在最末）

依赖 Dart `List.sort` 是稳定 mergesort，平局保持 `Map.values` 的插入顺序（Dart `Map` = `LinkedHashMap`）。**注意：Map.update（key 已存在时覆盖 value）保留原位置，不会推到末尾**。

`_bumpPeerActivity(peerId)` 在 4 个收发入口（`_onIncoming` / `_onFileOffer` / `send` / `prepareImage` / `sendFile`）调用。peerId == null 表示群发，遍历所有 connected peer 一起 bump（群发对所有人算一次互动）。

主屏 PeerList 的 `N nearby` 数字只算 online peer（自己 + online peers）；CONVERSATIONS section header 右侧在有人 offline 时显示 `online / total` 比值，全员 online 时只显示总数。

PeerList tile 的 meta 行通过顶层 `_peerPreview(chat, peer)` 计算最近消息预览（peer == null 表示 Everyone here），从 `chat.messages` 尾向头扫一次找到第一条匹配。每次 `Chat.notifyListeners` 时整个 PeerList 重 build 重新扫，O(N×M) 但 messages 不持久化、量小，没必要建索引。

### 文件传输协议（offer / accept 握手 + per-peer fanout）
分两段：先协商，再传输；群聊场景按 peer 独立跟踪状态。

1. **协商**：sender 发 `file_offer`（携带 ChatMessage 元数据，无字节）。receiver 根据 `autoAcceptFiles` 设置决定立即回复 `file_accept` 或先把 bubble 标 `awaitingAccept` 等用户点 Accept/Ignore，对应回 `file_accept` 或 `file_decline`
2. **传输**：sender 收到 `file_accept` 后才开始 `file_chunk(id, seq, data=base64)` → `file_end(id)`。chunk size 64KB，每个 chunk 之间 `await Future<void>.delayed(Duration.zero)` 让 event loop 处理网络
3. **群聊 fanout**：`sendFile` 时按 `connectedPeerIds`（私聊则是 `[toId]`）把每个 peer 写进 `msg.fanout` 表，初始 `FanoutState.offered`。`file_offer` 广播给所有 channel
   - **首个 `file_accept` 进来**：该 entry → `sending`，清 `msg.offerPending`（让 progress bar 开始动），单独跑 `sendFileBytes(file, [thatPeerId])`，progress 写到 `entry.bytesTransferred`
   - **`file_decline`**：entry → `declined`（**注意：不是 `failed`**，declined 是接收方主动拒绝，正常终态，不算发送失败）
   - **该 peer 传输 onError**：entry → `failed`（真正的传输错误）
   - 都**不影响其他 peer**（修过 v1 实现里"1 人 decline 误杀全员 / 多 accept 共用一个 progress 变量乱跳 / `_outgoingFiles` 提前清掉"三连 bug）
   - **每条 peer 完成后** 调 `_maybeFinalizeFanout`：所有 entry 都进终态（`delivered` / `declined` / `failed`）才聚合：
     - 任一 delivered → `msg.status=delivered`，`declined=false`
     - 全部 `declined`（无 delivered 无 failed）→ `msg.status=delivered` + `declined=true`（**故意不用 failed，避免触发 `_MessageBubble` 的红色 ⚠️ "Send failed" 图标**）
     - 其他（无 delivered 但有 failed）→ `msg.status=failed`，`declined=false`
     - 最后清 `_outgoingFiles`
   - 文件被读多次（每个 acceptor 一份独立流），实现简单。带宽友好的"一份流广播给所有 acceptors"留作优化项
   - `msg.bytesTransferred` 改为派生：取所有 fanout entry 的最大值，progress bar 单调前进不抖动

文件 ACK 不走 `_ackTimers`，由 `sendFileBytes` 的 onComplete/onError 回调直接改 status —— 文件可能传几分钟，不能用 500ms 文本 ACK 超时来判。

发送方在等待 accept 期间通过 `_outgoingFiles[msgId]` 持有 `File` 对象引用，accept 来到时再打开读取。如果文件已被外部删除，`file.open()` 抛错走 onError 标 failed。

### Android 文件落地
不能写 `getApplicationDocumentsDirectory`（用户看不到），必须走 MediaStore。`chat.dart` 里 `_androidChain[msgId]` 是个 `Future<void>` 链，把 `appendChunk` 串行化，否则原生侧 fd 写入会乱序。`finishIncoming` 收到 `file_end` 时被调用拿到最终 content URI。

iOS / macOS / Desktop 走 `getApplicationDocumentsDirectory()/lanchat_files/{msgId}__{safeName}` 私有目录，再通过 share_plus / open_filex 暴露。

### 图片压缩
长边 > 1280 时 `image.copyResize`，再 `encodeJpg(quality: 80)`。`prepareImage` + `completeImage` 两步：先用原始 bytes 做预览插入会话，压缩跑完后替换 imageBase64 再真正发送，UI 不阻塞。

### 文本 ACK
500ms 超时（`_ackTimeout`）。短了在弱网误判，长了 UX 上 pending 状态拖太久。

### 输入框直接粘贴文件
桌面端从 Finder/Explorer ⌘C 一个文件，到 conversation 输入框 ⌘V 直接发，不走 attach 菜单。实现要点：

1. **读剪贴板文件**：Flutter 内置 `Clipboard.getData(kTextPlain)` 在 macOS 复制文件场景下只能拿到 `public.utf8-plain-text`（文件**名**字符串，不是绝对路径），无法 `File.stat()`。改用 `super_clipboard` 的 `Formats.fileUri` 拿到真正的 `file://` URI 再 `toFilePath()`
2. **拦截 ⌘+V**：`_Compose` 内 TextField 外层包 `Actions(PasteTextIntent: _PasteOverrideAction(_handlePaste))`。EditableText 内部把 `PasteTextIntent` 注册成 `Action.overridable`，外层 Actions 能直接覆盖默认 paste 行为；不需要 hook `FocusNode.onKeyEvent`
3. **fallback**：剪贴板里没文件时，自己读 `Clipboard.kTextPlain` 插到光标位置（`controller.value.selection`），手动模拟原本 paste 的 UX
4. **目录拒绝**：`FileSystemEntity.typeSync` 判断；目录/缺失/超 100 MB 都用 SnackBar 提示，不静默吞掉
5. **移动端**：iOS/Android 剪贴板没有 file URI 概念，`super_clipboard` 自动 no-op，⌘+V 不触发（无键盘）也无影响

> 调试坑：曾以为 macOS ⌘+V 走 `NSTextInputContext.paste:` 会绕过 PasteTextIntent，加了 `FocusNode.onKeyEvent` 拦截。后来发现是 Debug build 跟 Release 是不同 binary，Local Network 权限要重新授权——表现上"粘贴 OK 但发不出去"被误读成拦截方案的问题。**测 paste/连接问题一律 build release 跑**。

---

## 四、设计方案

参考 `../lan-chat-designs/24-near.html`（主屏）与 `25-files.html`（文件交互）。

### 美学方向
克制、近距、安静的工具感，副标语：`link-local · peer-to-peer · no record`。整体接近 Linear / Things / Telegram 的克制工具风，刻意避开社交平台的高饱和与喧闹感。

### 色板（`theme.dart`）
| token | hex | 用途 |
| --- | --- | --- |
| `bgApp` | `#FFFFFF` | 主背景 |
| `surface` / `surface2` | `#F7F8FA` / `#F0F2F5` | 卡片 / 灰底头像 |
| `line` / `line2` | `#E8EAEF` / `#D8DCE3` | 1px 描边 |
| `ink` / `ink2` / `ink3` / `inkFaint` | 四级墨色 | 文字层级 |
| `accent` | `#4A6E87` slate teal | 主色（自己头像、强调字） |
| `accentSoft` / `accentDeep` | `#E8EEF3` / `#36546A` | 浅色背景态 / 按下态 |
| `presence` | `#5FB288` | 在线绿点 |

### 字体
- 正文 / 标题：**Hanken Grotesk**（400/500/600/700）
- 等宽 / handle / 元数据 / 系统提示：**JetBrains Mono**（设计稿用 Geist Mono，工程上用 JetBrains Mono 替代）

### 屏幕结构
1. **Splash**：3 秒最低展示 + 450ms 淡出（`home_page.dart:_bootstrap`）
2. **NamePrompt**：首次启动输入昵称
3. **PeerList（主屏）**
   - Hero header：自己头像 + 昵称（18px/700/-0.3 letter-spacing）+ `@xxxx` short handle（mono 11px）；整块点击进 Settings
   - Room meta 卡：4 张堆叠 mini avatar（**仅 online peer**）+ "N nearby in this room" + mono 副标
   - SECTION header：mono 11px / 0.66 letter-spacing 大写；右侧显示 `online / total` 比值（全员 online 时仅显示总数）
   - Peer 列表：群聊 `Everyone here` 置顶，下面是 peer 条目（unread badge）
     - **LRU 排序**：聊过的浮在前（按 `lastActiveAt` 倒序），没聊过的按发现顺序排在后
     - **meta 行 = 最近消息预览**（IM 会话列表风格，不再显示 hostname）：
       - 私聊：双向都只显示 body，不加 sender 前缀（avatar + title 已经表明是谁）
       - `Everyone here`：对方发的加 `{fromName}: ` 区分谁说的；自己发的不加前缀
       - 文件 → `fileName`；图片 → `Photo`；文本 → 多行折叠成单行（`\s+ → ' '`）
       - 没匹配消息时 fallback：peer → host name（mDNS hostname）/ `offline`；group → `N in the room · open to all`
     - **Offline peer 不删除**：保留在列表中，presence 点变灰（`AppColors.inkFaint`），meta 在没消息记录时显示 `offline`
4. **ConversationPage**：自定义 `_FastCupertinoRoute`（300ms in / 260ms out），分日期分隔（Today / Yesterday / M/D HH:MM），消息泡 + 状态 dot + 图片/文件附件。桌面端输入框支持 ⌘+V / Ctrl+V 直接粘贴文件发送（见技术决策"输入框直接粘贴文件"）
   - 顶部 av-bar 也带 presence dot，sub-line 在线显示 `@xxxx · {hostname}.local.`（mDNS hostname，来自 bonsoir 的 `svc.host`，不是 IP；IP 解析在 `transport.connectTo` 内仅用于 socket 拨号），离线显示 `@xxxx · offline`
   - Compose bar 行 `crossAxisAlignment: center`，所有按钮（image / file picker / send）统一 44×44，跟 textfield `minHeight: 44` 在中线对齐
5. **Settings**：改名 + 日志

### 视觉细节
- 卡片圆角统一 `12` / `14`，1px 细描边 + 浅灰 surface（不用阴影）
- 头像：圆形，自己 accent 填充白字，对方 surface2 填墨字，presence 绿点带 2.5px 白描边
- 关闭 Material 涟漪：`splashFactory: NoSplash`、`highlightColor: transparent`，更贴近原生 iOS 触感
- mono 字体专门承载 ID / 系统状态 / 协议出处这类"机器信息"，强化"本地协议工具"氛围

### 文件 bubble 文案规则（_FileBubble statusLabel）
**没有 ✓ chip / retry chip**。状态完全靠 mono 副标文字 + bottom progress bar 表达 — 跟 Near 整体的「机器信息」克制美学一致，也避免 chip 跟文字争 sub-line 横向空间（fileName 长 + sub-line 长 + 12px chip 三方挤压会截断 K/N 文字）。

私聊（fanoutSize ≤ 1）保持单一状态词：

| 场景 | 文案 |
| --- | --- |
| sender offerPending | `offered` |
| sender 已 accepted, in-flight | （无 label，靠底部 progress bar）|
| sender delivered | `delivered` |
| sender declined（接收方主动拒绝）| `declined` |
| sender failed（传输错误）| `failed` |
| receiver awaitingAccept | `offered`（带 Accept/Ignore 按钮）|
| receiver 接收完成 | `downloaded` |

群聊（mine && fanoutSize > 1）按方案 A 用「K / N」聚合，复用顶层 `isDeclined` / `isFailed` flag：

| 状态 | 文案 |
| --- | --- |
| `isDeclined`（全部 declined）| `declined` |
| `isFailed`（全部失败但无 delivered）| `failed` |
| `delivered == 0` 其他 | `offered to N` |
| `0 < delivered < N` | `delivered to K / N` |
| `delivered == N` | `delivered to N` |

刻意不显示 `sending to {names}` 这种长文案 —— sub-line 高度只够单行 mono 字号；分母 `N` 只是 fanout 表初始大小，途中拒绝/失败也不缩，目的是让发送方"少几个就重发或私聊问"。

> **declined ≠ failed**：`_MessageBubble` 在 `status == SendStatus.failed` 时显示红色 ⚠️ Tooltip "Send failed"。设计上 declined 是接收方主动选择，正常终态，不该触发这个标记。所以 `_maybeFinalizeFanout` 在"全 declined"时把 `msg.status` 设为 `delivered` + `declined=true`（不是 `failed`），避免误标。

### Auto-accept 设置
Settings → Receiving → `Auto-accept files` 切换。关掉后：
- 接收方收到 `file_offer` 时不自动开 sink，bubble 标 `awaitingAccept`，副标 `offered` 前置 `_PulseDot`，右侧 30px Accept(filled accent ✓) / Ignore(outlined ✕) 两按钮（参考 `25-files.html` phone 2）
- 用户点 Accept：`chat.acceptOffer` → 开 sink → 回 `file_accept`
- 用户点 Ignore：`chat.declineOffer` → 回 `file_decline`，bubble 状态变 `declined`
- 设置持久化：SharedPreferences key `autoAcceptFiles`，默认 `true`
- 发送方**总是**先发 offer（不知道对端设置），所以发送方 UI 必经 `offered` 状态；对方 auto-accept 时 `offered` 一闪而过，关掉时停留到对方点击

---

## 五、协议格式（WebSocket JSON）

```jsonc
{ "type": "hello",   "fromId": "<uuid>" }
{ "type": "msg",     "msg": { /* ChatMessage.toJson */ } }
{ "type": "ack",     "id":  "<msgId>" }
{ "type": "ping",    "token": "<id>" }
{ "type": "pong",    "token": "<id>" }
{ "type": "file_offer",   "msg": { /* ChatMessage with fileName/fileSize/fileMime */ } }
{ "type": "file_accept",  "id":  "<msgId>" }
{ "type": "file_decline", "id":  "<msgId>" }
{ "type": "file_chunk",   "id":  "<msgId>", "seq": 0, "data": "<base64>" }
{ "type": "file_end",     "id":  "<msgId>" }
```

`ChatMessage.toJson()`：`id` / `fromId` / `fromName` / `text` / `ts`（ms）/ `toId?` / `image?`(base64) / `imageMime?` / `fileName?` / `fileSize?` / `fileMime?`。`toId == null` 表示群发。

---

## 六、平台原生侧

- **macOS**
  - `macos/Runner/DebugProfile.entitlements` + `Release.entitlements` 必须开 `com.apple.security.network.server` / `client` / `com.apple.security.app-sandbox` 配合的 mDNS 权限
  - `Info.plist` 里 `NSBonjourServices` 要包含 `_lanchat._tcp`
  - 图片保存：sandbox 不能默认写 `~/Downloads`，需要 entitlement `com.apple.security.files.downloads.read-write`。开了之后用 `path_provider.getDownloadsDirectory()` 拿到真实 `~/Downloads` 直接写文件，不用弹 saveFile 对话框（mac 桌面用户更习惯 Finder 路径而非 Photos.app）
  - `NSPhotoLibraryAddUsageDescription` 仍然保留，便于 iOS / Android fallback 路径
- **Android**：`MethodChannel('lanchat/files')` 实现 `beginIncoming` / `appendChunk` / `finishIncoming`，落地到 MediaStore Downloads
- **iOS**：Local Network 权限 + Bonjour services 声明在 `Info.plist`

### 图片保存路径分支（`home_page.dart:_save`）
| 平台 | 路径 |
| --- | --- |
| iOS / Android | `Gal.putImageBytes` → 系统相册 |
| macOS | `getDownloadsDirectory()` → `~/Downloads/near-{ms}.jpg` |
| Linux / Windows | `FilePicker.platform.saveFile` 弹 Finder 对话框 |

---

## 七、已知优化方向 / 给后续会话的提示

- `home_page.dart` 单文件 ~2500 行，包含会话页、附件预览、图片裁剪、文件 bubble 等多个独立 widget。拆分时优先抽：`_MessageBubble` / `_FileBubble` / 附件 picker bottom sheet / SplashView / NamePrompt
- 文件传输无并发控制：多文件同时发会顺序排队但不会丢，注意大文件 base64 占用内存
- **群聊文件「一份流广播」未做**：当前每个 acceptor 独立读一遍文件 + 独立 `sendFileBytes`，N 个 acceptor 就读 N 遍。优化方向 — 第一个 accept 就开始读 + 广播给已 accept 集合；新 accept 进来时若还在传，加入正在 broadcast 的 channel set；若已传完，再为后到 accept 单独跑一份
- 没有消息持久化：app 杀掉后历史就没了。这是设计如此（"no record"），但如果未来要加，建议落 SQLite + 选择性保留最近 N 条
- ACK 超时 500ms 在跨子网或慢 Wi-Fi 上偏短，但加大会让"对方掉线"的反馈延迟。可考虑随网络质量自适应
- **群聊 fanout 按"快照"，不跟随 peer 进出**：`sendFile` 时刻的 `connectedPeerIds` 决定 fanout 表，之后即使有新 peer 加入也收不到这条 offer，已断开的 peer 不会从 fanout 移除（永远停在 `offered`，导致 `_maybeFinalizeFanout` 永远不收敛）。修法：`_onPeerLost` 时遍历 `_outgoingFiles` 把对应 entry 标 `declined`，触发 finalize
- **测试设备**：同机跑两个 sandboxed mac 实例不能真实模拟（共享 container + 同 bundleId mDNS 行为异常 + loopback sandbox 限制）。需要至少两台物理设备；测 `K of N` 群聊聚合需要 ≥ 3 端
- `super_clipboard` 在 Linux / Windows 桌面端尚未验证，目前只跑 macOS / iOS / Android
- 设计稿目录 `../lan-chat-designs/` 是 HTML 原型，是 source of truth；改 UI 前先去看对应文件（`24-near.html` 主屏，`25-files.html` 文件交互）
