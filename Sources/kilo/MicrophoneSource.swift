import AVFoundation

enum MicrophoneError: Error {
    case permissionDenied
}

/// 麥克風音訊來源（AVAudioEngine input tap）。與 SystemAudioSource 並列的 AudioSource。
/// @unchecked Sendable：engine/continuation 由 start/stop 序列化管理。
final class MicrophoneSource: NSObject, AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<PCMBuffer>.Continuation?

    func start() async throws -> AsyncStream<PCMBuffer> {
        guard await Self.ensurePermission() else { throw MicrophoneError.permissionDenied }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let (stream, continuation) = AsyncStream<PCMBuffer>.makeStream()
        self.continuation = continuation

        // tap buffer 會被 reuse，跨 yield 到別的 task 前必須深拷貝
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            self?.continuation?.yield(PCMBuffer(pcm: copy))
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private static func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}

extension AVAudioPCMBuffer {
    /// 深拷貝為自有記憶體（tap buffer 跨 yield 不安全）。
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        }
        return copy
    }
}
