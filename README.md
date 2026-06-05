# kilo

> macOS 感官 agent — 聽見你看的影片與對話、看見螢幕，做即時分析。

**狀態**：scaffold / M1。當前 infra MVP = 在 MacBook 瀏海（動態島）顯示串流即時字幕。

## Pipeline

```
系統音訊 (ScreenCaptureKit) → SpeechAnalyzer / SpeechTranscriber → 瀏海 overlay 字幕
```

## Milestones

- **M1a**（現在）— 探測 `SpeechTranscriber` 語言支援、驗繁中：`make locales`
- **M1b** — ScreenCaptureKit 系統音訊 → SpeechAnalyzer → console 印 volatile/final
- **M2** — 接 `NSPanel` 瀏海 overlay：單行滾動，volatile(灰) / final(白)
- **M3** — 加麥克風音訊源（`AudioSource` protocol 的第二個實作）

## Dev（不開 Xcode）

```bash
make locales   # 跑 M1a，dump 支援語言
make bundle    # 打包 .app + codesign
make run       # bundle + open
```

需 macOS 26+（SpeechAnalyzer）與一張 Apple Development cert（hash 放本地 `Makefile.local` 的 `SIGN_ID`）。

## 設計依據

`docs/` — SpeechAnalyzer survey、瀏海 overlay 自刻筆記、CLI 開發流程。
