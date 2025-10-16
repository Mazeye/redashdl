# redash-dl (Swift)

macOS ネイティブの Redash 向けコマンドラインダウンローダー（Swift 実装）。3 つのモードに対応：

> このライブラリは [redash_pandas](https://github.com/alexweberk/redash_pandas) のSwiftコマンドラインツール版です。Python版の機能をSwiftで再実装し、macOSネイティブのコマンドラインツールとして提供しています。

- query：クエリを直接実行
- safe：ページング（offset/limit）で安全に取得
- period：期間を分割して取得

## ビルド

```bash
# リポジトリのルートでビルド
swift build -c release
# 任意：Swift 標準ライブラリを静的リンク（配布しやすい）
swift build -c release --static-swift-stdlib
# 実行ファイル
.build/release/redash-dl
```

## 配布

- 単一バイナリをそのまま配布：`.build/release/redash-dl`
- PATH に追加：

```bash
cp .build/release/redash-dl /usr/local/bin/
```

- （任意）社内ネットワーク経由：

```bash
curl -L https://internal/redash-dl -o /usr/local/bin/redash-dl && chmod +x /usr/local/bin/redash-dl
```

## 認証情報

優先度：`--credentials` > `--endpoint/--apikey` > キャッシュ > エラー。

- 初回は `--credentials` で JSON を指定することを推奨：`{"endpoint":"...","apikey":"..."}`
- 成功後はファイルパスをキャッシュし、以降は `--credentials` を省略可能
- キャッシュ管理：

```bash
redash-dl config show
redash-dl config clear
```

## 共通オプション

- `-c/--credentials`：認証情報 JSON のパス
- `-e/--endpoint`：Redash エンドポイント（例 `https://redash.example.com`）
- `-k/--apikey`：API キー
- `-o/--output`：出力ファイルパス（デフォルトはカレントディレクトリ）

## 使い方

### 1) query

```bash
# 基本
redash-dl query -i 42 -c creds.json
# パラメータ付き
redash-dl query -i 42 -p '{"name":"John"}'
# 出力先を指定
redash-dl query -i 42 -o result.csv
```

### 2) safe（ページング）

```bash
# 大量データを分割して取得（進捗表示）
redash-dl safe -i 2674 -l 100000 -n 50 -c creds.json
# パラメータ付き
redash-dl safe -i 2674 -l 100000 -p '{"foo":"bar"}'
# 並行処理で高速化（3並行）
redash-dl safe -i 2674 -l 100000 --concurrency 3
# 進捗表示を無効化
redash-dl safe -i 2674 -l 100000 --no-progress
```

要件：Redash のクエリ内で `{{offset_rows}}` と `{{limit_rows}}` パラメータを定義しておくこと。

### 3) period（期間分割）

```bash
# 月単位で 3 ヶ月ごとに区切る（進捗表示）
redash-dl period -i 6738 -s 2023-01-01 -e 2024-06-20 -t m -m 3 -c creds.json
# 週単位
redash-dl period -i 6738 -s 2023-01-01 -e 2024-06-20 -t w
# 並行処理で高速化（2並行）
redash-dl period -i 6738 -s 2023-01-01 -e 2024-06-20 -t m --concurrency 2
# 進捗表示を無効化
redash-dl period -i 6738 -s 2023-01-01 -e 2024-06-20 -t m --no-progress
```

`-t/--interval` の指定可能値：d/day, w/week, m/month, q/quarter, y/year

## 並行処理機能

`safe`と`period`モードで並行処理をサポート：

- **並行数制御** - `--concurrency`オプションで並行数を指定（デフォルト: 1, 最大: 5）
- **自動調整** - 指定した並行数が5を超える場合は自動的に5に調整
- **安全制限** - サーバーへの負荷を考慮した最大並行数制限
- **後方互換** - 並行数を指定しない場合は従来の順次実行

### 並行処理の例

```bash
# 3並行でSafeクエリ実行
redash-dl safe -i 1234 -l 10000 --concurrency 3

# 2並行でPeriodクエリ実行
redash-dl period -i 1234 -s 2025-01-01 -e 2025-12-31 -t m --concurrency 2

# 並行数制限の例（10を指定しても5に調整される）
redash-dl safe -i 1234 --concurrency 10
# Warning: Concurrency adjusted from 10 to 5 (max: 5)
```

## 進捗表示機能

`safe`と`period`モードでリアルタイム進捗表示をサポート：

- **進捗バー** - 現在の進捗と総進捗のパーセンテージを表示
- **リアルタイム状態** - 現在処理中のページ/期間を表示
- **統計情報** - 取得済み行数、残り時間の推定を表示
- **完了通知** - 総所要時間と最終結果を表示

### 進捗表示の例

```bash
# Safeモード進捗表示
[████████████████████████████████] 15/50 (30.0%) ETA: 2m30s 第15ページ取得中 (1500000行取得済み)
✅ Safeクエリ完了、1500000行のデータを取得 - 所要時間: 5m23s

# Periodモード進捗表示  
[████████████████████████████████] 6/6 (100.0%) ETA: 0s 期間処理中: 2024-04-01 から 2024-06-20 (45000行取得済み)
✅ Periodクエリ完了、45000行のデータを取得 - 所要時間: 3m15s
```

`--no-progress`オプションで進捗表示を無効化できます。

## 出力

- 既定ではカレントワーキングディレクトリに出力：
  - query：`redash_<id>.csv`
  - safe：`redash_<id>_safe.csv`
  - period：`redash_<id>_period.csv`
- 502 は空結果を返します。タイムアウト時はエラーを投げます。

## 謝辞

このプロジェクトは [redash_pandas](https://github.com/alexweberk/redash_pandas) を参考に作成されました。Python版の優れた設計と機能をSwiftで再実装し、macOSネイティブのコマンドラインツールとして提供しています。

- **redash_pandas**: Python版のRedashデータ取得ライブラリ
- **作者**: [alexweberk](https://github.com/alexweberk)
- **ライセンス**: Apache-2.0

## ライセンス

MIT
