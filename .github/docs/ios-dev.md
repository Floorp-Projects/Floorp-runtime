# iOS GeckoView 開発ガイド

iOS 向け Floorp の開発に関する技術ドキュメント。

## 目次
- [アーキテクチャ概要](#アーキテクチャ概要)
- [ビルド成果物](#ビルド成果物)
- [GeckoView Swift ラッパー](#geckoview-swift-ラッパー)
- [React Native 統合](#react-native-統合)
- [CI/CD](#cicd)

---

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────┐
│           React Native App (TypeScript)          │
├─────────────────────────────────────────────────┤
│         Native Module (Swift/Obj-C)              │
├─────────────────────────────────────────────────┤
│         GeckoView Swift Wrapper                  │
│  (GeckoView, GeckoSession, EventDispatcher)      │
├─────────────────────────────────────────────────┤
│         GeckoView.xcframework                    │
│    (XUL, libmozglue, libnss3, etc.)             │
├─────────────────────────────────────────────────┤
│              Gecko Engine (C++/Rust)             │
└─────────────────────────────────────────────────┘
```

---

## ビルド成果物

### ディレクトリ構成

```
obj-aarch64-apple-ios-sim/
└── dist/
    ├── bin/
    │   ├── XUL                    # Gecko メインライブラリ
    │   ├── libmozglue.dylib       # Mozilla グルーライブラリ
    │   ├── libnss3.dylib          # NSS ライブラリ
    │   └── ...
    └── include/
        └── GeckoView/
            ├── IOSBootstrap.h
            └── GeckoViewSwiftSupport.h
```

### CI アーティファクト

| アーティファクト名 | 内容 | 用途 |
|-------------------|------|------|
| `floorp-ios-simulator-moz-artifact` | 統合アーカイブ | フルビルド成果物 |
| `floorp-ios-simulator-app` | GeckoTestBrowser.app | テスト用ブラウザ |
| `floorp-ios-geckoview-xcframework` | XCFramework | React Native 連携 |
| `floorp-ios-geckoview-swift` | Swift ラッパーソース | ライブラリ構築用 |

---

## GeckoView Swift ラッパー

### 場所
`mobile/ios/GeckoTestBrowser/GeckoView/`

### 主要クラス

#### GeckoView
```swift
public class GeckoView: UIView {
    public var session: GeckoSession?
}
```
UIView サブクラス。GeckoSession の描画領域を提供。

#### GeckoSession
```swift
public class GeckoSession {
    public func open(windowId: String? = nil)
    public func load(_ url: String)
    public func reload()
    public func goBack(userInteraction: Bool = true)
    public func goForward(userInteraction: Bool = true)
    public func stop()
    
    public var contentDelegate: ContentDelegate?
    public var navigationDelegate: NavigationDelegate?
    public var progressDelegate: ProgressDelegate?
    public var permissionDelegate: PermissionDelegate?
}
```
ブラウザセッションを管理。Android の GeckoSession と類似の API。

#### GeckoRuntime
```swift
public class GeckoRuntime {
    public static func main(argc: Int32, argv: ...)
    public static func childMain(xpcConnection: xpc_connection_t, ...)
}
```
Gecko エンジンの初期化とプロセス管理。

### デリゲート

| デリゲート | 用途 |
|-----------|------|
| `ContentDelegate` | ページコンテンツイベント（タイトル変更等） |
| `NavigationDelegate` | ナビゲーションイベント（URL 変更、エラー等） |
| `ProgressDelegate` | 読み込み進捗イベント |
| `PermissionDelegate` | 権限リクエスト処理 |

---

## React Native 統合

### 必要なコンポーネント

1. **XCFramework** - CI から取得
2. **Swift ラッパー** - CI から取得、または Swift Package 化
3. **Native Module** - 新規作成が必要

### Native Module 設計例

```swift
// GeckoViewManager.swift
@objc(GeckoViewManager)
class GeckoViewManager: RCTViewManager {
    override func view() -> UIView! {
        return RNGeckoView()
    }
    
    @objc func loadUri(_ node: NSNumber, uri: String) {
        // GeckoSession.load() を呼び出し
    }
}
```

```typescript
// GeckoWebView.tsx
interface GeckoViewProps {
  uri?: string;
  onLoadStart?: (event: { url: string }) => void;
  onLoadEnd?: (event: { url: string; title: string }) => void;
}

const GeckoWebView = requireNativeComponent<GeckoViewProps>('GeckoView');
```

### プロジェクト構成例

```
floorp-mobile-ios/
├── package.json
├── tsconfig.json
├── src/
│   ├── App.tsx
│   └── components/
│       └── GeckoWebView.tsx
├── ios/
│   ├── Podfile
│   ├── FloorpMobile/
│   │   ├── GeckoViewModule.swift
│   │   ├── GeckoViewManager.swift
│   │   └── GeckoViewBridge.m
│   └── Frameworks/
│       └── GeckoView.xcframework
```

---

## CI/CD

### iOS ビルドワークフロー

```yaml
# .github/workflows/ios-build.yml
- name: Build iOS
  run: ./.github/workflows/scripts/build-ios.sh

# XCFramework は build-ios.sh 内で自動生成
# create-xcframework.sh が呼び出される
```

### XCFramework 生成スクリプト

```bash
# 手動実行
./.github/workflows/scripts/create-xcframework.sh \
  obj-aarch64-apple-ios-sim \
  ~/output \
  aarch64-apple-ios-sim
```

---

## 関連ドキュメント

- [IOS_DEVELOPMENT_GUIDE.md](../../mobile/ios/GeckoTestBrowser/IOS_DEVELOPMENT_GUIDE.md) - 詳細な開発ガイド
- [README](../../mobile/ios/README) - iOS ポートの概要
