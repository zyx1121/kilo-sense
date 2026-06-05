# 從 CLI 開發 macOS App（不開 Xcode）

> 摘要筆記。完整流程見 utils skill `macos-cli-dev` + 參考實作 [zyx1121/shake](https://github.com/zyx1121/shake)。
> 整理日期：2026-06-05

---

## 核心鏈

```
編輯 .swift → make bundle → open .app → pgrep / osascript / log stream 驗證
```

SwiftPM 產 executable；手刻 Makefile 把 binary 包成 `.app` bundle 並 codesign。**沒有 `.xcodeproj`，不開 Xcode IDE。**

**為什麼走這條**：乾淨 diff、可重現 build、agent 也能改。適合個人/內部 menubar、overlay、AppKit+SwiftUI，不上 App Store。

## 三個檔定義專案

- **`Package.swift`** — `.executableTarget`，`platforms: [.macOS(.v14)]`（對齊 Info.plist）。SwiftPM 預設遞迴抓 path 下所有 `.swift`。
- **`Resources/Info.plist`** — 關鍵欄位：
  - `CFBundleIdentifier = dev.<you>.<app>`（**TCC 認 bundle id + team id**，跨 rebuild 沿用權限）
  - `NSPrincipalClass = NSApplication`、`CFBundlePackageType = APPL`
  - `LSUIElement = true`（menubar-only：無 Dock、不在 Cmd-Tab）
  - `LSMinimumSystemVersion`、`NSHighResolutionCapable`
- **`Makefile`** — `bundle` target：
  ```makefile
  bundle: build
  	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
  	cp $(BIN_PATH) $(CONTENTS)/MacOS/$(APP_NAME)
  	cp Resources/Info.plist $(CONTENTS)/Info.plist
  	codesign --force --options runtime --sign $(SIGN_ID) $(APP_BUNDLE)
  ```

## Codesign — Apple Dev cert vs ad-hoc

| 簽法 | 後果 |
|---|---|
| `--sign -`（ad-hoc） | 每次 rebuild cdhash 變 → **TCC 權限要重 grant** |
| `--sign <SHA-1 hash>`（Apple Development） | Team ID 穩定 → **rebuild 不掉權限** |

→ 會戳 螢幕錄製 / Accessibility 的 app 一定用 Apple Dev cert。撈 hash：`security find-identity -p codesigning -v`。
`--options runtime`（Hardened Runtime）：Notarization 必須，平常開著無害（除非 JIT / 動態 dlopen）。

## Dev loop 指令

| 動作 | 指令 |
|---|---|
| build + bundle | `make bundle` |
| launch | `open build/<App>.app` |
| 在跑嗎 | `pgrep -l <App>` |
| 視窗狀態（免截圖） | `osascript -e 'tell application "System Events" to get name of every window of process "<App>"'` |
| log（NSLog 全進來） | `log stream --predicate 'process == "<App>"' --style compact` |
| 驗簽 | `codesign -dvvv build/<App>.app` |

## 關鍵 gotcha

- **信 build 不信 LSP**：`sourcekit-lsp` 單檔孤立 parse，會誤報 `Cannot find type` 即便同 module 別檔有。`swift build` 是 whole-module，pass 就 work。
- **座標系 Cocoa vs CG**（全 mac dev 最大坑）：Cocoa 原點左下、Y 向上（`NSEvent.mouseLocation`/`NSWindow.frame`/`NSScreen.frame`）；CG 原點左上、Y 向下（`CGEvent`/`AXValue`/`CGDisplayBounds`）。轉換：`cgY = primaryHeight - cocoaY`。
- **Overlay 用 `NSPanel` 不用 `NSWindow`**：`styleMask=[.borderless,.nonactivatingPanel]`、`level=.screenSaver`(蓋系統 UI) 或 `.statusBar`、`collectionBehavior=[.canJoinAllSpaces,.stationary]`。
- **TCC**：`AXIsProcessTrusted()`(不彈) / `AXIsProcessTrustedWithOptions`(彈)；`CGPreflightScreenCaptureAccess()`(不彈) / `CGRequestScreenCaptureAccess()`(彈)。Swift 6 strict concurrency 下 `kAXTrustedCheckOptionPrompt` 會被嫌，直接用字面值 `"AXTrustedCheckOptionPrompt"`。
- **系統音訊只用 ScreenCaptureKit**（禁 BlackHole / virtual device）。

## 何時切回 Xcode

Live SwiftUI Preview · LLDB step-debug GUI · Instruments · provisioning profile（Push/iCloud/sandbox capability）· App Store 上架。
要時 `open Package.swift`（Xcode 14+ 直接吃 SwiftPM），用完回 CLI。
