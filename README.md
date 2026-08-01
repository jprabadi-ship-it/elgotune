# Elgotune

MX ERGO と ERGO M575 のボタン・ポインタ・スクロールをまとめて調整する、macOS 向けの常駐アプリです。無料・広告なし・ネットワーク通信なし。

**[製品ページ](https://elgotune.gigowat.com) ・ [ダウンロード](https://github.com/jprabadi-ship-it/elgotune/releases/latest) ・ [プライバシーポリシー](https://elgotune.gigowat.com/privacy.ja.html)**

> Tunes the buttons, pointer and scrolling of the Logitech MX ERGO and ERGO M575 on macOS.
> Free, ad-free, and makes no network connections. The app is in English outside Japanese locales.
> See the [product page](https://elgotune.gigowat.com/index.en.html).

## できること

- **全ボタンの割り当て** — 精密モード、左右・中クリック、戻る／進む、ホイールの左右チルト、デバイス切替
- **短押しと押しっぱなしで別々の操作**（判定時間は 100〜1500ms）
- **押しながら転がしてスクロール**、および上下左右の**方向ジェスチャー**
- **慣性スクロール** — ホイールを止めたあとの滑走。長さと初速を調整可能
- **ポインタの速度と加速** — デバイス単位で解像度と加速カーブを設定
- **スクロールの速さ・加速・縦横反転**
- **アプリ別の無効化** — 登録したアプリが前面のときは標準動作に戻る
- 任意のキーボードショートカットの割り当て、設定の書き出し／読み込み、バッテリー表示、診断ログ

## 対応デバイス

MX ERGO と ERGO M575（M575S / M575SP を含む）のみを対象とします。HID++ の `DEVICE_NAME (0x0005)` でモデル名を読み取り、**一致しない Logitech デバイスにはボタン機能を一切設定しません**。

| 機種 | 対応する内容 |
|---|---|
| MX ERGO（Unifying レシーバー） | 全ボタン、ポインタ、スクロール、デバイス切替 |
| ERGO M575 / M575S / M575SP（Bluetooth・Bolt） | 左右・中クリック、戻る／進む、ポインタ、スクロール |

M575 系は Bluetooth 接続時に HID++ の `CHANGE_HOST` へ対応しないため、デバイス切り替えは本体のボタンをそのまま使います（アプリは横取りしません）。

## 必要な環境と権限

macOS 14 以降。トラックボールを制御するため、次の3つの許可が必要です（初回起動時にガイドが出ます）。

| 権限 | 用途 |
|---|---|
| アクセシビリティ | 左右クリックの監視、押しっぱなしジェスチャーの判定 |
| 操作送信 | 割り当てたキー操作・クリックの実行 |
| 入力監視 | トラックボール本体との通信、ボタン入力の受け取り |

## ビルド

```sh
swift build && swift test
swift run PrecisionButton
```

アプリバンドルとして生成する場合:

```sh
./scripts/build-app.sh
open "/tmp/elgotune-stage/Elgotune.app"
```

`build-app.sh` はキーチェーンの Apple Development / Developer ID 証明書を自動で使って署名します（`ELGOTUNE_SIGN_IDENTITY` で明示指定も可能）。**署名IDが安定していれば、アプリを更新してもアクセシビリティと入力監視の許可が維持されます。** 署名IDがない場合はアドホック署名にフォールバックし、その場合は更新のたびに許可の再登録が必要です。

配布用ビルドは `scripts/release.sh`（Hardened Runtime 付き署名 → DMG → 公証 → ステープル → `spctl` 検証）。Developer ID 証明書と notarytool のプロファイルが必要です。

```sh
xcrun notarytool store-credentials Elgotune \
  --apple-id <apple-id> --team-id <team-id> --password <app用パスワード>
```

## 実装上の注意点

- **ポインタの速度・加速は非公開APIに依存します。** `IOHIDEventSystemClient` でデバイスの `HIDPointerResolution` と加速値を直接書き換えています。公開APIの `NXEventStatus` は値を受理するものの、接続中のデバイスには反映されません。シンボルは `dlsym` で解決しているため、将来の macOS で失われてもアプリは起動し、ポインタ調整だけが無効になります。この依存のため **Mac App Store では配布できません**
- **左右クリックの割り当ては、接続中の他社製マウスにも適用されます。** macOS のイベントにデバイスの区別がないためです。左右クリックを標準のままにすれば影響はありません
- 終了時に、ポインタ設定と転送中のボタンをすべて標準状態へ戻します
- プロジェクトが Google ドライブ上にあると拡張属性が即座に復活して `codesign` が失敗するため、バンドルは `/tmp/elgotune-stage` で組み立てて署名しています

## 言語

日本語環境では日本語、それ以外では英語で表示されます。日本語のリテラルをそのまま翻訳キーにしているため、保守するのは `Sources/PrecisionButton/Resources/en.lproj/Localizable.strings` の英訳だけです。CI が未翻訳のキーを検出します。

## 支援

無料で公開しています。役に立ったと感じていただけたら、[Amazon ほしい物リスト](https://www.amazon.co.jp/hz/wishlist/ls/WFRWJC8J65NF)から。支援の有無で機能は変わりません。

不具合の報告や要望は Issues、または admin@gigowat.com までどうぞ。

## ライセンス

[GNU General Public License v3.0](LICENSE)

Elgotune は Logitech International S.A. とは関係のない独立した製品です。MX ERGO、ERGO M575、Logi Options+ は Logitech International S.A. の商標であり、対応機種を示す目的でのみ使用しています。
