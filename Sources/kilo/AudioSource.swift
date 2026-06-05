import AVFoundation

/// 跨執行緒安全傳遞的 PCM buffer 包裝。
/// buffer 在 SystemAudioSource 已深拷貝為自有記憶體、單一 owner 傳遞，故 @unchecked Sendable 成立。
struct PCMBuffer: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
}

/// 音訊來源抽象。SystemAudioSource（系統音訊）/ MicrophoneSource（麥克風）並列。
/// Sendable：source 在 @MainActor 建、丟進背景 Task 餵 analyzer，需可跨 isolation。
protocol AudioSource: Sendable {
    /// 啟動擷取，回傳一串 PCM buffer 供呼叫端拉去轉錄。
    func start() async throws -> AsyncStream<PCMBuffer>
    /// 停止擷取並結束 stream。
    func stop() async
}
