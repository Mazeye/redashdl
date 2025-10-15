# redash-dl (Swift)

macOS ネイティブの Redash 向けコマンドラインダウンローダー（Swift 実装）。3 つのモードに対応：

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
# 大量データを分割して取得
redash-dl safe -i 2674 -l 100000 -n 50 -c creds.json
# パラメータ付き
redash-dl safe -i 2674 -l 100000 -p '{"foo":"bar"}'
```

要件：Redash のクエリ内で `{{offset_rows}}` と `{{limit_rows}}` パラメータを定義しておくこと。

### 3) period（期間分割）

```bash
# 月単位で 3 ヶ月ごとに区切る
redash-dl period -i 6738 -s 2023-01-01 -e 2024-06-20 -t m -m 3 -c creds.json
# 週単位
redash-dl period -i 6738 -s 2023-01-01 -e 2024-06-20 -t w
```

`-t/--interval` の指定可能値：d/day, w/week, m/month, q/quarter, y/year

## 出力

- 既定ではカレントワーキングディレクトリに出力：
  - query：`redash_<id>.csv`
  - safe：`redash_<id>_safe.csv`
  - period：`redash_<id>_period.csv`
- 502 は空結果を返します。タイムアウト時はエラーを投げます。

## ライセンス

MIT
