# codexbar-to-greptimedb

[English README](README.md)

`codexbar-to-greptimedb` は、CodexBar で設定したプロバイダーの利用状況とクレジット残高を GreptimeDB に保存する CLI です。

## 前提条件

- HTTP SQL API を有効にした GreptimeDB
- 保存対象のプロバイダーを設定済みの CodexBar
- 対応するインストール先
  - Homebrew: macOS Sonoma (14) 以降、Apple Silicon または Intel
  - リリース用インストーラー: macOS arm64 / x86_64 または Linux x86_64

Linux 用の配布バイナリには、実行時に `curl`（`libcurl` を提供）と `libsqlite3` が必要です。

## インストール

### Homebrew（macOS）

```sh
brew install smartcrabai/tap/codexbar-to-greptimedb
```

### リリース用インストーラー

最新版を `$HOME/.local/bin` にインストールします。

```sh
curl --fail --location --silent --show-error \
  https://raw.githubusercontent.com/smartcrabai/codexbar-to-greptimedb/main/install.sh | sh
```

`$HOME/.local/bin` が `PATH` に含まれていない場合は、シェルの起動設定ファイルに追加してください。現在のシェルだけで有効にする場合:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

バージョンまたはインストール先を指定する場合は、インストーラーをダウンロードします。

```sh
curl --fail --location --silent --show-error \
  https://raw.githubusercontent.com/smartcrabai/codexbar-to-greptimedb/main/install.sh \
  -o install.sh

# 実行前に install.sh の内容を確認してください。
sh install.sh --version 0.1.0 --install-dir "$HOME/.local/bin"
```

## CodexBar の設定

`--provider` を指定しない場合は、CodexBar 設定で有効なプロバイダーを保存します。CodexBar と同じ順序で次の設定ファイルを読みます。

1. `CODEXBAR_CONFIG`
2. `XDG_CONFIG_HOME/codexbar/config.json`
3. `~/.config/codexbar/config.json`
4. `~/.codexbar/config.json`

`--source` または `CODEXBAR_SOURCE` を指定すると、プロバイダーに設定した source より優先されます。どちらもなければ設定済みの source、さらに未設定なら `auto` を使います。

## 利用状況を保存する

GreptimeDB の接続情報を設定して実行します。既定では一回だけ保存します。

```sh
export GREPTIMEDB_URL='https://<greptime-host>'
export GREPTIMEDB_USERNAME='<username>'
export GREPTIMEDB_PASSWORD='<password>'

codexbar-to-greptimedb --provider claude
```

HTTP Basic 認証を使う場合は `GREPTIMEDB_USERNAME` と `GREPTIMEDB_PASSWORD` を両方設定してください。秘密値がシェル履歴に残らないよう、`--password` ではなく環境変数の使用を推奨します。

プロバイダーの指定例:

```sh
# CodexBar 設定で有効なプロバイダー
codexbar-to-greptimedb

# Codex と Claude
codexbar-to-greptimedb --provider both

# 登録済みのすべてのプロバイダー
codexbar-to-greptimedb --provider all

# Codex の CLI source を指定
codexbar-to-greptimedb --provider codex --source cli
```

## 毎分保存する

フォアグラウンドで継続実行する場合:

```sh
codexbar-to-greptimedb --every-minute
```

`--once` は、間隔を設定していても一回だけの実行を強制します。定期実行中の一時的な CodexBar または GreptimeDB のエラーは標準エラーに出力し、次の周期で再試行します。一回実行時は失敗すると非 0 で終了します。各回の保存処理にはタイムアウトを設定しており(`--export-timeout-seconds` / `CODEXBAR_TO_GREPTIMEDB_EXPORT_TIMEOUT_SECONDS`、既定 300 秒)、取得や書き込みがハングしてもループが永久停止しないようにしています。タイムアウトは他の一時的な失敗と同様に扱われます。

### 利用枠が空いたときの Discord 通知

継続実行モード(`--watch`、`--every-minute`、`--interval-seconds`)で `DISCORD_WEBHOOK_URL` を設定していると、今回の取得結果を前回の取得結果と比較します。ある利用枠(usage window)の使用率が前回は 100% で、今回は 100% 未満に下がっていた場合、その Discord Webhook にメッセージを送信します。使い切っていたレート制限が復活したタイミングをすぐに知りたい場合に便利です。

```sh
export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/<id>/<token>'
codexbar-to-greptimedb --every-minute
```

この比較は同一プロセス内で継続実行している間の前回・今回の取得結果同士で行うため、一回実行モードでは何も起きません。また、ある利用枠が次回の取得結果に含まれていない(使用率が下がったのではなく単に情報が取得できなかった)場合は、100% 未満に下がったとは確認できないため通知しません。

### Homebrew service

Homebrew Formula は `$(brew --prefix)/etc/codexbar-to-greptimedb.env` を作成し、既定で `GREPTIMEDB_URL=http://localhost:4000` を設定します。upgrade 後も設定ファイルを保持し、認証情報を含められるため権限は `0600` です。

service は標準出力・標準エラーを `$(brew --prefix)/var/log/codexbar-to-greptimedb.log` に記録します。

```sh
nano "$(brew --prefix)/etc/codexbar-to-greptimedb.env"
```

設定例:

```sh
GREPTIMEDB_URL='https://<greptime-host>'
GREPTIMEDB_USERNAME='<username>'
GREPTIMEDB_PASSWORD='<password>'
```

次のコマンドでバックグラウンドサービスとして起動します。この service は設定ファイルを読み込み、CodexBar 設定で有効なプロバイダーを `--every-minute` 付きで実行します。

```sh
brew services start smartcrabai/tap/codexbar-to-greptimedb
```

設定を変更した場合は service を再起動します。

```sh
brew services restart smartcrabai/tap/codexbar-to-greptimedb
```

## オプションと環境変数

| CLI オプション | 環境変数 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `--greptime-url URL` | `GREPTIMEDB_URL` | 必須 | GreptimeDB の HTTP ベース URL |
| `--database NAME` | `GREPTIMEDB_DATABASE` | `public` | 保存先データベース |
| `--table NAME` | `GREPTIMEDB_TABLE` | `llm_usage_snapshots` | 保存先テーブル |
| `--username NAME` | `GREPTIMEDB_USERNAME` | なし | HTTP Basic ユーザー名 |
| `--password VALUE` | `GREPTIMEDB_PASSWORD` | なし | HTTP Basic パスワード |
| `--provider ID` | `CODEXBAR_PROVIDER` | CodexBar 設定の有効プロバイダー | プロバイダー ID、alias、`both`、または `all` |
| `--source SOURCE` | `CODEXBAR_SOURCE` | 設定済み source または `auto` | `auto`、`web`、`cli`、`oauth`、`api` |
| `--interval-seconds N` | `CODEXBAR_TO_GREPTIMEDB_INTERVAL_SECONDS` | 一回実行 | 正の `N` 秒ごとに実行 |
| `--watch`, `--every-minute` | なし | なし | 60 秒ごとに実行 |
| `--once` | なし | なし | 一回だけ実行 |
| `--export-timeout-seconds N` | `CODEXBAR_TO_GREPTIMEDB_EXPORT_TIMEOUT_SECONDS` | `300` | 保存処理が `N` 秒を超えたら中断して再試行 |
| なし | `DISCORD_WEBHOOK_URL` | なし | 利用枠の使用率が 100% 未満に下がったときに通知する Discord Webhook(継続実行モードのみ) |

CLI オプションは同名の環境変数より優先します。`--database` と `--table` は、英字または `_` で開始し、英数字と `_` だけで構成される SQL 識別子である必要があります。

## 保存データ

初回の保存時に、GreptimeDB HTTP SQL API を使って `append_mode=true` の対象テーブルを作成します。

| 列 | 型 | 内容 |
| --- | --- | --- |
| `ts` | `TIMESTAMP(3)` | 取得時刻。time index |
| `provider`, `provider_source`, `account_key`, `usage_window` | `STRING` | 時系列タグ |
| `account_email`, `account_organization` | `STRING` | CodexBar が返したアカウント情報 |
| `used_percent`, `window_minutes`, `resets_at` | 数値・時刻 | 利用枠の値 |
| `usage_updated_at`, `credits_remaining` | 時刻・数値 | 取得元の更新時刻と残クレジット |

各プロバイダー・アカウントには `usage_window = 'snapshot'` の行を保存します。標準の `primary`、`secondary`、`tertiary` は別行で保存し、追加の利用枠は `usage_window = 'extra:<id>'` として保存します。

確認クエリ:

```sql
SELECT
  ts, provider, provider_source, account_email, usage_window,
  used_percent, window_minutes, resets_at, credits_remaining
FROM llm_usage_snapshots
ORDER BY ts DESC
LIMIT 100;
```
