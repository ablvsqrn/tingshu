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
    private var interruptedWhilePlaying = false // set when another app steals the audio session mid-playback
    private var sessionObservers: [NSObjectProtocol] = []

    // Pre-synthesis: a serial background queue keeps the next few sentences
    // synthesized ahead of playback and persists them to a disk cache, so
    // sentences start instantly and replays/reopens cost no network at all.
    private let prefetchQueue = DispatchQueue(label: "tingshu.prefetch", qos: .utility)
    private var prefetchToken = 0
    private let cacheLimitBytes = 200 * 1024 * 1024

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
        // Keep the next 20 sentences synthesized ahead, across chapter
        // boundaries; called again at every sentence so the window rolls
        // forward with playback for as long as there is network.
        var targets: [String] = []
        if let content = content {
            var chapter = currentChapter
            var idx = currentSentence + 1
            while targets.count < 20, content.chapters.indices.contains(chapter) {
                let sents = content.chapters[chapter].sentences
                while idx < sents.count, targets.count < 20 {
                    targets.append(sents[idx])
                    idx += 1
                }
                chapter += 1
                idx = 0
            }
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
        observeAudioSessionNotifications()
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
        configureAudioSession() // another app may have deactivated it while we were away
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
            // One recovery attempt before the system voice: if a player is
            // loaded but silent, the session was probably deactivated by an
            // interruption — re-activate and retry instead of swapping voice.
            self.configureAudioSession()
            if let p = self.player, p.play() { return }
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
            // The session is only guaranteed active right after we activate
            // it: another app (call, video, voice message) can deactivate it
            // while we are backgrounded, and AVAudioPlayer then fails
            // silently — no sound, no delegate error, playback just stalls.
            configureAudioSession()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            player = p
            if !p.play() {
                configureAudioSession() // one re-activation retry before any fallback
                if !p.play(), let text = sentences.indices.contains(currentSentence)
                    ? sentences[currentSentence] : nil {
                    speakWithSystemVoice(text)
                }
            }
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

    // MARK: - Interruptions & foreground recovery

    /// Cutting to another app and back used to kill playback: an app that
    /// plays audio (call, video, voice message) interrupts and deactivates
    /// our session; AVAudioPlayer then stops silently, its finish delegate
    /// never fires, and nothing ever resumed — the user came back to a
    /// stalled player that then tripped the 8s watchdog into swapping to
    /// the system voice. These handlers close that hole.
    private func observeAudioSessionNotifications() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        sessionObservers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleMediaServicesReset() })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPlaying { interruptedWhilePlaying = true }
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            if interruptedWhilePlaying, shouldResume {
                interruptedWhilePlaying = false
                resumeAfterInterruption()
            }
            // Without shouldResume, recovery happens on foreground via
            // appBecameActive() when the user returns to the app.
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // Media server restarted: session config and remote-command targets
        // were wiped. Rebuild them, and resume if we were mid-listen.
        let wasPlaying = isPlaying || interruptedWhilePlaying
        interruptedWhilePlaying = false
        configureAudioSession()
        configureRemoteCommands()
        if wasPlaying { resumeAfterInterruption() }
    }

    /// Re-activate the session and keep the current sentence going: resume
    /// the loaded player when possible, otherwise re-speak — the disk cache
    /// makes the chosen Azure voice come back instantly, no system voice.
    private func resumeAfterInterruption() {
        guard isPlaying, content != nil else { return }
        configureAudioSession()
        if let p = player, !p.isPlaying, p.play() {
            updateNowPlaying()
            return
        }
        if synthesizer.isSpeaking { return }
        player = nil
        speakCurrent()
    }

    /// Called when the app returns to the foreground. If state says
    /// "playing" but nothing is actually making sound, recover here
    /// instead of sitting silent until the watchdog swaps the voice.
    func appBecameActive() {
        guard isPlaying, content != nil else { return }
        if player?.isPlaying == true || synthesizer.isSpeaking { return }
        resumeAfterInterruption()
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
