#if os(iOS)
import AVFoundation

@MainActor
final class KeepAliveAudio {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var sessionActive = false

    var isRunning: Bool { engine.isRunning }

    func start() -> Bool {
        guard !isRunning, let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return isRunning }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionActive = true
            let source = AVAudioSourceNode(format: format) { _, _, _, audioBuffers in
                for buffer in UnsafeMutableAudioBufferListPointer(audioBuffers) {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }
            engine.attach(source)
            node = source
            engine.connect(source, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            return true
        } catch {
            stop()
            return false
        }
    }

    func stop() {
        if let node {
            engine.stop()
            engine.detach(node)
            self.node = nil
        }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessionActive = false
        }
    }
}
#endif
