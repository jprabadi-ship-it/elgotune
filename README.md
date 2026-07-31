# ErgoTune

MX ERGO と ERGO M575 のボタン・ポインタ・スクロールをまとめて調整する、軽量なメニューバーアプリです。バンドルIDは `jp.local.PrecisionButton` のままで、旧称は Precision Button です。

## 対応デバイス

MX ERGO と ERGO M575（M575S / M575SP を含む）のみを対象とします。HID++の `DEVICE_NAME (0x0005)` でモデル名を読み取り、一致しないLogitechデバイスにはボタン機能を一切設定しません。

## 現在の機能

- Logitech Unifying / Bolt USB Receiver とBluetooth HID++デバイスの検出
- HID++ 2.0 `REPROG_CONTROLS_V4` による精密モード、戻る、進むボタンの一時転送
- macOSイベントタップによる左右クリックのカスタマイズ
- Mission Control、アプリケーションウインドウ、デスクトップ表示、中央クリック、Enterキー、Command+Backspaceの割り当て
- 任意のキーボードショートカットの記録と送出
- 短押しと押しっぱなしへの個別割り当て（開始判定100〜1500ms、50ms刻み）
- 精密モード、左右・中クリック、戻る、進む、デバイス切替のボタン別設定
- 左右クリックを押している間のトラックボール・スクロールモード
- 左右クリック押しっぱなし＋上・下・左・右ジェスチャーへの個別割り当て（しきい値到達時に即実行）
- 設定保存、メニューバー常駐、接続診断ログ

## ビルドと起動

```sh
swift build
swift run PrecisionButton
```

通常のmacOSアプリとして生成する場合:

```sh
./scripts/build-app.sh
open "/tmp/ergotune-stage/ErgoTune.app"
```

初回起動時は、画面の「権限を許可…」から次の権限を許可してください。

- プライバシーとセキュリティ > アクセシビリティ
- プライバシーとセキュリティ > 入力監視

権限変更後はアプリを再起動してください。

## 注意

`build-app.sh` はキーチェーンの Apple Development / Developer ID 証明書を自動で使って署名します（`PRECISION_SIGN_IDENTITY` で明示指定も可能）。署名IDが安定していれば、アプリを更新してもアクセシビリティと入力監視の許可は維持されます。署名IDが見つからない場合はアドホック署名にフォールバックし、その場合は更新のたびに許可の再登録が必要です。

なお、プロジェクトがGoogleドライブ上にあると拡張属性が即座に復活して `codesign` が失敗するため、アプリバンドルは `/tmp/ergotune-stage` で組み立てて署名しています。

デバイスを開けない場合、まず権限を確認してください。システム設定の各項目から「ErgoTune」をいったん削除し、`/Applications/ErgoTune.app` を追加し直してからアプリを再起動します。診断ログは `~/Library/Logs/ErgoTune.log` にも記録されます。

権限に問題がないのに開けない場合は、SteerMouse など他のドライバがデバイスを占有しているか、HID++の転送設定が競合している可能性があります。カスタマイズを無効にすると、ボタンはデバイスの標準動作へ戻ります。

左右クリックは、割り当てを標準から変更した場合のみmacOSイベントを横取りします。変更した左右ボタンではドラッグ操作を利用できません。アプリ自身のウインドウ内では左クリックを常に通常動作として残すため、「標準に戻す」で通常動作へ復帰できます。右クリックの押しっぱなしジェスチャーはアプリ上でもテストできます。

手元で使う分にはApple Development証明書の署名で足ります。

## 言語

日本語環境では日本語、それ以外の環境では英語で表示されます。日本語のリテラルをそのまま翻訳キーにしているため、`Sources/PrecisionButton/Resources/en.lproj/Localizable.strings` の英訳だけを保守すれば済みます。バンドルの開発リージョンは英語なので、未対応の言語環境は日本語ではなく英語にフォールバックします。

## 配布用ビルド

`scripts/release.sh` が、Hardened Runtime 付きの署名 → DMG 作成 → 公証 → ステープル → `spctl` 検証まで行います。Apple Developer Program への加入と、次の準備が必要です。

1. Developer ID Application 証明書をキーチェーンに用意（`ERGOTUNE_RELEASE_IDENTITY` で明示指定も可能）
2. notarytool のプロファイルを一度だけ作成

```sh
xcrun notarytool store-credentials ErgoTune \
  --apple-id <apple-id> --team-id <team-id> --password <app用パスワード>
```

```sh
./scripts/release.sh                  # 署名・DMG作成・公証・ステープル
./scripts/release.sh --skip-notarize  # 署名とDMG作成まで
```

配布にあたっては、非公開APIの `IOHIDEventSystemClient` を使っている点に注意してください（Mac App Storeでは配布できません。ポインタ設定の実装上、公開APIでは代替できません）。
