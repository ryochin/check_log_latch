# check_log_latch

[![CI](https://github.com/ryochin/check_log_latch/actions/workflows/ci.yml/badge.svg)](https://github.com/ryochin/check_log_latch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) | 日本語

ログに追記された新規行を正規表現で検査し、**人間が `--reset` で解除するまで CRITICAL を
返し続ける** Nagios プラグインです。

```text
CRITICAL - log pattern latched since 2026-07-08T10:00:00+09:00; count=1; latest='FATAL database connection failed'; clear with --reset | scanned_bytes=123B matches=1 latched=1
```

## なぜ `check_log` では足りないのか

標準の `check_log` は実行間の *差分* を検出します。つまり状態監視ではなくイベント検知です。

```text
1. あるチェックで対象文字列を検出
2. CRITICAL を返す
3. oldlog / state が更新される
4. 次のチェックではその行は既知扱い
5. OK に戻る
```

5分間隔の監視では、CRITICAL はちょうど1回のチェック分しか続きません。要件が

```text
ログに特定文字列が出たら CRITICAL
人間が確認して解除するまで CRITICAL を維持
解除後は古いログ行で再検出しない
```

であれば、`check_log` よりラッチ型のプラグインが適しています。

## 機能

- 指定ファイルを監視し、新規行を1つ以上の正規表現と照合する
- 一度検出したら **ラッチ** 状態を保存する
- ラッチ中は新規一致がなくても `CRITICAL` を返す
- ラッチ中はログファイルが消えても、読めなくなっても `CRITICAL` を維持する
- `--reset` で手動解除でき、その際に読み取り位置を現在の EOF まで進める
- 解除には正規表現も、読めるログファイルも、壊れていない状態ファイルも、使えるロック
  ファイルさえも要求しないため、ラッチが解除不能になることがない
- 逆に `--reset` 以外では解除されない。ディスク満杯でも、状態ファイルの破損でも、
  `chmod` でも、暴走した正規表現でも解除されない
- ログローテーションや truncate をある程度吸収する
- 端末エスケープシーケンスを除去し、色付きログを素のテキストとして読み・照合できるようにする
- ログ行の内容がプラグイン出力やパフォーマンスデータを偽装できないようにする
- 想定外の失敗やコマンドラインの誤りも含め、Nagios プラグイン形式の終了コードを返す
- ブロックしない。ログファイルに対しても、同じチェックの並行実行に対しても

```text
0 = OK
1 = WARNING
2 = CRITICAL
3 = UNKNOWN
```

## 動作要件

- Python 3.8 以降
- POSIX 環境（`fcntl` と `O_NOFOLLOW` を使用）
- サードパーティ依存なし

## インストール

```sh
install -o root -g wheel -m 0755 check_log_latch.py /usr/local/libexec/nagios/check_log_latch

install -d -o nagios -g nagios -m 0750 \
  /var/spool/nagios/check_log_latch
```

Linux では `wheel` が存在しない場合があります。その場合は `root` など、環境に応じて
置き換えます。

## クイックスタート

```sh
sudo -u nagios /usr/local/libexec/nagios/check_log_latch \
  -F /var/log/myapp/app.log \
  -p 'FATAL|panic|connection refused' \
  -t myapp \
  -s /var/spool/nagios/check_log_latch
```

初回実行時は、通常は既存ログを無視して現在の EOF から監視を開始します。

```text
OK - initialized at EOF (offset=0) | scanned_bytes=0B matches=0 latched=0
```

ログに対象文字列が追記されると `CRITICAL` になり、解除するまでその状態を維持します。

解除方法です。

```sh
sudo -u nagios /usr/local/libexec/nagios/check_log_latch \
  -F /var/log/myapp/app.log \
  -t myapp \
  -s /var/spool/nagios/check_log_latch \
  --reset
```

```text
OK - latch cleared for /var/log/myapp/app.log | scanned_bytes=0B matches=0 latched=0
```

解除に `-p` は不要です。`-F` と、状態ファイルを特定するオプション（`-t` / `-s`、または
`--state-file`）だけが意味を持ちます。

## 挙動

### 初回実行

既存ログを読み飛ばし、読み取り位置を現在の EOF に設定します。

```text
OK - initialized at EOF (offset=316) | scanned_bytes=0B matches=0 latched=0
```

この文言は初期化を行った実行だけに出ます。2回目以降で新規一致がない場合は
`OK - no matching log lines` になるため、「初期化された直後」なのか「平常運転で何も出て
いない」のかを区別できます。

初回から既存ログも検査したい場合は `--from-start` を指定します。この場合は初期化では
なく通常の検査として扱うため、上記の文言は出ません。

### 新規ログ行にパターン一致

```text
CRITICAL - log pattern latched since ...; count=1; latest='FATAL ...'; clear with --reset
```

同時に、状態ファイルへラッチ情報を保存します。

### 次回以降

ラッチ状態が残っている限り、新規一致がなくても `CRITICAL` を返します。

```text
CRITICAL - log pattern latched since ...
```

### ラッチ中にログファイルが消えた場合

ラッチは監視対象ファイルより長生きします。ログローテーションの一瞬や、アプリの再デプロイで
ファイルが消えても `CRITICAL` を維持します。

```text
CRITICAL - log pattern latched since ...; clear with --reset (log file currently missing: /var/log/myapp/app.log)
```

`--missing` はラッチが無いときにのみ効きます。これがないと、`--missing ok` を付けた環境で
「ファイルが消えた瞬間に勝手に recovery 通知が飛ぶ」ことになり、ラッチ型にした意味が
失われます。

### 手動解除

`--reset` はラッチを解除し、読み取り位置を現在の EOF まで進めます。これにより、解除直後に
アラートの原因となった行を再検出することを防ぎます。`fingerprint` も現在のファイルの
ものへ更新します。

解除時にログファイルを開けない場合は、進める先の EOF が無いため、保存していた読み取り
位置を破棄します。次にそのパスへ現れたファイルは初回実行と同じ扱いになり、先頭からでは
なく EOF から監視を開始します。そうしないと、中身入りのログが再作成された環境で解除直後
に再ラッチしてしまうためです。

これは解除時に開けなかった *すべて* のログファイルに適用されます（存在しない、権限が無い、
ディレクトリに置き換わっている）。解除自体が失敗してしまうと、何をしても解除できないラッチ
が残るためです。解除は成功し、あきらめた内容を出力します。

```text
OK - latch cleared for /var/log/myapp/app.log (log file could not be read, position dropped: [Errno 13] Permission denied: '/var/log/myapp/app.log')
```

状態ファイルが壊れて読めなくなっている場合も、同じ理由で `--reset` はそれを破棄します。

### ログファイルが読めない場合

ファイルは存在するが読めない場合（権限が無い、ディレクトリに置き換わっている、存在確認
から読み取りまでの間に消えた、など）は、traceback で落ちずに UNKNOWN を返します。

```text
UNKNOWN - cannot read log file /var/log/myapp/app.log: [Errno 13] Permission denied: '/var/log/myapp/app.log'
```

読み取るのは通常ファイルだけです。監視対象のパスに名前付きパイプやデバイスファイルが
あった場合も、監視システムに kill されるまでブロックするのではなく、同じように UNKNOWN
を返します。

```text
UNKNOWN - cannot read log file /var/log/myapp/app.log: [Errno 22] not a regular file: '/var/log/myapp/app.log'
```

ただし、ファイルが消えた場合と同じく、ラッチが残っていればそちらを優先します。そうしないと、
`chmod` ひとつ、あるいはディレクトリを残して終わった再デプロイだけで、誰も解除していない
`CRITICAL` を降格できてしまうためです。

```text
CRITICAL - log pattern latched since ...; clear with --reset (log file cannot be read: [Errno 13] Permission denied: '/var/log/myapp/app.log')
```

その他の想定外の失敗も UNKNOWN として報告します。traceback で死んだプラグインは終了
コード `1` を返し、Nagios はそれを WARNING と解釈してしまいます。実際には何も測定できて
いない実行に対して、それは誤った重大度です。

コマンドラインが不正な場合も同じ理由で UNKNOWN を返します。`argparse` は既定で終了コード
`2` を返し、Nagios はそれを CRITICAL と解釈するため、command 定義の打ち間違いや値の入らな
かった `$ARGn$` が、一度も開いていないログファイルに対するアラートになってしまいます。

```text
UNKNOWN - the following arguments are required: -F/--file
```

## オプション一覧

| オプション | 説明 |
|---|---|
| `-F`, `--file` | 監視対象ログファイル。必須。 |
| `-p`, `--pattern` | CRITICAL にする正規表現。複数回指定可、どれか1つに一致すれば CRITICAL。`--reset` 時のみ省略可。 |
| `-t`, `--tag` | 状態ファイル名に使う識別子。指定推奨。 |
| `-s`, `--state-dir` | 状態ファイルを保存するディレクトリ。デフォルトは `/var/spool/nagios/check_log_latch`。 |
| `--state-file` | 状態ファイルのパスを直接指定。`--state-dir` と `--tag` より優先。 |
| `-i`, `--ignore-case` | 大文字小文字を区別せずに一致させる。 |
| `--missing` | ログファイルが存在しないときの状態。`ok` / `warning` / `critical` / `unknown`。デフォルトは `unknown`。ラッチ中は無視される。 |
| `--max-bytes` | 1回の実行でスキャンする最大バイト数。未指定または `0` で無制限。 |
| `--max-output` | 出力に載せる一致行の最大文字数。デフォルトは `120`、最小値は `1`。 |
| `--lock-timeout` | 同じチェックの並行実行を待つ秒数。デフォルトは `10`。 |
| `--scan-timeout` | スキャンに許す秒数。デフォルトは `30`、`0` で無制限。 |
| `--from-start` | 初回実行時に、既存ログも先頭から検査する。 |
| `--reset` | ラッチ状態を解除し、現在の EOF まで読み取り位置を進める。 |
| `-V`, `--version` | バージョンを表示して終了する。 |

Nagios プラグインの慣例では `-t` は timeout に割り当てられています。ただしこのプラグインの
待ちは2つだけで、どちらも `--lock-timeout` と `--scan-timeout` という長い名前で上限が
付いており、どちらも頻繁に打つものではありません。そのため `-t` は毎回のコマンドラインで
実際に打つオプションに割り当てています。

### `-p`, `--pattern`

```sh
-p 'FATAL|panic|connection refused'
```

次のように分けて書いても同じです。

```sh
-p 'FATAL' -p 'panic' -p 'connection refused'
```

### `-t`, `--tag`

同じログファイルを複数条件で監視する場合、条件ごとに別の tag を使います。

```text
myapp-fatal
myapp-timeout
myapp-auth
```

tag はファイル名になるため、`A-Za-z0-9_.-` 以外の文字は `_` に畳まれます。畳まれた部分だけ
が違う2つの tag は、このままでは同じ状態ファイル、つまり同じラッチを共有してしまうため、
畳み込みが発生した tag には元の文字列の短いダイジェストが付きます。

```text
myapp-fatal   ->  myapp-fatal.json
app/one       ->  app_one_196083a4.json
app one       ->  app_one_15f75da5.json
```

### `-s`, `--state-dir`

Nagios 実行ユーザーが書き込める必要があります。**`/tmp` や `/var/tmp` のような誰でも
書けるディレクトリを指定してはいけません。** プラグインは状態ディレクトリが以下に該当
する場合、`UNKNOWN` で停止します。

```text
シンボリックリンクである
root でも実行ユーザーでもない所有者である
group に書き込み権がある
other に書き込み権がある
```

`--state-file` を使う場合も同じ検査が働きます。指定したファイルが置かれるディレクトリが
`--state-dir` と同じ基準で検査されるため、`--state-file /tmp/myapp.json` も拒否されます。

### `--max-bytes`

1回の実行でスキャンする量に上限を設け、巨大なログが一気に増えたときにチェックが長時間化
するのを防ぎます。

```sh
--max-bytes 5242880
```

デフォルトは無制限で、`0` を指定した場合も同じ意味になります。明示的に指定しない限り
取りこぼしは発生しません。追記分は 1 MiB ずつに区切って照合するため、1回の実行に必要な
メモリは「前回からの増加量」ではなく「ログ中の最長行」で決まり、上限なしでも実行コストが
破綻しません。

制限にかかると、読み取り開始位置を `現在のサイズ - max-bytes` まで前進させます。つまり
**制限を超えた古い未スキャン部分は検査されずに捨てられます**。負荷保護と引き換えの
取りこぼしなので、値は余裕を持たせてください。制限にかかった実行では、出力に注記が
付きます。

```text
OK - no matching log lines; scanned_bytes=5242880 (scan limited by --max-bytes)
```

区切り位置は計算結果次第で行の途中に落ちるため、実際のスキャンはその位置以降で最初に
現れた行境界から再開します。行の断片はログ行ではなく、`^ERROR` のような行頭アンカー付き
のパターンに食わせると、本来は行頭に無かった文字列に一致してしまうためです。

この判定は、制限がかかった実行だけでなく毎回行います。制限で切り取った範囲に改行が1つも
含まれない場合（`--max-bytes` より長い1行など）、その実行では行が1つも完成せず、保存される
読み取り位置が行の途中に留まります。次の実行にはそれを知らせる制限がないため、保存位置の
直前のバイトを見て判断します。

### `--lock-timeout`

同じチェックの実行はロックファイルで直列化します。2つの実行が同じ読み取り位置から読んで
1行を二重に数える、といったことを防ぐためです。ロックが取れなかった実行はしばらく待ち、
`--lock-timeout` 秒を超えたら諦めます。

```text
UNKNOWN - another run still holds the lock on /var/spool/nagios/check_log_latch/myapp.json after 10s
```

無制限に待つと、最後は監視システムに kill されて何も報告できなくなります。`service_check_timeout`
より小さい値にしておけば、その沈黙ではなくこのメッセージが出ます。なお、ここでもラッチは
優先されます。ロックを諦めたことは CRITICAL への注記であって、置き換えではありません。

ロックファイルが「他の実行に握られている」のではなく、そもそも *使えない* 場合（その名前に
シンボリックリンクが置かれている、状態ディレクトリが読み取り専用になった、など）は別扱いに
なります。待っても解決しないためです。ラッチが無ければ UNKNOWN、あれば CRITICAL を維持
します。`--reset` だけは例外で、ロックを取らずに実行して、そのことを出力に注記します。
`--reset` でしか解除できないラッチが、ロックファイルの都合で解除不能になってはならないため
です。

```text
OK - latch cleared for /var/log/myapp/app.log (cleared without the lock, a concurrent run could undo this: [Errno 62] Too many levels of symbolic links: '...')
```

この注記は、引き換えに何を失うかを示しています。ロックファイルが壊れる *前* にロックを
取った実行は、その時点の状態を保持したままです。それが処理を終えて書き込むと、解除の結果は
その下に埋もれ、次のチェックでラッチが復活し得ます。ロックファイルを直したうえで、解除が
効いているか確認してください。

### `--scan-timeout`

このプラグイン自体はブロックしませんが、*正規表現* は無制限に時間を使い得ます。`(a+)+` や
`(\w+)*` のような入れ子の量指定子は破滅的なバックトラックを起こし、一致しない数十文字の行
1本で、どんな監視システムの待ち時間よりも長く `re.search` が走り続けます。kill された
チェックは何も報告できません。

そのため、スキャンそのものにも期限を設けています。デフォルトは30秒です。

```text
UNKNOWN - scan of /var/log/myapp/app.log did not finish within 30s
```

実際のスキャンに対しては十分すぎる値です（40 MB のログでも1秒かかりません）。つまりこれに
かかったときは、上限が小さすぎるのではなく正規表現を直すべきです。発動時は状態を保存しま
せん。スキャンが途中で止まっているためで、次の実行も同じバイト列を読み、正規表現を直すまで
同じ報告を繰り返します。ここでもラッチは優先されます。

`0` で無効化できます。いずれの場合も `service_check_timeout` より小さい値にしてください。

## パフォーマンスデータ

何かを測定した実行はすべて同じ3つのラベルを出力します。解除した回やログファイルが無かった
回でグラフが途切れないようにするためです。

```text
scanned_bytes  その実行でスキャンした完全な行のバイト数
matches        その実行で一致した行数
latched        ラッチ中なら 1、そうでなければ 0
```

何も測定できなかった実行にパフォーマンスデータは付きません（ログが読めない、状態ファイルが
壊れている、コマンドラインが不正、など）。ただし2つは例外です。ログファイルが *存在しない*
場合は「ゼロ」という測定結果なので、`--missing` の設定にかかわらずラベルを出力します。
そしてラッチを報告する実行は、何も読めなかった場合でも `latched=1` と0を出力します。
アラートが立っていることがグラフから消えないようにするためです。

出力のサニタイズも行います。Nagios は最初の `|` で出力を切り、以降をパフォーマンスデータ
として解釈します。そのため、一致したログ行に `|` が含まれていると（パイプ区切りのログは
珍しくありません）、メッセージが途中で切れ、グラフも壊れます。メッセージ中の `|` は `/`
に置き換えます。

```text
2026-07-08 | FATAL | disk full     ->     latest='2026-07-08 / FATAL / disk full'
```

制御文字も同じ理由で空白に置き換えます。改行は long output の開始とみなされるためです。
一致行はさらに `repr()` を通すため、制御文字は削除ではなくエスケープされた形で残ります。

端末エスケープシーケンスは、それより早い段階でシーケンスごと削除します。ログ行を読み込んだ
直後、パターンを適用する前に落とします。Rust や Go のロガーはログレベルを色付けするため、
出力をファイルにリダイレクトしたログには、描画するものが何もないまま色だけが残ります。

```text
\x1b[31mERROR\x1b[0m db down     ->     latest='ERROR db down'
```

これは表示だけの話ではありません。パターンは削除後の行を見ます。そのため `-p '^ERROR'` は
手前の色ではなく単語そのものに固定され、`-p 'ERROR db'` も間に挟まるリセットコードに
邪魔されません。`--max-output` が数えるのも、同じ理由で実際に表示される文字数です。

状態ファイルに入るのは、そこまでを終えた行です。エスケープシーケンスは無く、連続する空白は
1 つに畳まれ、`--max-output` が適用されています。`|` と、空白ではない制御文字はそのまま
記録され、出力の段階で初めて無害化されます。

## Nagios 設定例

### command 定義

```nagios
define command {
  command_name  check_log_latch
  command_line  $USER1$/check_log_latch -F '$ARG1$' -p '$ARG2$' -t '$ARG3$' -s /var/spool/nagios/check_log_latch
}
```

### service 定義

```nagios
define service {
  use                   generic-service
  host_name             myapp-host
  service_description   MyApp latched error log
  check_command         check_log_latch!/var/log/myapp/app.log!FATAL|panic|connection refused!myapp

  normal_check_interval 5
  retry_check_interval  1
  max_check_attempts    1

  notification_options  c,r
}
```

### `max_check_attempts`

`1` でよいです。ログ検知はイベント性が強いためです。`check_log` 単体の場合、
`max_check_attempts` が `3` などだと、初回の `CRITICAL` が soft state になり、リトライ時に
`OK` へ戻って通知されないことがあります。このプラグインではリトライ中も `CRITICAL` を
維持しますが、初回で hard state にして通知する方が挙動として分かりやすいです。

### `notification_options`

ラッチ型では、recovery 通知を有効にしても意味があります。

```nagios
notification_options c,r
```

`--reset` 実行後、次回チェックで `OK` になれば recovery 通知が飛びます。一方、`check_log`
単体で運用する場合は5分後に自動的に `OK` へ戻るため、recovery 通知がノイズになりがちです。
その場合は `r` を外します。

```nagios
notification_options c
```

## 設計上の要点: ラッチを解除できるもの

`--reset` だけです。それ以外に実行が遭遇し得る事態はすべて、CRITICAL の *代わり* ではなく
CRITICAL への注記として報告します。そうでなければ、ディスク満杯や `chmod` ひとつで、誰も
確認していないアラートが黙って消えてしまいます。

| 状況 | ラッチ無し | ラッチ有り |
|---|---|---|
| ログファイルが無い | `--missing`（既定は UNKNOWN） | CRITICAL |
| ログファイルが読めない / 通常ファイルでない | UNKNOWN | CRITICAL |
| 他の実行がロックを保持している | UNKNOWN | CRITICAL |
| ロックファイルがそもそも使えない | UNKNOWN | CRITICAL |
| 状態ファイルが書けない | UNKNOWN | CRITICAL |
| スキャンが `--scan-timeout` に達した | UNKNOWN | CRITICAL |
| `latch` はあるが内容が壊れている | — | CRITICAL（詳細は unknown） |
| 状態ファイルが読めない / オブジェクトでない | UNKNOWN | UNKNOWN |

最後の1行だけがラッチの残らない場面ですが、これも OK への降格ではありません。読めない状態
ファイルには尊重すべきラッチも信用できる読み取り位置も無いため、推測せずにそう報告します。
`--reset` で復旧できます。

`--reset` 自体は上記のいずれにも妨げられません。正規表現も、読めるログファイルも、壊れて
いない状態ファイルも、使えるロックファイルも要求しません。

## 設計上の要点: ラッチ中でも読み取り位置を進める

このプラグインで一番重要なのは、**CRITICAL ラッチ中でもログの読み取り位置を進める**
ことです。これをしない場合、次のような問題が起きます。

```text
1. エラー行を検出して CRITICAL
2. ラッチ状態になる
3. 人間が確認して reset
4. 読み取り位置が古いまま
5. 同じエラー行を再検出
6. すぐまた CRITICAL
```

つまり、永遠に解除できない監視になります。そのため、ラッチ中も毎回ログを読み、読み取り
位置だけは最新へ進めます。ラッチ状態は維持しますが、古い行で再検出はしません。

## 状態ファイル

状態ファイルには、読み取り位置とラッチ情報を保存します。パーミッションは `0600` で、
umask に依存しません。

```json
{
  "file": "/var/log/myapp/app.log",
  "fingerprint": "1ff7e57112eec4b23ed2cf53a795c82689ebdd1d",
  "fingerprint_bytes": 256,
  "identity": [
    16777232,
    149095429
  ],
  "last_check": "2026-07-08T10:00:00+09:00",
  "latch": {
    "count": 1,
    "first_match": "FATAL database connection failed",
    "first_pattern": "FATAL|panic",
    "last_seen": "2026-07-08T10:00:00+09:00",
    "latest_match": "FATAL database connection failed",
    "latest_pattern": "FATAL|panic",
    "since": "2026-07-08T10:00:00+09:00"
  },
  "offset": 339
}
```

`latch` が存在する間は、プラグインは `CRITICAL` を返します。ここで問うのは *存在するか*
だけで、内容が壊れていないかは問いません。中身が失われた `latch` であっても「一度は一致
した」という事実は残っており、それを取り消せるのは `--reset` だけだからです。ただし
「いつ」「何に」一致したかは答えられないため、その部分は unknown と表示します。

```text
CRITICAL - log pattern latched since unknown; count=unknown; latest='unknown'; clear with --reset
```

それすら読めないほど壊れている場合（JSON としては妥当だがオブジェクトではない、JSON として
壊れている、UTF-8 ではない）は、参照すべきラッチも信用できる読み取り位置も無いため、黙って
初期化し直すのではなく UNKNOWN を返します。

```text
UNKNOWN - invalid state file /var/spool/nagios/check_log_latch/myapp.json: not a JSON object
```

この場合も `--reset` が状態ファイルを破棄してやり直すため、行き止まりにはなりません。

### ファイル同一性の判定

同じファイルを見続けているかどうかは、次の2つで判定します。

```text
identity           [st_dev, st_ino] のペア
fingerprint        先頭バイト列の SHA-1
fingerprint_bytes  そのハッシュに使ったバイト数（最大 256）
```

`inode` 単独では、ファイルシステムをまたぐと一意になりません。そのため `st_dev` と組に
しています。ただし `st_dev` は、再起動や LVM/dm の再マップ、NFS の再マウントで変わる
ことがあります。`identity` だけで判定すると、これをローテーションと誤認して先頭から
読み直し、**数日前の古いエラー行で勝手に `CRITICAL` になります**。

そこで、両方に `fingerprint` がある場合は、`st_dev` を判定から外し、`fingerprint` と
`inode` の組で判定します。

```text
fingerprint と inode の両方が一致 → 同じファイル。offset から続きを読む
どちらかが不一致                  → 別ファイル。ローテーションとみなし先頭から読む
```

`inode` も一致を要求するのは、`fingerprint` が先頭の一部でしかないためです。固定のバナーで
始まるログはローテーション後も同じ `fingerprint` になるため、`fingerprint` だけで判定すると
新しいファイルを旧 offset から読み始め、**その手前にある行をすべて読み飛ばします**。

256 バイト未満のファイルは、あるだけのバイト数でハッシュを取り、その長さを
`fingerprint_bytes` に記録します。次回の実行は同じ長さの先頭バイト列をハッシュし直して
比較できます。256 バイトに満たないファイルの `fingerprint` を諦めてしまうと、短いログは
`inode` しか手がかりが無くなりますが、`inode` は in-place の truncate を生き延びるため、
書き直された短いログが単なる追記として扱われ、中身を入れ替えた行が一度もスキャンされない
ことになります。

`fingerprint` を取った長さよりもファイルが短くなっている場合、そのファイルは `fingerprint`
の取得元ではあり得ないので、ローテーションとして扱います。

ハッシュを取る対象が無いのは空ファイルだけです。この場合は `inode` だけで判定し、ここでも
`st_dev` は加えません。理由は上と同じで、静かな小さいログファイルが、デバイス番号の振り
直しをきっかけに先頭から読み直され、その履歴で再ラッチしてしまってはならないためです。
保存された `inode` も無い場合は、offset を裏付けるものが何も無いため先頭から読みます。行を
読み直す代償は `--reset` で解除できる CRITICAL で済みますが、裏付けの無い offset を信じると、
このチェックが検出すべき行そのものを飛ばすためです。

残る取りこぼしは、truncate 後に旧 offset を超えて書き直され、なおかつ先頭 256 バイトまで
同じ内容になるログです（固定バナーを in-place で書き直した場合など）。`inode` も
`fingerprint` も一致するため、これは追記として扱われます。

## `check_log` との違い

| 項目 | `check_log` | check_log_latch |
|---|---|---|
| 新規ログ検出 | できる | できる |
| 次回チェック | OK に戻る | CRITICAL 継続 |
| 手動解除 | なし | `--reset` |
| Recovery 通知 | ノイズになりがち | 意味がある |
| 状態保持 | 差分位置のみ | 差分位置 + ラッチ |
| 汎用監視 | やや弱い | 強い |

## 実運用上の注意

### 運用イメージ

```text
5分ごとにログ差分を見る
↓
対象文字列が新規に出る
↓
CRITICAL 通知
↓
状態ファイルに latch を保存
↓
次回以降も CRITICAL
↓
人間がログや原因を確認
↓
--reset で解除
↓
次回チェックで OK / recovery 通知
```

### 状態ディレクトリの権限

```sh
install -d -o nagios -g nagios -m 0750 /var/spool/nagios/check_log_latch
```

誰でも書けるディレクトリを使ってはいけません。他ユーザーが先に同名ディレクトリを作れる
場所だと、状態ファイルを差し替えてラッチを勝手に解除したり、任意の内容を仕込んだり
できてしまいます。

プラグイン側でも、状態ディレクトリの所有者と group / other の書き込み権を検査し、状態
ファイル・一時ファイル・ロックファイルはいずれもシンボリックリンクを辿らずに開きます。
プラグイン自身が作成するディレクトリは、途中の階層も含めて、その時点の umask に関わらず
`0750` で作成します。ただし親ディレクトリを正しく用意することが前提です。

### tag は必ず一意にする

同じ tag を複数サービスで共有すると、状態ファイルが衝突し、ラッチも共有されてしまいます。

悪い例です。

```text
service A: -t app
service B: -t app
```

良い例です。

```text
service A: -t app-fatal
service B: -t app-timeout
```

### `--reset` は状態が対応するログに対して打つ

状態ファイルは最後に使われたログファイルを覚えていて、それが変わると出力に注記します。

```text
OK - no matching log lines; scanned_bytes=0 (state last used for a different log file: /var/log/myapp/old.log)
```

多くはサービス定義の他の部分と `-F` が食い違っているケースです。特に問題になるのは
`--reset` で、`-F` が指したファイルから読み取り位置を記録するため、誤ったパスに向けて打つと、
次の本来のチェックが自分のログをローテーションとみなして先頭から読み直し、その履歴で再ラッチ
します。この注記は次回の実行で自動的に消えます。

### 正規表現のエスケープ

`[ERROR]` のような文字列をそのまま探す場合、正規表現では `[` と `]` をエスケープします。

```sh
-p '\[ERROR\]'
```

### 見たままのログに対してパターンを書く

端末エスケープシーケンスは照合の前に削除されるため、色付きの行も色が付いていなかったものと
して照合されます。パターン側で色を考慮する必要はありませんし、色そのものに一致させることも
できません。

### 入れ子の量指定子を避ける

量指定子の付いたグループの中にさらに量指定子がある形（`(a+)+`、`(\w+)*`、`(.*,)*` など）は、
惜しいところで一致しない入力に対して破滅的なバックトラックを起こします。数十文字あれば
数時間走り続けます。`--scan-timeout` があるためチェックが黙って食い潰されることはありま
せんが、正規表現を直すまでその実行は UNKNOWN を返し、ログを一切スキャンできません。
グループごとの量指定子は1つまでにし、可能な範囲でアンカーを付けてください。

### 初回から既存ログを見ない

初回実行時は EOF から始める方が安全です。既存ログまで検査すると、数日前のエラーで突然
`CRITICAL` になる可能性があります。

## 開発

```sh
task lint    # プラグインに ruff、テストスクリプトに shellcheck
task test    # tests/run_tests.sh
task check   # 両方
```

lint は [Task](https://taskfile.dev/) と [uv](https://docs.astral.sh/uv/) 経由で
[ruff](https://docs.astral.sh/ruff/) を実行します。ruff のバージョンは `Taskfile.yml` で、
ルールセットは `ruff.toml` で固定しているため、実行環境によって結果がぶれません。
`task lint:fix` で safe autofix を適用できます。

`tests/run_tests.sh` は使い捨てディレクトリでプラグインを実際に動かすテストで、`bash` と
対象のインタプリタ以外に依存はありません。別のインタプリタで確認する場合は `PYTHON` を
指定します。

```sh
PYTHON=python3.8 bash tests/run_tests.sh
```

GitHub Actions では同じ lint に加え、テストを Linux 上の Python 3.8 / 3.11 / 3.14 と
macOS 上の Python 3.14 で実行します（`.github/workflows/ci.yml`）。

## ライセンス

[MIT](LICENSE)
