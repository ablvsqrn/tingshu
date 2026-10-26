import Foundation

struct BookMeta: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var fileName: String
    var addedAt: Date
    var lastChapter: Int = 0
    var lastSentence: Int = 0
}

struct Chapter: Codable, Identifiable {
    var id: Int { index }
    var index: Int
    var title: String
    var text: String

    var sentences: [String] { SentenceSplitter.split(text) }
}

struct BookContent: Codable {
    var title: String
    var author: String
    var chapters: [Chapter]
}

enum SentenceSplitter {
    /// Split chapter text into speakable sentences.
    /// Keeps terminators attached, merges tiny fragments, caps length so a
    /// single TTS request never becomes a multi-minute utterance.
    static func split(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";"]
        let closers: Set<Character> = ["」", "』", "”", "’", "\"", "'", "）", ")"]
        var raw: [String] = []
        var current = ""
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {
            for ch in paragraph {
                current.append(ch)
                if terminators.contains(ch) || current.count >= 150 {
                    // absorb trailing closing quotes/brackets into this sentence
                    raw.append(current)
                    current = ""
                } else if closers.contains(ch) && !current.isEmpty && raw.isEmpty == false && current.count <= 2 {
                    raw[raw.count - 1] += current
                    current = ""
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                raw.append(current)
            }
            current = ""
        }
        // merge fragments that are too short to be a sentence on their own
        var merged: [String] = []
        for s in raw {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.count < 8, let last = merged.last, last.count + t.count <= 160 {
                merged[merged.count - 1] = last + t
            } else {
                merged.append(t)
            }
        }
        return merged
    }
}

/// Speed choices shown in the listening panel: label + Azure prosody rate %.
let speedOptions: [(label: String, ratePercent: Int)] = [
    ("0.75x", -25),
    ("1.0x", 0),
    ("1.25x", 25),
    ("1.5x", 50),
    ("2.0x", 100),
]

/// Sleep timer choices: stored value + label. "chapter" stops at chapter end.
let sleepOptions: [(value: String, label: String)] = [
    ("off", "不定时"),
    ("15", "15 分钟"),
    ("30", "30 分钟"),
    ("60", "60 分钟"),
    ("chapter", "本章结束"),
]

/// Chinese voices offered in the UI (Azure Speech short names).
let chineseVoices: [(name: String, label: String)] = [
    ("zh-CN-XiaoxiaoNeural", "晓晓（女，温暖）"),
    ("zh-CN-XiaoyiNeural", "晓伊（女）"),
    ("zh-CN-YunyangNeural", "云扬（男，播音）"),
    ("zh-CN-YunjianNeural", "云健（男，浑厚）"),
    ("zh-CN-YunxiNeural", "云希（男，年轻）"),
    ("zh-CN-YunxiaNeural", "云夏（男，少年）"),
    ("zh-CN-liaoning-XiaobeiNeural", "晓北（女，东北）"),
    ("zh-CN-shaanxi-XiaoniNeural", "晓妮（女，陕西）"),
    ("zh-TW-HsiaoChenNeural", "晓臻（女，台湾）"),
    ("zh-HK-HiuMaanNeural", "晓曼（女，粤语）"),
]
