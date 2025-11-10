# AppShim Prototype Notes

このディレクトリには、macOS 向け Site Specific Browser (SSB) の AppShim プロトタイプのための最小実装が含まれています。

## 構成

- `AppShimMain.mm`  
  `NSApplicationMain` を呼び出し、`AppShimDelegate` をアプリケーションデリゲートとして登録します。
- `AppShimDelegate.h/mm`  
  Floorp 本体を別プロセスとして起動するための基本ロジックを提供します。現状は実装骨子のみで、起動フローや IPC の詳細は TODO として残しています。

## ビルドの雛形

開発環境では `xcrun clang` を利用して以下のようにビルドできます（仮例）:

```bash
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -fobjc-arc \
  -isysroot "$SDKROOT" \
  -framework Cocoa \
  AppShimMain.mm AppShimDelegate.mm \
  -o floorp-ssb-loader
```

実際には、Floorp リポジトリ内のビルドシステムに組み込む際に、ターゲット追加や Info.plist 生成、コード署名などが必要になります。

## TODO

- Floorp バイナリの検索ロジックを確立する（環境変数、隣接バンドル、構成ファイルなど）。
- `-start-ssb` など SSB 固有パラメータの受け渡し仕様を定義する。
- AppShim と Floorp 間の IPC / 終了同期方法を選定する。
- ビルドシステムへの統合（`moz.build` or pre-build スクリプト）を設計する。

