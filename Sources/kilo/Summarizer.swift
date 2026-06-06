import Foundation
import OSLog

/// 累積定稿逐字稿，切段後丟給 gpt-5.4-mini 摘要。
/// 切段：停頓 6 秒（沒有新定稿）或累積 ≥500 字，誰先到誰觸發。
@MainActor
final class Summarizer {
    private let store: SummaryStore
    private let metrics: MetricsStore
    private let client: OpenAIClient?
    private var buffer = ""
    private var flushTask: Task<Void, Never>?

    init(store: SummaryStore, metrics: MetricsStore, client: OpenAIClient?) {
        self.store = store
        self.metrics = metrics
        self.client = client
    }

    /// 餵入一段定稿逐字稿（只送 finalized，別送 volatile）。
    func feed(_ finalText: String) {
        buffer += finalText
        if buffer.count >= 500 { flush() } else { scheduleFlush() }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        flushTask?.cancel()
        let segment = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard segment.count >= 10, let client else { return }
        let metrics = self.metrics
        let store = self.store
        Task {
            let start = Date()
            Telemetry.summary.info("summarize request chars=\(segment.count, privacy: .public)")
            do {
                let result = try await client.summarize(segment)
                let latency = Date().timeIntervalSince(start)
                store.add(result.text)
                metrics.recordSummary(tokensIn: result.tokensIn, tokensOut: result.tokensOut, latency: latency)
                Telemetry.summary.info(
                    "summarize done in=\(result.tokensIn, privacy: .public) out=\(result.tokensOut, privacy: .public) latency=\(String(format: "%.2f", latency), privacy: .public)s")
            } catch {
                metrics.recordError()
                Telemetry.summary.error("summarize failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
