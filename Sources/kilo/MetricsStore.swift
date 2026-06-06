import Foundation

/// 即時可觀測指標（in-memory）。SummaryView footer 顯示。
@MainActor @Observable
final class MetricsStore {
    private(set) var segments = 0          // 已摘要段數
    private(set) var asrChars = 0          // 累積辨識字數
    private(set) var summaryCalls = 0
    private(set) var summaryErrors = 0
    private(set) var tokensIn = 0
    private(set) var tokensOut = 0
    private(set) var lastLatency: TimeInterval = 0  // 最近一次摘要往返秒數

    /// gpt-5.4-mini：$0.75 / 1M input、$4.50 / 1M output。
    var costUSD: Double { Double(tokensIn) / 1e6 * 0.75 + Double(tokensOut) / 1e6 * 4.5 }

    func recordFinal(chars: Int) { asrChars += chars }

    func recordSummary(tokensIn ti: Int, tokensOut to: Int, latency: TimeInterval) {
        segments += 1
        summaryCalls += 1
        tokensIn += ti
        tokensOut += to
        lastLatency = latency
    }

    func recordError() {
        summaryCalls += 1
        summaryErrors += 1
    }
}
