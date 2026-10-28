import Foundation
import PDFKit
import ZIPFoundation

/// Format dispatcher: every supported format produces the same BookContent
/// (chapters of plain text), so the player, pre-synthesis and cache never
/// need to know where a book came from.
enum BookParser {
    static func parse(url: URL) throws -> BookContent {
        switch url.pathExtension.lowercased() {
        case "epub":
            return try EPUBParser.parse(epubURL: url)
        case "txt":
            return try TXTBookParser.parse(url: url)
        case "pdf":
            return try PDFBookParser.parse(url: url)
        case "docx":
            return try DOCXBookParser.parse(url: url)
        default:
            throw err("不支持的格式 .\(url.pathExtension)（支持 EPUB / TXT / PDF / Word .docx）")
        }
    }

    static func err(_ message: String) -> NSError {
        NSError(domain: "BookParser", code: 40,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Split long plain text into chapter-sized chunks at line boundaries.
enum TextChunker {
    static func chunk(_ text: String, maxChars: Int = 6000) -> [String] {
        if text.count <= maxChars { return [text] }
        var chunks: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            current = ""
        }
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            // A single line longer than the cap (common in TXT dumps with no
            // line breaks) is hard-split by character count.
            while line.count > maxChars {
                flush()
                chunks.append(String(line.prefix(maxChars)))
                line = String(line.dropFirst(maxChars))
            }
            if current.count + line.count + 1 > maxChars { flush() }
            current += line + "\n"
        }
        flush()
        return chunks
    }
}

// MARK: - TXT

enum TXTBookParser {
    static func parse(url: URL) throws -> BookContent {
        let data = try Data(contentsOf: url)
        guard let decoded = decode(data) else {
            throw BookParser.err("这本 TXT 的编码识别不了（试过 UTF-8 / GBK / UTF-16）")
        }
        let text = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 50 else { throw BookParser.err("这本 TXT 几乎是空的") }

        let title = url.deletingPathExtension().lastPathComponent
        let lines = text.components(separatedBy: "\n")
        let headIndexes = lines.indices.filter { isChapterHeading(lines[$0]) }

        var chapters: [Chapter] = []
        if headIndexes.count >= 3 {
            // Text before the first heading becomes an opening chapter.
            let preface = lines[0..<headIndexes[0]].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if preface.count >= 100 {
                chapters.append(Chapter(index: 0, title: "开头", text: preface))
            }
            for (n, start) in headIndexes.enumerated() {
                let end = n + 1 < headIndexes.count ? headIndexes[n + 1] : lines.count
                let body = lines[(start + 1)..<end].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let headTitle = lines[start].trimmingCharacters(in: .whitespaces)
                if body.count < 10 {
                    chapters.append(Chapter(index: chapters.count, title: headTitle, text: headTitle))
                } else if body.count > 9000 {
                    for (k, part) in TextChunker.chunk(body, maxChars: 6000).enumerated() {
                        chapters.append(Chapter(index: chapters.count,
                                                title: k == 0 ? headTitle : headTitle + "（续）",
                                                text: part))
                    }
                } else {
                    chapters.append(Chapter(index: chapters.count, title: headTitle, text: body))
                }
            }
        } else {
            for part in TextChunker.chunk(text) {
                chapters.append(Chapter(index: chapters.count,
                                        title: "第 \(chapters.count + 1) 节", text: part))
            }
        }
        guard !chapters.isEmpty else { throw BookParser.err("这本 TXT 没提取到正文") }
        return BookContent(title: title, author: "", chapters: chapters)
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: "^\\s{0,4}(第\\s*[0-9零一二三四五六七八九十百千万两]+\\s*[章节回卷部篇集讲][^\\n]{0,30}|Chapter\\s+[0-9]+[^\\n]{0,30})$",
        options: [])

    private static func isChapterHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 42 else { return false }
        let range = NSRange(location: 0, length: (t as NSString).length)
        return headingRegex.firstMatch(in: t, range: range) != nil
    }

    /// Encoding ladder: BOM-marked UTF-16, then strict UTF-8, then GB18030
    /// (the usual encoding of older Chinese TXT files), then UTF-16.
    static func decode(_ data: Data) -> String? {
        if data.count >= 2 {
            let b0 = data[0], b1 = data[1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF),
               let s = String(data: data, encoding: .utf16) {
                return s
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb18030 = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(kCFStringEncodingGB_18030_2000)))
        if let s = String(data: data, encoding: gb18030) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return nil
    }
}

// MARK: - PDF (text layer only, via PDFKit)

enum PDFBookParser {
    static func parse(url: URL) throws -> BookContent {
        guard let doc = PDFDocument(url: url) else {
            throw BookParser.err("这本 PDF 打不开（可能已损坏或有密码保护）")
        }
        var chapters: [Chapter] = []
        var buffer = ""
        var startPage = 1
        func flush(until page: Int) {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 20 {
                chapters.append(Chapter(index: chapters.count,
                                        title: "第 \(startPage)–\(page) 页", text: t))
            }
            buffer = ""
        }
        for i in 0..<doc.pageCount {
            if buffer.isEmpty { startPage = i + 1 }
            buffer += (doc.page(at: i)?.string ?? "") + "\n"
            if buffer.count >= 6000 { flush(until: i + 1) }
        }
        flush(until: doc.pageCount)

        let totalChars = chapters.reduce(0) { $0 + $1.text.count }
        guard totalChars >= 100 else {
            throw BookParser.err("这本 PDF 抽不到文字，多半是扫描图片版——需要先 OCR 成 Word 再导入")
        }
        let attrs = doc.documentAttributes
        let title = (attrs?[PDFDocumentAttribute.titleAttribute] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let author = (attrs?[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
        return BookContent(title: title, author: author, chapters: chapters)
    }
}

// MARK: - Word .docx (ZIP + document.xml; tables flatten to reading order)

enum DOCXBookParser {
    static func parse(url: URL) throws -> BookContent {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("docx-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        do {
            try fm.unzipItem(at: url, to: workDir)
        } catch {
            throw BookParser.err("解压 Word 文件失败（.doc 老格式不支持，请另存为 .docx）")
        }
        let docURL = workDir.appendingPathComponent("word/document.xml")
        guard let data = try? Data(contentsOf: docURL),
              let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        else {
            throw BookParser.err("读不到 word/document.xml，可能不是 .docx 文件")
        }
        let delegate = DOCXDelegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        _ = parser.parse()
        let paragraphs = delegate.paragraphs
        guard !paragraphs.isEmpty else { throw BookParser.err("这份 Word 里没提取到文字") }

        // Chapter split at heading paragraphs; oversized chapters re-chunked.
        var segments: [(title: String, body: String)] = []
        var curTitle = "正文"
        var curBody: [String] = []
        var sawHeading = false
        func flush() {
            let body = curBody.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { segments.append((curTitle, body)) }
            curBody = []
        }
        for para in paragraphs {
            if para.isHeading {
                flush()
                curTitle = para.text
                sawHeading = true
            } else {
                curBody.append(para.text)
            }
        }
        flush()

        var chapters: [Chapter] = []
        if !sawHeading {
            let whole = paragraphs.map { $0.text }.joined(separator: "\n")
            for part in TextChunker.chunk(whole) {
                chapters.append(Chapter(index: chapters.count,
                                        title: "第 \(chapters.count + 1) 节", text: part))
            }
        } else {
            for seg in segments {
                if seg.body.count <= 9000 {
                    chapters.append(Chapter(index: chapters.count, title: seg.title, text: seg.body))
                } else {
                    for (k, part) in TextChunker.chunk(seg.body).enumerated() {
                        chapters.append(Chapter(index: chapters.count,
                                                title: k == 0 ? seg.title : seg.title + "（续）",
                                                text: part))
                    }
                }
            }
        }
        guard !chapters.isEmpty else { throw BookParser.err("这份 Word 里没提取到正文") }

        var title = url.deletingPathExtension().lastPathComponent
        let coreURL = workDir.appendingPathComponent("docProps/core.xml")
        if let core = try? String(contentsOf: coreURL, encoding: .utf8),
           let r = core.range(of: "<dc:title>([^<]+)</dc:title>", options: .regularExpression) {
            let t = String(core[r]).replacingOccurrences(of: "<[^>]+>", with: "",
                                                          options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { title = t }
        }
        return BookContent(title: title, author: "", chapters: chapters)
    }
}

private final class DOCXDelegate: NSObject, XMLParserDelegate {
    var paragraphs: [(text: String, isHeading: Bool)] = []
    private var current = ""
    private var inText = false
    private var paraOpen = false
    private var paraHeading = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if name.hasSuffix(":p") || name == "p" {
            paraOpen = true
            current = ""
            paraHeading = false
        } else if name.hasSuffix("pstyle") {
            let v = (attributeDict["w:val"] ?? attributeDict["val"] ?? "").lowercased()
            if v.contains("heading") || v.contains("标题") || v == "1" || v == "2" { paraHeading = true }
        } else if name.hasSuffix("outlinelvl") {
            let v = attributeDict["w:val"] ?? attributeDict["val"] ?? ""
            if v == "0" { paraHeading = true }
        } else if name.hasSuffix(":t") || name == "t" {
            inText = true
        } else if name.hasSuffix(":tab") {
            current += " "
        } else if name.hasSuffix(":br") || name.hasSuffix(":cr") {
            current += "\n"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name.hasSuffix(":t") || name == "t" { inText = false }
        if (name.hasSuffix(":p") || name == "p"), paraOpen {
            paraOpen = false
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { paragraphs.append((t, paraHeading)) }
        }
    }
}
