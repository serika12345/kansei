# Kansei Mission Close

Mission Controlに閉じるボタンを重ねるアプリケーションです。

## Run

```sh
nix develop
swift run KanseiMissionClose
```

初回起動時はアクセシビリティ権限を許可してください。

## What It Does

- `AXUIElement`で各アプリのウィンドウを列挙します。
- private SPIの`_AXUIElementGetWindow`をC shim経由で呼び、`CGWindowID`へ変換します。
- `CGWindowListCopyWindowInfo`で`CGWindowID`に対応するboundsを取得します。
- 透明な`NSPanel`を全Spaceに表示し、取得したboundsの左上に閉じるボタンを描画します。
- ボタンクリック時は`kAXCloseButtonAttribute`への`kAXPressAction`を優先し、失敗時に`"AXClose"`アクション文字列へフォールバックします。
