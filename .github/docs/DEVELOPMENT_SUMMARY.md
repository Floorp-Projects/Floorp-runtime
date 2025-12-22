# iOS ブラウザアプリ開発サマリー

このドキュメントでは、iOS 版 GeckoView を使用したブラウザアプリの開発、ビルド、UI カスタマイズ、および React Native への移行可能性についてまとめます。

## 1. プロジェクト構造とビルドプロセス

### プロジェクト構造
このプロジェクトは、Mozilla の GeckoView エンジンを iOS アプリに組み込むためのテストベッドとして機能しています。

- **GeckoTestBrowser.xcodeproj**: Xcode プロジェクトファイル。
- **GeckoView**: Gecko エンジンの iOS ラッパーフレームワーク。
- **GeckoTestBrowser**: アプリケーション本体のターゲット。
- **UI コンポーネント**: `RootViewController`, `BrowserToolbar`, `BrowserSearchBar` などで構成されています。

### ビルド方法
コマンドラインから `xcodebuild` を使用してビルドおよびシミュレータでの実行が可能です。

```bash
# ビルドコマンド
xcodebuild -project mobile/ios/GeckoTestBrowser/GeckoTestBrowser.xcodeproj \
           -scheme GeckoTestBrowser \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           build
```

### シミュレータでの実行
ビルド完了後、`xcrun simctl` を使用してアプリをインストールおよび起動します。

```bash
# インストール
xcrun simctl install <DeviceID> <PathToAppBundle>

# 起動
xcrun simctl launch <DeviceID> org.mozilla.ios.GeckoTestBrowser
```

## 2. GeckoView の統合

GeckoView は、iOS 上で Web コンテンツを表示するためのコアエンジンです。`WKWebView` の代わりに `GeckoView` クラスを使用します。

- **GeckoSession**: ブラウザのタブやウィンドウに対応するセッション管理クラス。URL のロード、ナビゲーション（戻る/進む）、イベント処理を行います。
- **GeckoRuntime**: Gecko エンジンのランタイム環境。
- **Delegate パターン**: `NavigationDelegate`, `ProgressDelegate`, `ContentDelegate` などを実装して、ページの読み込み状態やタイトル変更などのイベントを受け取ります。

## 3. UI デザインとカスタマイズ

今回の開発では、モダンで没入感のある「ダークブルー/パープル」テーマを採用し、DaisyUI 風の美しさを目指しました。

### テーマ設定 (`Theme` struct)
アプリケーション全体で一貫した色を使用するために `Theme` 構造体を定義しました。

- **Background**: 非常に暗いブルー (`#050A14`)
- **Surface**: わずかに明るいブルー (`#0D1426`)
- **Primary**: 鮮やかなブルー (`#3366CC`)
- **Secondary**: ライトブルー (`#66B2E6`)
- **Accent**: パープル (`#804DCC`)

### 背景デザイン (`AppBackgroundView`)
単色の背景ではなく、幾何学模様（グリッド、六角形、三角形、円など）を低不透明度で描画することで、リッチな視覚体験を提供しています。Core Graphics (`draw(_:)`) を使用して描画しています。

### タブ一覧 (`TabListViewController`)
- **グリッドレイアウト**: `UICollectionView` を使用してタブをグリッド状に表示。
- **スナップショット**: 各タブの現在の Web ページのスクリーンショットを表示し、視認性を向上。
- **カードデザイン**: 角丸、ボーダー、影を使用したモダンなカードスタイル。

## 4. React Native への書き換え可能性

iOS アプリを React Native で書き直すことは**技術的に可能**ですが、いくつかの重要な考慮事項があります。

### メリット
- **クロスプラットフォーム**: Android 版とのコード共有が可能（ビジネスロジック、UI コンポーネント）。
- **開発効率**: Hot Reloading などによる高速な開発サイクル。
- **UI の柔軟性**: React のコンポーネントモデルによる UI 構築の容易さ。

### デメリットと課題
- **GeckoView ブリッジ**: React Native はデフォルトで `WKWebView` (iOS) や `WebView` (Android) を使用します。GeckoView を使用するには、**Native Module (Native UI Component)** として GeckoView をラップする必要があります。
    - iOS 側の `GeckoView` (Swift/Obj-C) と React Native (JS/TS) の間でメソッド呼び出しやイベント通知のブリッジを実装する必要があります。
    - これは高度なネイティブ開発知識を必要とし、メンテナンスコストがかかります。
- **パフォーマンス**: ブラウザのような複雑なアプリでは、JS ブリッジのオーバーヘッドがパフォーマンスに影響する可能性があります（ただし、New Architecture / TurboModules で改善されつつあります）。

### 結論
React Native 化は可能ですが、**GeckoView の React Native ラッパーを作成する**という大きな初期投資が必要です。既存のネイティブ実装が安定している場合、UI 部分のみを React Native にする「Brownfield」アプローチも検討の余地があります。

## 5. Firefox (Gecko) ビルドに関する知見

Gecko (Firefox エンジン) のビルドは非常に大規模で複雑です。

- **ビルドシステム**: `mach` コマンド（Python ベースのツール）を使用します。
- **mozconfig**: ビルド設定ファイル。ターゲットアーキテクチャ（iOS, Android, Desktop）、最適化レベル、有効化する機能を指定します。
- **依存関係**: Rust, Python, Node.js, Clang など多岐にわたるツールチェーンが必要です。
- **iOS ビルド**: iOS 向けにビルドする場合、クロスコンパイルの設定が重要です。通常は macOS 上で Xcode のツールチェーンを使用してビルドします。

### Floorp Runtime でのビルド
このワークスペース (`floorp-runtime`) は、Gecko のビルド環境を含んでいるようです。`mach build` コマンドを使用して Gecko 本体をビルドし、生成されたフレームワーク (`GeckoView.framework`) を iOS アプリプロジェクトにリンクする流れになります。

---
*このドキュメントは、2025年12月22日時点での開発状況に基づいています。*
