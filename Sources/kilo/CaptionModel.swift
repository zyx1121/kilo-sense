import Foundation

/// 字幕顯示狀態。Transcriber 餵辨識結果，SwiftUI 觀察。
/// 顯示與辨識解耦：analyzer 一段段給，這裡用打字機逐字推進，做出連貫感。
@MainActor @Observable
final class CaptionModel {
    /// 已定稿（白字）。
    private(set) var finalized: String = ""
    /// 逐字顯示中的 volatile（灰字）——打字機追到 targetVolatile。
    private(set) var shownVolatile: String = ""
    /// 是否展開顯示（靜音後收合）。
    private(set) var visible: Bool = false

    private var targetVolatile: String = ""
    private var typeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    func setVolatile(_ text: String) {
        targetVolatile = text
        appear()
        pumpTypewriter()
    }

    func commitFinal(_ text: String) {
        finalized += text
        if finalized.count > 200 { finalized = String(finalized.suffix(200)) }
        targetVolatile = ""
        shownVolatile = ""
        appear()
    }

    /// 逐字把 shownVolatile 推進到 targetVolatile（35ms/字）。
    private func pumpTypewriter() {
        guard typeTask == nil else { return }  // 已在推進，loop 會讀到新 target
        typeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if shownVolatile == targetVolatile { break }
                if targetVolatile.hasPrefix(shownVolatile) {
                    let end = targetVolatile.index(targetVolatile.startIndex,
                                                   offsetBy: shownVolatile.count + 1)
                    shownVolatile = String(targetVolatile[..<end])
                } else {
                    shownVolatile = targetVolatile  // 辨識回頭改字，直接對齊不卡住
                }
                try? await Task.sleep(for: .milliseconds(35))
            }
            self?.typeTask = nil
        }
    }

    /// 有內容就展開；靜音 3 秒收合並清空（回到只剩瀏海）。
    private func appear() {
        visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            visible = false
            finalized = ""
            shownVolatile = ""
            targetVolatile = ""
        }
    }
}
