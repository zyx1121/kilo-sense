import Foundation

/// 字幕顯示狀態。Transcriber 更新、SwiftUI 觀察。
@MainActor @Observable
final class CaptionModel {
    /// 已定稿（白字）。單行顯示時 view 取尾部。
    private(set) var finalized: String = ""
    /// 進行中、會被覆蓋的暫定段（灰字）。
    private(set) var volatile: String = ""
    /// 是否顯示 overlay（靜音一段後收合）。
    private(set) var visible: Bool = false

    private var hideTask: Task<Void, Never>?

    func setVolatile(_ text: String) {
        volatile = text
        bump()
    }

    func commitFinal(_ text: String) {
        finalized += text
        volatile = ""
        if finalized.count > 200 { finalized = String(finalized.suffix(200)) }
        bump()
    }

    /// 有新內容就顯示；靜音 3 秒後收合並清空（回到只剩瀏海）。
    private func bump() {
        visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.visible = false
            self.finalized = ""
            self.volatile = ""
        }
    }
}
