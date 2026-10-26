import AVFoundation
import CryptoKit
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

    // Pre-synthesis: a serial background queue keeps the next few sentences
    // synthesized ahead of playback and persists them to a disk cache, so
    // sentences start instantly and replays/reopens cost no network at all.
    private let prefetchQueue = DispatchQueue(label: "tingshu.prefetch", qos: .utility)
    private var prefetchToken = 0
    private let cacheLimitBytes = 500 * 1024 * 1024

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TTSAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".mp3"
        return cacheDir.appendingPathComponent(name)
    }

    func audioCacheSizeText() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total = 0
        for f in files {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        if total <= 0 { return "0 MB" }
        return String(format: "%.0f MB", Double(total) / 1_048_576.0)
    }

    func clearAudioCache() {
        audioCache.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func enforceCacheLimit() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var total = 0
        var sized: [(url: URL, size: Int, date: Date)] = []
        for f in files {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = v?.fileSize ?? 0
            total += size
            sized.append((f, size, v?.contentModificationDate ?? .distantPast))
        }
        guard total > cacheLimitBytes else { return }
        for item in sized.sorted(by: { $0.date < $1.date }) {
            if total <= cacheLimitBytes { break }
            try? fm.removeItem(at: item.url)
            total -= item.size
        }
    }

    /// Start pre-synthesizing from the current position without playing
    /// (called when the listening panel opens).
    func warmUp() { schedulePrefetch() }

    private func schedulePrefetch() {
        prefetchToken += 1
        let token = prefetchToken
        guard !azureKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var targets: [String] = []
        let start = currentSentence + 1
        if sentences.indices.contains(start) {
            for i in start..<min(start + 5, sentences.count) { targets.append(sentences[i]) }
        }
        if let content = content, content.chapters.indices.contains(currentChapter + 1) {
            let nextSentences = content.chapters[currentChapter + 1].sentences
            for i in 0..<min(3, nextSentences.count) { targets.append(nextSentences[i]) }
        }
        guard !targets.isEmpty else { return }
        let voiceC = voice, rateC = ratePercent, keyC = azureKey, regionC = azureRegion
        prefetchQueue.async { [weak self] in
            guard let self = self else { return }
            for text in targets {
                if self.prefetchToken != token { return }
                let key = voiceC + "|" + String(rateC) + "|" + text
                var inMemory = false
                DispatchQueue.main.sync { inMemory = self.audioCache[key] != nil }
                if inMemory { continue }
                let fileURL = self.cacheFileURL(for: key)
                if FileManager.default.fileExists(atPath: fileURL.path) { continue }
                let sem = DispatchSemaphore(value: 0)
                AzureSpeechClient(region: regionC, apiKey: keyC)
                    .synthesize(text: text, voice: voiceC, ratePercent: rateC) { result in
                        if case .success(let data) = result {
                            try? data.write(to: fileURL)
                            self.enforceCacheLimit()
                            DispatchQueue.main.async { self.audioCache[key] = data }
                        }
                        sem.signal()
                    }
                _ = sem.wait(timeout: .now() + 30)
            }
        }
    }

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
            schedulePrefetch()
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
                self.schedulePrefetch()
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
        if let disk = try? Data(contentsOf: cacheFileURL(for: key)), !disk.isEmpty {
            audioCache[key] = disk
            completion(disk)
            return
        }
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
                if let self = self {
                    let url = self.cacheFileURL(for: key)
                    self.prefetchQueue.async {
                        try? data.write(to: url)
                        self.enforceCacheLimit()
                    }
                }
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
