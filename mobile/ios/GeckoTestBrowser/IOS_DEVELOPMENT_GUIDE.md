# GeckoTestBrowser iOS 開発ガイド

このドキュメントでは、`GeckoTestBrowser` iOS アプリケーションの開発プロセス、ビルド手順、およびアーキテクチャの詳細について概説します。これは、最近実装されたタブブラウザ機能に基づき、このプロジェクトに取り組む開発者のための包括的なガイドとして機能します。

## 1. プロジェクト概要

`GeckoTestBrowser` は、Mozilla の GeckoView エンジンを組み込んだ Swift ベースの iOS アプリケーションです。これは、iOS 上での GeckoView の機能を実証するためのテストベッドおよび最小限のブラウザ実装として機能します。

### ディレクトリ構造

プロジェクトの場所: `mobile/ios/GeckoTestBrowser/`

- **GeckoTestBrowser.xcodeproj**: Xcode プロジェクトファイル。
- **GeckoTestBrowser/**: ソースコードディレクトリ。
    - **Launch/**: アプリケーションのエントリーポイント (`AppDelegate.swift`, `SceneDelegate.swift`, `main.swift`)。
    - **UI/**: ユーザーインターフェースコンポーネント。
        - `RootViewController.swift`: ブラウザビュー、ツールバー、タブロジックを管理するメインコントローラー。
        - `Components/`: `BrowserToolbar` や `BrowserSearchBar` などの再利用可能な UI コンポーネント。
    - **Extensions/**: UI ユーティリティ用の Swift 拡張機能。
    - **GeckoView/**: GeckoView ライブラリ用の Swift ラッパーおよびバインディング。

## 2. ビルドプロセス

プロジェクトは `xcodebuild` を使用してコマンドラインからビルドできます。これは、CI/CD パイプラインや、ターミナルベースのワークフローを好む開発者に役立ちます。

### ビルドコマンド

iOS シミュレータ（この例では特に iPhone 17 Pro をターゲット）向けにプロジェクトをビルドするには:

```bash
xcodebuild -project GeckoTestBrowser.xcodeproj \
           -scheme GeckoTestBrowser \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           build
```

**主なパラメータ:**
- `-project`: `.xcodeproj` ファイルへのパス。
- `-scheme`: 使用するビルドスキーム（通常はアプリ名）。
- `-destination`: ターゲットデバイスまたはシミュレータを指定します。形式: `'platform=iOS Simulator,name=<デバイス名>'`。

## 3. シミュレータでの実行

コマンドライン経由でシミュレータ上でアプリケーションを実行するには、`xcrun simctl` を使用していくつかの手順を実行します。

### 手順 1: シミュレータアプリの起動

```bash
open -a Simulator
```

### 手順 2: 利用可能なデバイスのリスト表示

使用したいシミュレータの UDID を見つけます:

```bash
xcrun simctl list devices available
```

### 手順 3: シミュレータの起動

前の手順で取得した UDID（例: `9A2C6FD5-BB8D-48BF-A911-D89D7EC166FB`）を使用します:

```bash
xcrun simctl boot <UDID>
```

### 手順 4: アプリケーションのインストール

ビルド後、アプリバンドル（`.app`）は Derived Data ディレクトリに配置されます。このバンドルを起動したシミュレータにインストールする必要があります。

```bash
xcrun simctl install <UDID> /path/to/derived_data/.../GeckoTestBrowser.app
```

*注: ビルドされたアプリへのパスは、`xcodebuild` の出力または DerivedData ディレクトリを検査することで確認できます。*

### 手順 5: アプリケーションの起動

バンドル識別子を使用してアプリを起動します:

```bash
xcrun simctl launch <UDID> org.mozilla.ios.GeckoTestBrowser
```

## 4. 機能実装: タブブラウザ

最近、シンプルな `UIAlertController` ベースのタブ切り替え機能を、フル機能のグリッドベース `TabListViewController` に置き換えました。このセクションでは、そのアーキテクチャと実装について詳しく説明します。

### アーキテクチャ

実装は標準的な MVC（Model-View-Controller）パターンに従い、既存の `RootViewController` 内に統合されています。

#### モデル

1.  **`Tab` クラス**:
    -   単一のブラウザタブを表します。
    -   **プロパティ**:
        -   `id`: 一意の識別子 (UUID)。
        -   `session`: タブに関連付けられた `GeckoSession`。
        -   `title`: 現在のページタイトル。
        -   `snapshot`: グリッドビューで使用されるページの `UIImage` スクリーンショット。

2.  **`TabManager` クラス**:
    -   `Tab` オブジェクトのコレクションを管理します。
    -   タブの追加、削除、選択を処理します。
    -   **デリゲートパターン**: `TabManagerDelegate` を使用して、ライフサイクルイベント（タブの追加、削除、アクティブタブの変更）を `RootViewController` に通知します。

#### ユーザーインターフェース

1.  **`TabListViewController`**:
    -   タブをグリッド表示する `UIViewController`。
    -   **UICollectionView**: フローレイアウトを使用してタブを2列に表示します。
    -   **Delegate**: `TabListViewControllerDelegate` を定義し、ユーザーアクション（タブ選択、新規タブ、タブを閉じる）を `RootViewController` に伝えます。
    -   **ビジュアル**: モーダルな雰囲気のために半透明の暗い背景を使用します。

2.  **`TabCell`**:
    -   カスタム `UICollectionViewCell`。
    -   タブのスナップショット画像とタイトルを表示します。
    -   グリッドから個々のタブを直接閉じるための「閉じる」(x) ボタンを含みます。

#### RootViewController への統合

`RootViewController` はコーディネーターとして機能します:

-   **スナップショット**: タブを切り替えるかタブリストを開く前に、`updateSnapshot(for:)` が呼び出されます。これは `UIGraphicsImageRenderer` と `drawHierarchy` を使用して、`GeckoView` の現在の状態をキャプチャします。
-   **プレゼンテーション**: `tabsButtonClicked` メソッドは `TabListViewController` をインスタンス化し、現在のタブを割り当て、デリゲートを設定し、モーダル（`.overFullScreen`）で表示します。
-   **デリゲーション**:
    -   `didSelectTab(_:)`: `TabManager` のアクティブタブを更新し、グリッドを閉じます。
    -   `didRequestNewTab()`: `TabManager` を介して新しいタブを作成し、グリッドを閉じます。
    -   `didCloseTab(_:)`: `TabManager` からタブを削除し、グリッドビューを更新します。

### コードスニペット

#### スナップショットの実装
Web ビューの内容をキャプチャすることは、ビジュアルタブスイッチャーにとって重要です:

```swift
private func updateSnapshot(for tab: Tab) {
    let renderer = UIGraphicsImageRenderer(bounds: geckoview.bounds)
    let image = renderer.image { _ in
        geckoview.drawHierarchy(in: geckoview.bounds, afterScreenUpdates: false)
    }
    tab.snapshot = image
}
```

#### タブマネージャーのロジック
タブロジックを集約することで、ビューコントローラーが簡素化されます:

```swift
class TabManager {
    // ...
    func removeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        delegate?.didRemoveTab(tab)
        
        // アクティブなタブが削除された場合のロジックを処理
        if activeTab?.id == tab.id {
            if let nextTab = tabs.last {
                 selectTab(nextTab)
            } else {
                activeTab = nil
                createNewTab()
            }
        }
    }
    // ...
}
```

## 5. 今後の改善点

-   **永続化**: 現在、アプリを終了するとタブは失われます。状態の復元やタブ URL のディスクへの保存を実装すると、ユーザーエクスペリエンスが向上します。
-   **アニメーション**: タブグリッドの開閉時にトランジションアニメーションを追加すると、UI がより滑らかに感じられます。
-   **プライベートブラウジング**: `Tab` モデルを拡張して、プライベートモード（シークレットモード）をサポートできます。
-   **ファビコン**: タブグリッド内のタイトルの横にファビコンを取得して表示します。

## 6. Gecko (Firefox Core) のビルド

`GeckoTestBrowser` iOS アプリは、コアとなる Gecko エンジン (XUL) ライブラリに依存しています。ブラウザエンジン自体を変更したり、基盤となるライブラリを更新したりする必要がある場合は、Gecko のソースコードをビルドする必要があります。

### 前提条件

-   **Mozilla ビルド環境**: 必要な依存関係がインストールされていることを確認してください。macOS については [Mozilla Build Documentation](https://firefox-source-docs.mozilla.org/setup/index.html) を参照してください。
-   **Rust**: Gecko のビルドに必要です。

### ビルド設定

プロジェクトには、iOS シミュレータビルド用に事前設定された `mozconfig` ファイルが含まれています: `mozconfig-ios`。

### ビルド手順

1.  **設定のセットアップ**:
    `MOZCONFIG` 環境変数をエクスポートして、iOS 設定ファイルを指すようにします。

    ```bash
    export MOZCONFIG=$(pwd)/mozconfig-ios
    ```

2.  **ブートストラップ (初回のみ)**:
    環境をまだセットアップしていない場合は、ブートストラップコマンドを実行します。

    ```bash
    ./mach bootstrap
    ```
    利用可能な場合は「Firefox for iOS」のオプションを選択するか、「Firefox for Desktop」を選択して iOS の依存関係が満たされていることを確認します。

3.  **Gecko のビルド**:
    `mach` を使用してビルドコマンドを実行します。

    ```bash
    ./mach build
    ```

    このプロセスは、ハードウェアによってはかなりの時間（30分以上）がかかる場合があります。

### アーティファクト (生成物)

ビルドプロセスにより、オブジェクトディレクトリ（例: `obj-aarch64-apple-ios-sim/dist/bin`）にいくつかの主要なライブラリが生成されます:

-   `XUL`: メインの Gecko ライブラリ。
-   `libmozglue.dylib`: Mozilla グルーライブラリ。
-   `libnss3.dylib`, `libsoftokn3.dylib` など: Network Security Services ライブラリ。

### Xcode との統合

`GeckoTestBrowser` Xcode プロジェクトは、これらのアーティファクトを探すように構成されています。
-   **検索パス**: プロジェクトのビルド設定 (`LIBRARY_SEARCH_PATHS`, `HEADER_SEARCH_PATHS`) は、Gecko ビルドの `dist` ディレクトリを指しています。
-   **Copy Files Phase**: Xcode のビルドフェーズで、これらの動的ライブラリをアプリバンドルの `Frameworks` ディレクトリにコピーします。

**注意**: `floorp-runtime` 内の C++ または Rust コードを変更した場合、変更を反映させるには、Xcode で iOS アプリを再ビルドする前に、再度 `./mach build` を実行する必要があります。

## 7. React Native 書き換えの実現可能性

`GeckoTestBrowser` アプリケーションを React Native を使用して書き直すことは技術的に可能ですが、カスタム GeckoView iOS 実装をブリッジするために多大な労力が必要です。

### 課題と要件

1.  **カスタムネイティブモジュール (ブリッジ)**:
    -   iOS 上の `GeckoView` は標準的な CocoaPod や Swift Package ではないため、単に `npm install` でラッパーをインストールすることはできません。
    -   ネイティブの Swift `GeckoView` クラスをラップする **React Native UI コンポーネント**（例: `<GeckoView />`）を作成する必要があります。
    -   このコンポーネントは、プロパティ（URL、セッション ID）とイベント（onPageStart, onPageStop, onTitleChange）を JavaScript レイヤーに公開する必要があります。

2.  **セッション管理**:
    -   現在の `GeckoView` 実装は `GeckoSession` オブジェクトに依存しています。
    -   React Native アーキテクチャでは、「タブマネージャー」のロジックは JavaScript/TypeScript（Redux、Context、またはローカルステートを使用）に移行する可能性が高いです。
    -   ネイティブモジュールには、セッションを作成、破棄、切り替えるメソッドが必要になるか、`<GeckoView>` コンポーネントが props に基づいて内部的にセッションの交換を処理する必要があります。

3.  **ビルドシステムの複雑さ**:
    -   現在のビルドは、ローカルでビルドされた C++ ライブラリ（`XUL` など）へのリンクに依存しています。
    -   これを標準の React Native `ios/` プロジェクト構造（CocoaPods ベース）に統合するには、カスタム `Podfile` 設定や動的ライブラリの手動リンクが必要になる場合があります。

### 提案アーキテクチャ

-   **JavaScript レイヤー**: UI（ツールバー、URL バー、タブグリッド）、状態管理（タブのリスト）、ビジネスロジックを処理します。
-   **ネイティブレイヤー (Swift/Obj-C)**:
    -   `GeckoViewManager`: ネイティブ `GeckoView` をインスタンス化する React Native ViewManager。
    -   `GeckoView`: ブリッジからのコマンドを受け入れるように少し変更された既存の Swift ラッパー。
    -   **Gecko ライブラリ**: 基盤となる XUL/Rust バイナリは、依然としてアプリにバンドルする必要があります。

### 結論

実現可能ではありますが、React Native への書き換えは、主に既存のネイティブエンジンのラッパーとなります。主な複雑さは、ビルドシステムの統合と、`GeckoSession` API のための堅牢なブリッジの作成にあります。
