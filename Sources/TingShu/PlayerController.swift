import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

/// Sentence-by-sentence listening engine.
/// Flow per sentence: fetch MP3 from Azure Speech (prefetching the next one
/// while the current plays) -> AVAudioPlayer -> on finish, advance.
/// If Azure is unreachable or no key is set, falls back to the on-device
/// voice so a listening session never just dies.
final class PlayerController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentBookID: String?
    @Published var currentChapter = 0
    @Published var currentSentence = 0
    @Published var statusText = ""

    @AppStorage("azureKey") var azureKey = ""
    @AppStorage("azureRegion") var azureRegion = "southeastasia"
    @AppStorage("voice") var voice = "zh-CN-XiaoxiaoNeural"
    @AppStorage("ratePercent") var ratePercent = 0
    @AppStorage("sleepSetting") var sleepSetting = "off"

    private var sleepTimer: Timer?

    var onProgress: ((String, Int, Int) -> Void)?

    private var content: BookContent?
    var currentSentenceText: String {
        sentences.indices.contains(currentSentence) ? sentences[currentSentence] : ""
    }

    private var sentences: [String] = []
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var audioCache: [String: Data] = [:]
    private var generation = 0 // bumped on every stop/jump; stale fetches check it

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
        configureRemoteCommands()
    }

    // MARK: - Public control

    func load(bookID: String, content: BookContent, chapter: Int, sentence: Int) {
        stopInternal()
        self.content = content
        currentBookID = bookID
        setChapter(chapter, sentence: sentence)
    }

    func play() {
        guard content != nil else { return }
        if player != nil, player?.isPlaying == false, !isPlaying {
            player?.play()
            isPlaying = true
            startSleepTimerIfNeeded()
            return
        }
        speakCurrent()
        startSleepTimerIfNeeded()
    }

    func pause() {
        generation += 1
        sleepTimer?.invalidate()
        sleepTimer = nil
        player?.pause()
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        updateNowPlaying()
    }

    /// Call after voice or speed changes: re-speak the current sentence with
    /// the new settings (cache keys include voice+rate, but drop stale audio).
    func restartCurrentWithNewSettings() {
        audioCache.removeAll()
        if isPlaying { speakCurrent() }
        startSleepTimerIfNeeded()
    }

    func applySleepSetting() {
        // changed from the panel while playing or paused
        if isPlaying { startSleepTimerIfNeeded() }
    }

    private func startSleepTimerIfNeeded() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard isPlaying else { return }
        guard let minutes = Double(sleepSetting) else { return } // "off"/"chapter"
        sleepTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pause()
                self?.statusText = "定时到了，已暂停"
            }
        }
    }

    func stop() { stopInternal() }

    func nextSentence() {
        guard currentSentence + 1 < sentences.count else { nextChapter(); return }
        currentSentence += 1
        reportProgress()
        if isPlaying { speakCurrent() }
    }

    func previousSentence() {
        guard currentSentence > 0 else { return }
        currentSentence -= 1
        reportProgress()
        if isPlaying { speakCurrent() }
    }

    func nextChapter() {
        guard let content = content, currentChapter + 1 < content.chapters.count else {
            stopInternal(); return
        }
        setChapter(currentChapter + 1, sentence: 0)
        if isPlaying { speakCurrent() }
    }

    func previousChapter() {
        guard currentChapter > 0 else { return }
        setChapter(currentChapter - 1, sentence: 0)
        if isPlaying { speakCurrent() }
    }

    func jumpTo(sentence: Int) {
        currentSentence = max(0, min(sentence, sentences.count - 1))
        reportProgress()
        speakCurrent()
    }

    // MARK: - Internals

    private func setChapter(_ chapter: Int, sentence: Int) {
        guard let content = content, content.chapters.indices.contains(chapter) else { return }
        currentChapter = chapter
        sentences = content.chapters[chapter].sentences
        currentSentence = max(0, min(sentence, sentences.count - 1))
        audioCache.removeAll()
        reportProgress()
        updateNowPlaying()
    }

    private func reportProgress() {
        if let id = currentBookID { onProgress?(id, currentChapter, currentSentence) }
    }

    private func stopInternal() {
        generation += 1
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
    }

    private func speakCurrent() {
        guard sentences.indices.contains(currentSentence), let _ = content else { return }
        let myGeneration = generation + 1
        generation = myGeneration
        player?.stop()
        player = nil // so the system-voice fallback's didFinish can advance
        synthesizer.stopSpeaking(at: .immediate)

        let text = sentences[currentSentence]
        statusText = ""
        fetchAudio(for: text, announce: true) { [weak self] data in
            guard let self = self, self.generation == myGeneration else { return }
            DispatchQueue.main.async {
                if let data = data {
                    self.statusText = ""
                    self.playData(data, generation: myGeneration)
                } else {
                    self.speakWithSystemVoice(text)
                }
                self.isPlaying = true
                self.updateNowPlaying()
                self.prefetchNext()
            }
        }
        // Watchdog: a stalled fetch must never leave a tap unanswered. If no
        // audio has started for this generation within 8s, discard the late
        // result (generation bump) and read the sentence with the system voice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.generation == myGeneration,
                  self.player?.isPlaying != true, !self.synthesizer.isSpeaking else { return }
            self.generation += 1
            self.statusText = "网络合成超时，已切换到系统语音"
            self.speakWithSystemVoice(text)
            self.isPlaying = true
            self.updateNowPlaying()
        }
    }

    private func fetchAudio(for text: String, announce: Bool = false,
                            completion: @escaping (Data?) -> Void) {
        let key = voice + "|" + String(ratePercent) + "|" + text
        if let cached = audioCache[key] { completion(cached); return }
        if azureKey.trimmingCharacters(in: .whitespaces).isEmpty {
            if announce {
                DispatchQueue.main.async { [weak self] in
                    self?.statusText = "还没填 Azure 密钥（设置页填入），先用系统语音"
                }
            }
            completion(nil)
            return
        }
        if announce {
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "正在合成语音…"
            }
        }
        let client = AzureSpeechClient(region: azureRegion, apiKey: azureKey)
        client.synthesize(text: text, voice: voice, ratePercent: ratePercent) { [weak self] result in
            switch result {
            case .success(let data):
                self?.audioCache[key] = data
                completion(data)
            case .failure(let error):
                if announce {
                    DispatchQueue.main.async {
                        self?.statusText = "Azure 合成失败（\(error.localizedDescription)），先用系统语音"
                    }
                }
                completion(nil)
            }
        }
    }

    private func prefetchNext() {
        let next = currentSentence + 1
        guard sentences.indices.contains(next) else { return }
        fetchAudio(for: sentences[next]) { _ in }
    }

    private func playData(_ data: Data, generation gen: Int) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            p.play()
        } catch {
            if let text = sentences.indices.contains(currentSentence) ? sentences[currentSentence] : nil {
                speakWithSystemVoice(text)
            }
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        if statusText.isEmpty { statusText = "已切换到系统语音" }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48 + Float(ratePercent) / 200.0
        synthesizer.speak(utterance)
    }

    private func advanceAfterFinish() {
        if currentSentence + 1 < sentences.count {
            currentSentence += 1
            reportProgress()
            speakCurrent()
        } else if sleepSetting == "chapter" {
            isPlaying = false
            statusText = "本章播完，定时暂停"
            updateNowPlaying()
        } else if let content = content, currentChapter + 1 < content.chapters.count {
            setChapter(currentChapter + 1, sentence: 0)
            speakCurrent()
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    // MARK: - Audio session / lock screen

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* device will surface it; keep the app usable */ }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.nextSentence() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previousSentence() }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let content = content else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = content.title
        info[MPMediaItemPropertyArtist] = content.chapters.indices.contains(currentChapter)
            ? content.chapters[currentChapter].title : content.author
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension PlayerController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isPlaying else { return }
            self.advanceAfterFinish()
        }
    }
}

extension PlayerController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isPlaying, self.player == nil else { return }
            self.advanceAfterFinish()
        }
    }
}
