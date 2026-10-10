import AVFoundation

/// Lossless FLAC copy of a dictation, for the dev-only compression A/B test (see CLAUDE.md,
/// SilenceTrimmer section). Kept free of app types so a throwaway script can compile it alone
/// and prove the system encoder works. Returns nil on any failure — the caller logs and skips.
enum AudioCompression {
    static func flacData(pcm16: Data, sampleRate: Double) -> Data? {
        let frames = pcm16.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { src in
            _ = src.copyBytes(to: UnsafeMutableRawBufferPointer(start: dst, count: frames * 2))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozvena-ab-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            // Scoped so the file is closed (deinit finalizes the FLAC stream) before reading.
            try {
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatFLAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16
                ], commonFormat: .pcmFormatInt16, interleaved: true)
                try file.write(from: buffer)
            }()
            let data = try Data(contentsOf: url)
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}
