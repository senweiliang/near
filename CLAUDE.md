# Near — 项目速览

跨平台（macOS / iOS / Android / Windows）局域网点对点聊天工具。零配置发现 + WebSocket P2P 传输 + 文本/图片/文件三类消息，无服务器、不落库。

包名 `near`（`pubspec.yaml`），bundle ID `com.near.app`（iOS / macOS / Android applicationId 三端统一）。GitHub: `senweiliang/near` (private)。

> **构建/启动约定**：
> - **mac**：要测试时直接 `flutter build macos --release` + `open .../Release/near.app`。Debug build 跟 Release 是不同 binary，会被 macOS 视为新 app，Local Network / mDNS 权限要重新弹窗授权——容易出现"粘贴 OK 但连不上 peer"这种假阳性。Release build 跟用户日常双击的是同一签名同一路径，权限沿用，所见即所得。
> - **Windows**：本地无 Windows 机器，由 `.github/workflows/build-windows.yml` 在 GitHub Actions `windows-latest` runner 上构建，产物为 artifact `near-windows-x64.zip`。workflow 在 CI 上跑 `flutter create --platforms=windows .` 重新生成 `windows/` 脚手架，所以脚手架不入库。

---

## 一、技术栈

- Flutter SDK ^3.11.5，Material 3 + 自定义 Cupertino 路由
- 发现：`bonsoir` ^5.1.0（mDNS / Bonjour）
- 传输：`shelf` + `shelf_web_socket` 当 server，`web_socket_channel` 当 client
- 加密：`cryptography`（Ed25519 / X25519 / HKDF / ChaCha20-Poly1305）+ `cryptography_flutter`（自动启用系统原生实现，无需手动 enable）
- 通知：`flutter_local_notifications`（Android 需开 core library desugaring，已在 `build.gradle.kts` 配好）
- 拖放 / 打包：`desktop_drop`（桌面拖文件进会话）、`archive`（文件夹打 zip）
- 持久化：`shared_preferences`（仅 myId / myName，不存历史消息）
- 媒体：`file_picker`、`gal`（保存相册）、`open_filex`、`share_plus`、`super_clipboard`、`flutter_linkify` + `url_launcher`
- 字体：`google_fonts`（Hanken Grotesk + JetBrains Mono）

---

## 二、模块划分（lib/）

| 文件 | 职责 |
| --- | --- |
| `main.dart` | App entrypoint。劫持 `debugPrint` 把 `[xxx]` 前缀日志注入 `AppLog`；macOS 用 `MethodChannel('near.window/ready')` 通知原生窗口就绪 |
| `theme.dart` | `AppColors` 调色板 + `AppFonts.body()` / `AppFonts.mono()` 工厂 |
| `discovery.dart` | mDNS 广播 + 监听。服务类型 `_near._tcp`，attributes 携带 `id` / `name`。`updateName()` 通过 stop+start 重新广播触发对端刷新 |
| `transport.dart` | WebSocket 连接管理。dual-stack server、IPv4 lookup、ID 去重、keepalive、redial、文件分块传输；通过 `onChannelEstablished` / `onChannelClosed` 回调把 channel 状态喂给 chat |
| `peer.dart` | `Peer` 模型（id/name/host/port + `online` flag + `lastActiveAt` 用于 LRU 排序）+ `ChatMessage` 模型（含 `SendStatus`、图片 base64 缓存、文件元信息、`bytesTransferred`、offer 三态 flag、`fanout` per-peer 状态表）+ `FanoutState` / `FanoutEntry`（仅 sender 端用，不进 wire format） |
| `chat.dart` | `Chat extends ChangeNotifier`：粘合 discovery + transport，维护 `messages` / `peers` / ack timer / 文件接收 sink；Android 通过 `MethodChannel('near/files')` 走 MediaStore；通过 `MethodChannel('near/background')` 启停 Android foreground service |
| `home_page.dart` + `home/*.dart` | UI 主体，用 `part` 拆成 `peer_list` / `conversation` / `message_bubble` / `compose` / `splash` / `file_bubble` / `share_sheet`（part 文件共享库私有符号，`_Xxx` 类可跨文件互用）。`home_page.dart` 本身只留 HomePage、公共小工具和 `_sendPathsTo`（文件 / 文件夹统一发送入口） |
| `secure_channel.dart` | 端到端加密：`NearIdentity`（Ed25519 长期身份）、`SecureSession`（握手 + 收发两个方向的 AEAD）、`InnerFrame`（JSON 帧 / 二进制文件块帧编解码）。纯 Dart，有单测 |
| `notifications.dart` | `Notifier`：新消息系统通知，失败只记日志 |
| `share_intake.dart` | `MethodChannel('near/share')`：接收系统分享 / 「用 Near 打开」/ 拖到 Dock 的文件路径 |
| `file_utils.dart` | `zipDirectory`：后台 isolate 把文件夹打成 zip |
| `settings_page.dart` | 改昵称、auto-accept 文件 toggle、Stay-connected-in-background toggle（仅 Android）、查看调试日志 |
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

`hello` 阶段 dedupe：已有同 peer channel 时，两端统一保留「ID 较小一方拨出的那条」（新连接若是它就替换旧的，否则关新的）。不能简单"先到先留"——双向同时拨通时两端各留一条、各关另一条，结果两条全断。重连（redial）时也只有 ID 较小的一方负责，避免对称重连风暴。

**兜底反向拨号**：ID 较大的一方等 `_kFallbackDialDelay`（5s）还没 channel 就自己 `force` 拨一次（discovery found 和 channel 断开后都会挂这个 timer）。场景：Windows 开 Clash TUN，ID 较小的 PC 拨不出去，原先两端会永远卡住。

### IPv4 lookup
mDNS 解析出的主机名（`xxx.local.`）在某些网络下会优先解析到 IPv6 或被系统代理截胡，导致 dial 失败。**代理 fake-ip**：Clash 等 TUN 模式会把 `.local` 解析到 `198.18.0.0/15` 假 IP，连上即被代理断开（`Connection closed before full header was received`）。所以广播 attrs 带 `ips`（本机可拨的局域网 IPv4，逗号分隔），拨号候选顺序 = attrs `ips` → lookup 结果（`isDialableIPv4` 过滤掉 fake-ip / loopback / link-local）→ hostname，每个候选 3s 超时依次试。`transport.dart:67` 强制 `InternetAddress.lookup(..., type: IPv4)` 拿到地址再拨号；server 端用 `anyIPv6` dual-stack 监听以兼容两边。

### Keepalive + 后台恢复探活
- 每条 channel 10s 周期 ping，token 携带时间戳
- App 从后台 resume：`Chat.onAppResumed()` 对所有 connected peer 发 1s 超时的 probe ping，挂的丢弃 + redial。修了 iOS 切后台几秒回来 socket 已经死了但没收到 close frame 的 bug
- **probe 不再用于文件传输健康检查**：原来 sender 端假死靠 onAppResumed probe 间接发现，但 probe 跟 file_chunk 共用同一个 sink — chunk 排队时 pong 也排队，1s 超时下 sender 经常被误判 dead 然后被 dropPeer 中断传输（receiver 切回前台触发 probe 是典型场景）。现在文件流自带窗口化 ack + 2s idle watchdog（`_kAckIdleTimeout`），probe 仅用作"刚 resume 时快速判一次连接还在不在"的副作用，文件传输不再依赖它
- `_keepAliveInterval = 10s` 定在 `transport.dart`

### mDNS lost 抖动 + bonsoir_android attrs 错位
两个独立坑加在一起处理：

1. **改名重广播会触发对端 `lost` 事件**。`chat._onPeerLost` 加了护栏：`_transport.hasChannelTo(id)` 为 true 就忽略 lost，避免 peer 列表抖一下消失再出现
2. **bonsoir_android 5.x 的 lost 事件 attrs 不可靠** —— `svc.attributes` 拿到的是**本机自己的广播 attrs**（`name=Android, id=本机的id`），不是丢失的那个 peer 的 attrs。如果按 `svc.attributes['id']` 查 peer，永远查的是本机自己（不在 peers 里），导致 lost 路径变 no-op、peer.online 永远停在 true
3. 修法：`_onPeerFound` 时维护 `_svcNameToPeerId[svc.name] = id` 映射，`_onPeerLost` 优先按 `svc.name` 反查真实 peerId（fallback 到 attrs['id'] 兼容 bonsoir_darwin / bonsoir_windows）

### Peer 在线状态：transport channel 是 source of truth
mDNS 在 Android 后台、网络抖动场景下不可靠。所以 `peer.online` 的权威信号改成**transport channel 状态**：
- `_onChannelEstablished(peerId)` → `peer.online = true`
- `_onChannelClosed(peerId)` → `peer.online = false`
- mDNS lost 仍保留作为辅助兜底（peer 关掉 app 但 channel 没及时收 close frame 的情况）

之前只靠 mDNS 标 offline 时，Android log 显示对端 `channel done 1002` 但 peer 还是绿点 —— 因为 mDNS lost 要么没来，要么 attrs 错位。

### Peer 生命周期 / LRU 排序
Peer 下线（channel 关闭，或 mDNS lost 且 channel 也已断）**不从 `peers` map 删除**，仅把 `peer.online = false`。这样：
- 用户依然能进入该 peer 的 conversation 看历史聊天记录
- UI 把 presence dot 从绿色 (`AppColors.presence`) 切到灰色 (`AppColors.inkFaint`)
- conversation header sub-line 显示 `@xxxx · offline` 替代 IP

`_onPeerFound` 重新发现旧 peer 时**保留**其 `lastActiveAt`（不重置），保持 LRU 顺序在重连后稳定。

PeerList 排序两层：
1. 有 `lastActiveAt` 的 peer 在前，按时间倒序（最近聊过最上 = LRU）
2. 无 `lastActiveAt` 的 peer 在后，保持 mDNS 发现顺序（新 found 加在最末）

依赖 Dart `List.sort` 是稳定 mergesort，平局保持 `Map.values` 的插入顺序（Dart `Map` = `LinkedHashMap`）。**注意：Map.update（key 已存在时覆盖 value）保留原位置，不会推到末尾**。

`_bumpPeerActivity(peerId)` 在 4 个收发入口（`_onIncoming` / `_onFileOffer` / `send` / `prepareImage` / `sendFile`）调用。peerId == null 表示群发，遍历所有 connected peer 一起 bump（群发对所有人算一次互动）。

主屏 hero 区 `N nearby on this network` 数字 **只算 peer，不含自己**（"nearby" 字面就不该把自己算进去）。CONVERSATIONS section header 右侧的 `online / total` 比值则是 conversation 数（peers + Everyone group），含 +1 是 Everyone group，不是自己。

PeerList tile 的 meta 行通过顶层 `_peerPreview(chat, peer)` 计算最近消息预览（peer == null 表示 Everyone here），从 `chat.messages` 尾向头扫一次找到第一条匹配。每次 `Chat.notifyListeners` 时整个 PeerList 重 build 重新扫，O(N×M) 但 messages 不持久化、量小，没必要建索引。

### 文件传输协议（offer / accept 握手 + per-peer fanout）
分两段：先协商，再传输；群聊场景按 peer 独立跟踪状态。

1. **协商**：sender 发 `file_offer`（携带 ChatMessage 元数据，无字节）。receiver 根据 `autoAcceptFiles` 设置决定立即回复 `file_accept` 或先把 bubble 标 `awaitingAccept` 等用户点 Accept/Ignore，对应回 `file_accept` 或 `file_decline`
2. **传输（窗口化 ack）**：sender 收到 `file_accept` 后开始发**二进制**文件块帧（`ChunkFrame(msgId, offset, bytes)`，不再 base64 进 JSON）→ `file_end(id)`。块按**绝对字节偏移**寻址，receiver 只接 `offset == 已接收字节数` 的块（`_incomingOffset`），旧连接残留 / 重复块自然丢弃。chunk size 64KB，sender 维护 per-(msgId, peerId) 的 `_OutgoingFlow`，inflight bytes 上限 1 MB（约 16 个 chunk）。窗口满时主循环挂在 `waitForAck()` 上等。**receiver 每写完一个 chunk 回 `file_chunk_ack(id, offset)`**（Android 走 `_androidChain` 异步链，链尾 ack；其他平台 `sink.add` 后立即 ack），sender 收到 ack 推进窗口 + 累加 acked 字节作进度。`file_end` 在所有 inflight 都 ack 后才发，确保 receiver 端 sink 已 flush 全部字节
3. **传输健康检查**：sender 端每条流挂一个 500ms 周期 watchdog，**`_kAckIdleTimeout = 2s`** 内没收到任何新 ack → 整体 fail。LAN 场景下正常 ack 间隔 = receiver 单 chunk 处理时间（解密 + 写盘，iOS/macOS < 1ms，Android MediaStore 串行链最差 ~50ms），2s 足以覆盖正常延迟，超过基本就是真假死（对端 crash / 网线拔了 / Wi-Fi 切换中）。连接关闭时 `_failFlowsOn(conn)` 按**连接**（不是 peerId）唤醒并中止挂在其上的 sender 循环，错误类型是 `ChannelLostException`（区别于 idle 超时等真失败）。**这套 in-band 检测取代了过去依赖 `onAppResumed` probe + 文本 ACK 500ms 超时来兜文件场景的设计**，sender 不再误判活的为死的，也不会在对端真死时误标 delivered（旧 fire-and-forget 实现的失败模式）
4. **群聊 fanout**：`sendFile` 时按 `connectedPeerIds`（私聊则是 `[toId]`）把每个 peer 写进 `msg.fanout` 表，初始 `FanoutState.offered`。`file_offer` 广播给所有 channel
   - **首个 `file_accept` 进来**：该 entry → `sending`，清 `msg.offerPending`（让 progress bar 开始动），单独跑 `sendFileBytes(file, thatPeerId)`，progress 是 receiver ack 累计字节
   - **`file_decline`**：entry → `declined`（**注意：不是 `failed`**，declined 是接收方主动拒绝，正常终态，不算发送失败）
   - **该 peer 传输 onError**：`ChannelLostException` → entry `paused`（见下「断点续传」）；其他错误 → `failed`
   - **该 peer 断线时 entry 还在 `offered`**（对方还没回应）→ 直接 `failed` 并 finalize，否则 fanout 永不收敛
   - 都**不影响其他 peer**（修过 v1 实现里"1 人 decline 误杀全员 / 多 accept 共用一个 progress 变量乱跳 / `_outgoingFiles` 提前清掉"三连 bug）
   - **每条 peer 完成后** 调 `_maybeFinalizeFanout`：所有 entry 都进终态（`delivered` / `declined` / `failed`）才聚合：
     - 任一 delivered → `msg.status=delivered`，`declined=false`
     - 全部 `declined`（无 delivered 无 failed）→ `msg.status=delivered` + `declined=true`（**故意不用 failed，避免触发 `_MessageBubble` 的红色 ⚠️ "Send failed" 图标**）
     - 其他（无 delivered 但有 failed）→ `msg.status=failed`，`declined=false`
     - 最后清 `_outgoingFiles`
   - 每个 acceptor 一份独立流、独立读文件。**「一份流广播」评估后不做**：加密后每个 peer 的会话密钥不同，密文本来就得逐 peer 生成；改二进制帧后也没有 base64 编码可省；重复读盘由 OS page cache 吸收。剩下能省的只有几次 `read` 系统调用，不值得引入多 peer 共享窗口的复杂度
   - `msg.bytesTransferred` 改为派生：取所有 fanout entry 的最大值，progress bar 单调前进不抖动

5. **断点续传**：连接断开后两端都保留状态 `_kResumeGrace = 60s`：
   - sender：entry `paused`（UI 显示 `paused`），保留 `_outgoingFiles`；60s 内没续上 → `failed`
   - receiver：sink / MediaStore session 不关，`msg.transferPaused = true`；60s 后 `_abortIncoming`（Android 走 `cancelIncoming` 删半成品）
   - 重连 `_onChannelEstablished` 时 receiver 对每条未完成的接收发 `file_resume(id, offset)`（Android 先 await `_androidChain` 让偏移可信）；sender `cancelFlow` 旧流后从 offset 重开。无法续传（文件已清 / 已判 failed）回 `file_cancel`，receiver 立即标 failed
   - `FanoutEntry.flowGeneration`：每次（重新）起流 +1，旧流迟到的 onError / onProgress 按代号丢弃，避免把新流的状态覆盖回 paused

文本消息的 `_ackTimers` 500ms 超时是 IM 即时反馈用的；文件场景由窗口化 ack 自身决定 status — onComplete 表示对端最后一个 chunk 也 ack 完成（真 delivered），onError 来自 sink 写抛错 / channel close / `_kAckIdleTimeout` 触发。

发送方在等待 accept 期间通过 `_outgoingFiles[msgId]` 持有 `File` 对象引用，accept 来到时再打开读取。如果文件已被外部删除，`file.open()` 抛错走 onError 标 failed。

receiver 侧 `_incomingFrom[msgId] → fromPeerId` 用于 `_onChannelClosed` 时定位并清理对应方向上还在 pending 的接收任务（关 sink、清 `_androidChain` / `_androidSessions`、msg 标 failed），避免 channel 断了 sink 还挂着泄漏 + bubble 永远 pending。

### Android 后台保活：foreground service（opt-in）
Android 系统在 app `paused` 后约 5 秒就会切断 wifi socket，导致 channel 死掉、对端 send 没人收。"允许后台运行"（电池白名单）只防止进程被杀，**不**保证网络。要真后台收消息，唯一合法解就是 foreground service + 常驻通知。

实现：
- `NearForegroundService.kt`（`android/app/src/main/kotlin/com/near/app/`）：`startForeground` 挂一个 IMPORTANCE_MIN 的静默通知 "Near · Connected on this network"，OS 不再 throttle 网络
- `MainActivity.kt` 暴露 `MethodChannel('near/background')`，方法 `start` / `stop`；`start` 还会做 Android 13+ 的 POST_NOTIFICATIONS 运行时权限请求
- `chat.dart` `stayConnectedInBackground` 字段持久化在 SharedPreferences key `stayConnectedInBackground`，**默认 false**；`Chat.start()` 时若 toggle 开着，自动调 `_ensureBackgroundService()`
- Settings → Receiving 提供 toggle，仅 Android 显示；toggle 开关动作直接走 `chat.setStayConnectedInBackground()` → MethodChannel
- iOS 没做（iOS 后台 socket 限制不一样，要做需要 BGTaskScheduler / VoIP push，scope 收敛只做 Android）

### Android 文件落地
不能写 `getApplicationDocumentsDirectory`（用户看不到），必须走 MediaStore。`chat.dart` 里 `_androidChain[msgId]` 是个 `Future<void>` 链，把 `appendChunk` 串行化，否则原生侧 fd 写入会乱序。`finishIncoming` 收到 `file_end` 时被调用拿到最终 content URI。

iOS / macOS / Desktop 走 `getApplicationDocumentsDirectory()/near_files/{msgId}__{safeName}` 私有目录，再通过 share_plus / open_filex 暴露。

### 图片不压缩
原图原字节直发，不 resize 不重新编码（历史上曾长边 > 1280 时 `copyResize` + `encodeJpg(quality: 80)`，用户明确要求去掉）。仅保留 `_maxImageBytes`（10 MB）输入体积上限。`imageMime` 靠魔数嗅探实际格式（`_isPngBytes`），不再固定写死 `image/jpeg`。`prepareImage` + `completeImage` 两步调用保留（先用原始 bytes 建 bubble 立即可见，`completeImage` 里再触发真正的 dispatch），但两步之间不再有压缩这个异步环节。

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
1. **Splash**：2 秒最低展示。**首次启动**走 hero 动画 → NamePrompt：splash 中央的 `Near.` 用 GlobalKey 测量 NamePrompt 里 `Near.` 的目标 rect，然后用 `AnimationController`(700ms easeInOutCubic) 把字号从 44pt 平滑插值到 36pt + 平移到目标位置；splash 白底同时用 `Interval(0, 0.7) easeIn` 淡出；NamePrompt 的 `a quiet room on this network` 副标 + 输入框 + Enter 按钮通过 `Interval(0.35, 1.0)` `FadeTransition` + `SlideTransition(0,0.12 → 0)` 一起淡入。**回访用户**（已存 myName）走原 450ms 淡出路径，不进 hero
   - **键盘焦点延迟**：NamePrompt 的 TextField 不用 `autofocus`，绑定 `FocusNode`，监听 `entryAnim` status；hero 完成（`AnimationStatus.completed`）后才 `requestFocus`。否则键盘弹出会改变 layout，target rect 失效，NEAR. 跳一下
   - **Material 上下文**：splash overlay 必须包 `Material(type: transparency)`，否则 Text 拿不到 `DefaultTextStyle`，会用 fallback debug 字体（带黄色双下划线 + 字形基线偏移），swap 时 NEAR. 视觉跳几像素
2. **NamePrompt**：首次启动输入昵称；输入提交 → `chat.start(name)` 内会把 myName 写入 SharedPreferences，下次直接进 PeerList
3. **PeerList（主屏）**
   - **Hero header**：自己头像 (42px) + 昵称 (18px/700/-0.3 letter-spacing) + 下方 `@xxxx` short handle (mono 11px)；整块点击进 Settings
   - **Room meta 卡**（F2 layout）：上半 row 是 presence stack + "**N nearby on this network**"（N **不含自己**，纯 peers 数），下半通过 1px 全宽 divider 隔开，居中放 mono 副标 `link-local · peer-to-peer · no record` (10.5px)。整体外层 `Container(clipBehavior: Clip.antiAlias)` 把 divider 裁到圆角内。features 留在 meta 卡而不挪到 hero 是因为：在群聊语境（"the room"）下 features 跟"当前网络状态"同源，留在一张卡更收敛
   - **Presence stack 上限 + 溢出**：最多展示 5 个圆头像（自己 + 4 个 online peer），超出走 `_MiniAv(overflow: true)` 渲染一个 mono `+N` tile（bgApp 底 + line 1px 描边 + ink3 字，跟普通头像视觉区分，避免被误读成 6 号头像）
   - SECTION header：mono 11px / 0.66 letter-spacing 大写；右侧显示 `online / total` 比值（全员 online 时仅显示总数）
   - Peer 列表：群聊 `Everyone here` 置顶，下面是 peer 条目（unread badge）
     - **LRU 排序**：聊过的浮在前（按 `lastActiveAt` 倒序），没聊过的按发现顺序排在后
     - **meta 行 = 最近消息预览**（IM 会话列表风格，不再显示 hostname）：
       - 私聊：双向都只显示 body，不加 sender 前缀（avatar + title 已经表明是谁）
       - `Everyone here`：对方发的加 `{fromName}: ` 区分谁说的；自己发的不加前缀
       - 文件 → `[fileName]`；图片 → `[Image]`；文本 → 多行折叠成单行（`\s+ → ' '`）。附件类用 `[...]` 跟正文文本视觉区分
       - 没匹配消息时 fallback：peer → host name（mDNS hostname）/ `offline`；group → `N in the room · open to all`（"in the room" 在群聊语境下指代"聊天室"，是字面所指，保留）
     - **Offline peer 不删除**：保留在列表中，presence 点变灰（`AppColors.inkFaint`），meta 在没消息记录时显示 `offline`
4. **ConversationPage**：自定义 `_FastCupertinoRoute`（300ms in / 260ms out），分日期分隔（Today / Yesterday / M/D HH:MM），消息泡 + 状态 dot + 图片/文件附件。桌面端输入框支持 ⌘+V / Ctrl+V 直接粘贴文件发送（见技术决策"输入框直接粘贴文件"）
   - 顶部 av-bar 也带 presence dot，sub-line 在线显示 `@xxxx · {hostname}.local.`（mDNS hostname，来自 bonsoir 的 `svc.host`，不是 IP；IP 解析在 `transport.connectTo` 内仅用于 socket 拨号），离线显示 `@xxxx · offline`；group sub 用 `N in the room · open to all`
   - Compose bar 行 `crossAxisAlignment: center`，所有按钮（image / file picker / send）统一 44×44，跟 textfield `minHeight: 44` 在中线对齐
   - **首帧防 scroll-flash**：消息列表用 `Opacity(_initialSettled ? 1 : 0)` 包住；`initState` post-frame callback 跑 `_jumpToEnd()` 后再 `setState(_initialSettled = true)` 揭开。否则 route 滑入时用户看到 list 在顶部位置一瞬，紧接着跳到底部，视觉"从远处滑下来"
   - **文本气泡 context menu**：text bubble 上 `onSecondaryTapUp`（桌面右键）+ `onLongPressStart`（移动长按）触发 `_showMessageMenu` —— `showMenu` 弹一个白底 1px 描边 10px 圆角的菜单，目前只有一项 `Copy`，复制完弹 1.2s `Copied` SnackBar
5. **Settings**：改名、auto-accept files、Stay connected in background（仅 Android）、日志

### 视觉细节
- 卡片圆角统一 `12` / `14`，1px 细描边 + 浅灰 surface（不用阴影）
- 头像：圆形，自己 accent 填充白字，对方 surface2 填墨字，presence 绿点带 2.5px 白描边
- 关闭 Material 涟漪：`splashFactory: NoSplash`、`highlightColor: transparent`，更贴近原生 iOS 触感
- mono 字体专门承载 ID / 系统状态 / 协议出处这类"机器信息"，强化"本地协议工具"氛围

### 文件 bubble 文案规则（_FileBubble statusLabel）
**没有 ✓ chip / retry chip**。状态完全靠 mono 副标文字 + bottom progress bar（私聊）或 chev 展开详情（群聊）表达。设计稿原型在 `../lan-chat-designs/27-fanout.html`。

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

**群聊（mine && fanoutSize > 1）只看 K = deliveredCount，去分母、去 declined/failed 整体词**：

| 状态 | 文案 |
| --- | --- |
| K == 0 | `offered to N` |
| K > 0（含 K == N 的 clean 终态）| `delivered to K` |

唯一的两条规则。`declined` / `failed` 不再上 sub-line — 这两种是**单个 acceptor**的事实，应该出现在展开 detail 行里、不应该让一个被拒绝拖走整条 bubble 的语义。N 的值用户随时能展开看到 N 行，无需在折叠态写分母。

**K=0 终态不 dim**：即使 fanout 全部进入终态且 deliveredCount==0（全 declined / 全 failed / 混合），bubble 仍维持原色 — 不视觉惩罚一条没人收到的消息。sub-line 仍写 `offered to N`，副标脉冲点取消（靠 `isFanoutTerminal` 判），用户点 chev 展开看每个 acceptor 是 declined 还是 failed。

**chev 展开按钮**：仅 `fanoutSize > 1` 时显示。22×22 InkWell hit area，绝对定位 bubble 右中（Stack + Positioned right:6, top:0, bottom:0 + Center），跟 incoming bubble 的 save 按钮共用同一视觉 slot。`AnimatedRotation` 200ms 旋转 180° 表展开态。点击 toggle 局部 `_expanded` state（`_FileBubble` 改成 StatefulWidget 持有）。

**detail 列表**：`AnimatedSize` 240ms easeOut 包 `Column`，每行一个 `_PeerFanoutRow`：
- 8×8 dot 颜色统一 inkFaint，**`delivered` → 实心圆，其他所有状态（offered / sending / declined / failed）→ 空心圆**
- name + handle 两行
- 右侧：sending 时 64×3 mini bar（fill 用 ink-3 灰）+ % 文字；其他状态显示 `offered` / `delivered` / `declined` / `failed` 单词，文字色统一 mutedFg

> **detail 行不用任何状态颜色 + 不用动效**：dot 颜色统一 inkFaint、文字统一 mutedFg、不脉冲。状态语义全靠右侧 word + delivered/未 delivered 的 fill 二元区分。理由：状态颜色（绿/红/蓝）让 fanout 列表读起来像"通过 / 失败"评估面板，破坏 Near 的克制工具感；动效在 fanout > 5 行的列表里抢注意力。fill/word 二元已经够了。

> **declined ≠ failed**：`_MessageBubble` 在 `status == SendStatus.failed` 时显示红色 ⚠️ Tooltip "Send failed"。设计上 declined 是接收方主动选择，正常终态，不该触发这个标记。所以 `_maybeFinalizeFanout` 在"全 declined"时把 `msg.status` 设为 `delivered` + `declined=true`（不是 `failed`），避免误标。

> **群聊不显示底部 progress bar**：`showProgress` 条件加了 `&& !isGroup`。群聊聚合一条总进度条要么 max（撒谎，最快那个 100% 时其他还在传）、要么 average（慢的拖累快的）、要么 sum/N（一种 average 变体），都不诚实。改为：群聊把整体进度交给副标文案（K/N）+ 展开 detail 里 per-peer mini bar 承担。私聊 / receiver 维持原 progress bar 行为。

### Auto-accept 设置
Settings → Receiving → `Auto-accept files` 切换。关掉后：
- 接收方收到 `file_offer` 时不自动开 sink，bubble 标 `awaitingAccept`，副标 `offered` 前置 `_PulseDot`，右侧 30px Accept(filled accent ✓) / Ignore(outlined ✕) 两按钮（参考 `25-files.html` phone 2）
- 用户点 Accept：`chat.acceptOffer` → 开 sink → 回 `file_accept`
- 用户点 Ignore：`chat.declineOffer` → 回 `file_decline`，bubble 状态变 `declined`
- 设置持久化：SharedPreferences key `autoAcceptFiles`，默认 `true`
- 发送方**总是**先发 offer（不知道对端设置），所以发送方 UI 必经 `offered` 状态；对方 auto-accept 时 `offered` 一闪而过，关掉时停留到对方点击

---

## 五、协议格式（v2，端到端加密）

### 握手与加密
- 每端持有一把 **Ed25519 长期身份密钥**（seed 存 SharedPreferences `identitySeed`；测试模式每次新生成）。指纹 = 公钥 SHA-256 前 16 字节，Settings → Security 显示自己的，会话页点对方名字看对方的
- 连接建立后双方各发一条**明文 text 帧** hello：`{type:hello, v:2, fromId, idKey, eph, sig}`，`eph` 是本次连接的 X25519 临时公钥，`sig` = Ed25519 签名(`near-hello-v2|fromId|` + eph)
- 收到 hello：验签 → X25519 求共享密钥 → HKDF 派生两个方向的 key（info 带发送方 eph，两个方向互不相同）→ **TOFU** 比对 `trustedKeys`（SharedPreferences，peerId → idKey）。首次见到就记住；不一致则拒绝连接、`_conflictingKeys` 记下新 key，会话页顶部出横幅，用户核对后点 Trust new key（`chat.trustNewKey`）才放行
- 之后每一帧都是**二进制** ChaCha20-Poly1305 密文，nonce = 方向内递增计数器。加解密是异步的，`_Connection` 用 send / receive 两条 Future 链保证顺序与计数器一致
- 没有 `v` 字段的 hello（v0.1.x 旧版明文协议）直接断开，**新旧版本不互通**
- `msg` / `file_offer` 的 `fromId` 必须等于握手身份，否则丢弃（防冒充）

### 明文帧内容（加密层之内）
首字节 0 = JSON，1 = 文件块（`[1][idLen u8][msgId][offset u64 BE][bytes]`）。JSON 消息：

```jsonc
{ "type": "msg",     "msg": { /* ChatMessage.toJson */ } }
{ "type": "ack",     "id":  "<msgId>" }
{ "type": "ping",    "token": "<id>" }
{ "type": "pong",    "token": "<id>" }
{ "type": "file_offer",   "msg": { /* ChatMessage with fileName/fileSize/fileMime */ } }
{ "type": "file_accept",  "id":  "<msgId>" }
{ "type": "file_decline", "id":  "<msgId>" }
{ "type": "file_chunk_ack", "id":  "<msgId>", "offset": 0 }
{ "type": "file_end",       "id":  "<msgId>" }
{ "type": "file_resume",    "id":  "<msgId>", "offset": 0 }   // receiver → sender，重连后续传
{ "type": "file_cancel",    "id":  "<msgId>" }                // sender → receiver，无法续传
```

`ChatMessage.toJson()`：`id` / `fromId` / `fromName` / `text` / `ts`（ms）/ `toId?` / `image?`(base64) / `imageMime?` / `fileName?` / `fileSize?` / `fileMime?`。`toId == null` 表示群发。

---

## 六、平台原生侧

- **macOS**
  - `macos/Runner/DebugProfile.entitlements` + `Release.entitlements` 必须开 `com.apple.security.network.server` / `client` / `com.apple.security.app-sandbox` 配合的 mDNS 权限
  - `Info.plist` 里 `NSBonjourServices` 要包含 `_near._tcp`
  - 图片保存：sandbox 不能默认写 `~/Downloads`，需要 entitlement `com.apple.security.files.downloads.read-write`。开了之后用 `path_provider.getDownloadsDirectory()` 拿到真实 `~/Downloads` 直接写文件，不用弹 saveFile 对话框（mac 桌面用户更习惯 Finder 路径而非 Photos.app）
  - `NSPhotoLibraryAddUsageDescription` 仍然保留，便于 iOS / Android fallback 路径
- **Android**：
  - `MethodChannel('near/files')` 实现 `beginIncoming` / `appendChunk` / `finishIncoming`，落地到 MediaStore Downloads
  - `MethodChannel('near/background')` 启停 `NearForegroundService`（见三 · Android 后台保活）；`AndroidManifest.xml` 声明 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` / `POST_NOTIFICATIONS` / `WAKE_LOCK` 权限，service `foregroundServiceType="dataSync"`
- **iOS**：Local Network 权限 + Bonjour services 声明在 `Info.plist`；后台保活未做

### 图片保存路径分支（`home_page.dart:_save`）
| 平台 | 路径 |
| --- | --- |
| iOS / Android | `Gal.putImageBytes` → 系统相册 |
| macOS | `getDownloadsDirectory()` → `~/Downloads/near-{ms}.jpg` |
| Linux / Windows | `FilePicker.platform.saveFile` 弹 Finder 对话框 |

### App 图标生成：Figma 手工导出，不用脚本
图标是启动页同款 "Near." wordmark（Hanken Grotesk Bold），源文件在 Figma：<https://www.figma.com/design/IRhtyJt989MpYOi3Qy81Ax>（"Icon Card 1024" = 白色圆角卡片版，"Icon FG 1024" = 透明底纯文字版）。改设计（换色、调字号等）直接去这个 Figma 文件改，改完在每个 frame 的 Export 面板按下表加导出行（单位用 `<数字>w` 固定宽度，不要用倍数），导出后按尺寸对应放到目标路径：

- macOS `AppIcon.appiconset`（"Icon Card 1024" 导出 16/32/64/128/256/512/1024）：`macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png`
- Android legacy（同上 frame 导出 48/72/96/144/192）：`android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png`
- Android adaptive 前景（"Icon FG 1024" 导出 108/162/216/324/432）：`android/app/src/main/res/drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_foreground.png`
- Windows（CI 用，"Icon Card 1024" 导出 256）：`tool/logo_windows_256.png`（跟 `flutter_launcher_icons_windows.yaml` 的 `icon_size: 256` 一致，零缩放）

**为什么不用脚本批量生成**：最早是用 Flutter（`flutter test` 里渲染 widget 再 `toImage`/`toByteData` 存 PNG）本地生成所有尺寸，中途踩了两个坑才放弃：
1. 一开始渲染一张 1024 母图交给 `flutter_launcher_icons` 缩放成各尺寸，圆角卡片的硬边细节在 60+ 倍缩放下丢失抗锯齿，小尺寸图标边缘出现锯齿/重影
2. 改成每个尺寸原生渲染（不缩放）之后，又在 `flutter_test` harness 里稳定复现一个 Flutter 引擎的已知问题（[flutter/flutter#49317](https://github.com/flutter/flutter/issues/49317)，多年未修）：`RenderRepaintBoundary.toImage()` 之后调用 `image.toByteData(format: PNG)` 会挂死，10 分钟后被 `flutter_test` 默认超时强杀
所以改成在 Figma 里画（矢量文字 + 矢量圆角矩形），用 Figma 自己的渲染器按每个目标尺寸单独导出——同样是"按目标分辨率原生光栅化，不缩放"，但避开了 Flutter 这个引擎 bug。**Figma 免费版 MCP 集成每月的读/写调用配额很低**（`download_assets` / `use_figma` 撞过一次），批量导出这种一次性、大量调用的操作直接在 Figma 网页的 Export 面板里手动做，不要尝试用 MCP 工具批量跑。

`card: true`（白色圆角卡片烤进 PNG 本体，对应 Figma 里 "Icon Card 1024"）用于 macOS app icon / Android legacy 单图标 / Windows .ico —— 这几处系统不提供背景层，透明区域会真的透明、露出桌面壁纸或托盘背景，所以背景得自己烤进去。`card: false`（纯文字透明底，对应 "Icon FG 1024"）只用于 Android adaptive icon 前景层——背景色由 `android/app/src/main/res/values/colors.xml` 里的 `ic_launcher_background`（`#FFFFFF`）和 `mipmap-anydpi-v26/ic_launcher.xml` 拼出来，系统负责按各家 launcher 的形状蒙版（圆形/圆角方形等）裁剪合成，不需要也不应该自己烤白底。

主配置 `flutter_launcher_icons.yaml` 已删除（macOS/Android 图标不再需要它）；Windows 因为本地没有 `windows/` 目录，`flutter_launcher_icons_windows.yaml` 仍保留给 CI 用，`image_path` 指向 `tool/logo_windows_256.png`（Figma 导出，不是本地脚本生成）。`tool/HankenGrotesk.ttf` / `tool/logo_master.png` / `tool/logo_fg.png` 是历史脚本留下的参考文件（`logo_master.png`/`logo_fg.png` 内容已同步成 Figma 导出版本），不参与实际构建。

---

## 七、已知优化方向 / 给后续会话的提示

- 文件传输无并发控制：多文件同时发各自独立跑流，共享同一条连接带宽
- 没有消息持久化：app 杀掉后历史就没了。这是设计如此（"no record"），但如果未来要加，建议落 SQLite + 选择性保留最近 N 条
- 文本 ACK 超时 500ms 在跨子网或慢 Wi-Fi 上偏短，但加大会让"对方掉线"的反馈延迟。可考虑随网络质量自适应（文件传输已迁移到窗口化 ack，不受这个超时影响）
- **群聊 fanout 按"快照"**：`sendFile` 时刻的 `connectedPeerIds` 决定 fanout 表，之后新加入的 peer 收不到这条 offer（设计如此）。断线 peer 卡 `offered` 的问题已修（见文件传输协议第 4 条）
- **测试设备**：同机跑两个 sandboxed mac 实例不能真实模拟（共享 container + 同 bundleId mDNS 行为异常 + loopback sandbox 限制）。需要至少两台物理设备；测 `K of N` 群聊聚合需要 ≥ 3 端
- **多实例本地测试**：通过 `NEAR_TEST_ID=alice ./build/macos/Build/Products/Release/near.app/Contents/MacOS/near &` 启动独立实例（不读 SharedPreferences、用独立 myId / 独立 `near_files_$testId` 文件缓存目录、强制 autoAcceptFiles=true）。同机两实例之间 dial loopback 时 dedupe 风暴有真 bug —— alice/bob 同机互联会出 `dedupe close` 死循环，偶发 SIGSEGV，跨机正常
- **iOS 后台保活未做**：scope 收敛到 Android。要做需要 BGTaskScheduler 唤醒 + 重连 / VoIP push（后者得后端，违背 no-server 原则）
- `super_clipboard` 在 Linux / Windows 桌面端尚未验证，目前只跑 macOS / iOS / Android
- 设计稿目录 `../lan-chat-designs/` 是 HTML 原型，是 source of truth；改 UI 前先去看对应文件（`24-near.html` 主屏，`25-files.html` 文件交互，`27-fanout.html` 群聊文件 fanout 详情面板）
- **会话列表用 `reverse: true` + `shrinkWrap` + `Align(topCenter)`**：offset 0 即底部，进入会话 / 键盘弹起天然停在最新消息，不再需要 post-frame `jumpTo` + Opacity gate（旧实现因 lazy build 的 `maxScrollExtent` 不准会"分段下弹"）。消息少时 shrinkWrap 让列表高度 = 内容高度，再顶部对齐，所以不会出现单条消息贴底。代价：用户上翻时有新消息进来，视口会被向上推一条的高度（主流 IM 同样行为）
- **系统分享入口**：Android `ACTION_SEND(_MULTIPLE)` intent-filter（`MainActivity.receiveShare` 后台线程把 content:// 复制到 cache）；iOS / macOS 声明 `CFBundleDocumentTypes`（public.data / public.content，macOS 另加 public.folder），出现在分享菜单「用 Near 打开」/ Finder 打开方式 / 拖到 Dock 图标。iOS 用 scene lifecycle 插件 `NearShareInbox`（`AppDelegate.swift`），macOS 用 `FlutterAppLifecycleDelegate.handleOpenURLs`（`MainFlutterWindow.swift`）。**没做 iOS Share Extension**（需要新 target + App Group 签名配置），所以 iOS 照片 app 的分享菜单里不一定有 Near，Files app 里一定有
- **通知**：`chat.activeConversation`（HomePage `_open` 维护）+ `appInForeground`（lifecycle 维护）决定是否弹；正在看的会话不弹。`_notifier.init()` 不能 await —— 首次会弹系统授权框，await 会卡住 `start()` 导致不联网
