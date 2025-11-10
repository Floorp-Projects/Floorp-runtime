# macOS SSB AppShim 設計メモ

## 目的
- Floorp の PWA（SSB）ウインドウを macOS 上で独立したアプリ（Dock/⌘-Tab/Spaces）として扱わせる。
- 既存の `floorp-ssb` シェルスクリプト方式では `CFBundleExecutable` が Floorp 本体に置き換わり、Launch Services が Floorp に統合してしまうため、AppShim(ネイティブ実行ファイル)を導入する。

## 現行フロー整理
1. `nsMacSSBSupport::Install` が SSB バンドル構成（Contents/以下）を生成。
2. `Contents/MacOS/floorp-ssb`（シェル）は Floorp 本体 (`Floorp.app/Contents/MacOS/floorp`) を `-profile` `-start-ssb` 付きで `exec`。
3. プロセス実体が Floorp バイナリのため、Dock/⌘-Tab/ウインドウグルーピングは Floorp にまとまる。

## 要件整理
- `CFBundleExecutable` として AppShim バイナリを配置し、SSB バンドル単体で macOS Application と認識される。
- AppShim は Floorp 本体を別プロセスとして起動し、必要な IPC を介して各種操作を委譲。
- アプリ終了時は Floorp 本体へ終了要求を伝え、AppShim 自身も終了。
- Dock アイコンやメニュー、バッジ更新を SSB ごとに制御可能にする足場を提供。

## 参考実装
- Chromium: `chrome/browser/apps/app_shim/` (App Shim controller, macOS loader)
- `NSRunningApplication`, `NSWorkspace`, `LSSetApplicationInformationItem` 等を活用したアプリ識別制御。

## 次ステップ
1. AppShim バイナリのプロトタイプを作成し、Launch Services が SSB バンドルを独立アプリとして扱うことを確認。
2. AppShim ↔ Floorp 間 IPC 方式の検討（`NSDistributedNotificationCenter`, `XPC`, Unix Domain Socket 等）。
3. `nsMacSSBSupport` の生成処理を AppShim 前提に再設計（`CFBundleExecutable`・リソース配置・Info.plist 更新）。
4. テスト項目の定義（起動、Dock 表示、ウインドウ制御、終了、バッジ/メニュー連携など）。

## プロトタイプ状況
- `.github/assets/pre-build/pwa/appshim/` に最小構成の AppShim ソース（`AppShimMain.mm`, `AppShimDelegate.mm` など）を配置。
- 仮のビルド手順や TODO は同ディレクトリ内 `README.md` に記載。

## 生成フロー更新方針
1. **ビルド統合**
   - `appshim` ディレクトリを Xcode/clang ビルドターゲットに組み込み、`floorp-ssb-loader` バイナリ（仮称）を生成。
   - `moz.build` または pre-build スクリプトで AppShim をビルドし、成果物を `.github/assets/pre-build/pwa/mac/` 相当の配置先に出力。

2. **バンドルテンプレートの準備**
   - `Contents/MacOS`：AppShim バイナリと設定用補助ファイルを配置。
   - `Contents/Resources`：`Info.plist`、アイコン、プロファイル設定などをテンプレート化。
   - `Info.plist` の `CFBundleExecutable` を AppShim に設定。`CFBundleIdentifier` は SSB ごとにユニーク化。

3. **`nsMacSSBSupport` の差し替え**
   - `WriteExecutable` 処理を AppShim コピーと設定ファイル生成に差し替え。
   - 既存のシェルスクリプト生成を廃止し、AppShim への引数受け渡しロジックに更新。
   - シンボリックリンクで Floorp 本体を参照していた処理は不要となるため削除。

4. **起動パラメータ整備**
   - AppShim が受け取るコマンドラインから、SSB ID / プロファイル / IPC ポートなどを判別できるよう仕様化。
   - Floorp 本体起動時の `-start-ssb` 等の既存フラグとの互換性を維持する。

5. **テスト/検証**
   - 生成された SSB バンドルが macOS で独立アプリとして扱われるか確認。
   - Dock/⌘-Tab/Spaces、終了同期、複数 SSB 同時起動などを含むテストケースを策定。

6. **将来の拡張**
   - IPC 経由で Dock バッジやメニューを更新できるよう、AppShim と Floorp 間の通信チャネルを設計。
   - コード署名や notarization を行う際のフローを追加。


