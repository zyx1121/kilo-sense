import Foundation
import Speech

// kilo M1a — 探測 SpeechTranscriber 語言支援，先把「繁中能不能用」這個最大風險驗掉。
// 純查詢、免任何權限。M1b 再接 ScreenCaptureKit 系統音訊 → SpeechAnalyzer 串流轉錄。

let supported = Array(await SpeechTranscriber.supportedLocales)
let installed = Array(await SpeechTranscriber.installedLocales)

func dump(_ title: String, _ locales: [Locale]) {
    print("=== \(title) (\(locales.count)) ===")
    for id in locales.map({ $0.identifier }).sorted() { print("  \(id)") }
}

dump("supportedLocales", supported)
dump("installedLocales", installed)

let ids = supported.map { $0.identifier.lowercased() }
func has(_ pred: (String) -> Bool) -> Bool { ids.contains(where: pred) }

print("---")
print("繁中 zh-Hant/zh-TW : \(has { $0.contains("hant") || $0.contains("_tw") } ? "✅ 有" : "❌ 無")")
print("簡中 zh-Hans/zh-CN : \(has { $0.contains("hans") || $0.contains("_cn") } ? "✅ 有" : "❌ 無")")
print("任何中文 zh*       : \(has { $0.hasPrefix("zh") } ? "✅ 有" : "❌ 無")")
