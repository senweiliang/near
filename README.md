# Near

跨平台（macOS / iOS / Android / Windows）局域网点对点聊天工具。零配置发现 + WebSocket P2P 传输 + 文本/图片/文件三类消息，无服务器、不落库。

- 包名 `near` / bundle ID `com.near.app`
- mDNS service type `_near._tcp`
- 详细技术方案与设计参见 [`CLAUDE.md`](./CLAUDE.md)

## 构建

```bash
flutter pub get

# macOS（release，权限沿用日常路径）
flutter build macos --release && open build/macos/Build/Products/Release/near.app

# iOS（需 Xcode + 设备签名）
flutter build ios --release

# Android
flutter build apk --release

# Windows（不支持从 macOS 交叉编译，由 GitHub Actions 构建）
# 见 .github/workflows/build-windows.yml
```

## 多实例本地测试

通过 `NEAR_TEST_ID` 环境变量启动独立实例（不读 SharedPreferences、用独立 myId / 文件缓存目录）：

```bash
NEAR_TEST_ID=alice ./build/macos/Build/Products/Release/near.app/Contents/MacOS/near &
NEAR_TEST_ID=bob   ./build/macos/Build/Products/Release/near.app/Contents/MacOS/near &
```

> 同机多 sandbox 实例之间走 loopback 时握手会失败（CLAUDE.md 已知坑），但跨机互联正常。
