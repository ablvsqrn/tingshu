import Foundation
import ZIPFoundation

/// Minimal EPUB parser for listening: unzip, read container.xml -> OPF,
/// walk the spine in reading order, strip each XHTML to plain text.
/// Deliberately NOT a rendering engine — typography stays simple while the
/// TTS pipeline is the product. (Readium Navigator can replace the reader
/// view later without touching this text-extraction contract.)
enum EPUBParser {
    static func parse(epubURL: URL) throws -> BookContent {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("epub-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        do {
            try fm.unzipItem(at: epubURL, to: workDir)
        } catch {
            throw NSError(domain: "EPUBParser", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "解压 EPUB 失败：\(error.localizedDescription)"])
        }

        // 1. container.xml -> OPF path
        let containerURL = workDir.appendingPathComponent("META-INF/container.xml")
        guard let containerXML = try? String(contentsOf: containerURL, encoding: .utf8) else {
            throw NSError(domain: "EPUBParser", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "读不到 META-INF/container.xml，可能不是标准 EPUB（或是加密/DRM 书）"])
        }
        guard let opfRelative = ContainerParser(opfPathIn: containerXML) else {
            throw NSError(domain: "EPUBParser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "container.xml 里找不到 OPF"])
        }
        let opfURL = workDir.appendingPathComponent(opfRelative)
        let opfDir = opfURL.deletingLastPathComponent()
        guard let opfXML = try? String(contentsOf: opfURL, encoding: .utf8) else {
            throw NSError(domain: "EPUBParser", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "读不到 OPF 文件：\(opfRelative)"])
        }
        let opf = OPFParser(xml: opfXML)

        // 2. optional NCX toc for nicer chapter titles
        var tocTitles: [String: String] = [:] // normalized content path -> label
        if let ncxHref = opf.manifest.first(where: { $0.mediaType.contains("ncx") })?.href {
            let ncxURL = opfDir.appendingPathComponent(ncxHref)
            if let ncxXML = try? String(contentsOf: ncxURL, encoding: .utf8) {
                tocTitles = NCXParser(xml: ncxXML, ncxDirRelative: opfRelative)
            }
        }

        // 3. spine -> chapters
        var chapters: [Chapter] = []
        for idref in opf.spine {
            guard let item = opf.manifest.first(where: { $0.id == idref }),
                  item.mediaType.contains("html") else { continue }
            let fileURL = opfDir.appendingPathComponent(item.href)
            guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let text = HTMLText.strip(html)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2 { continue }
            let key = normalizePath((opfDirRelative(workDir: workDir, file: fileURL)))
            let title = tocTitles[key]
                ?? firstHeading(in: html)
                ?? "第 \(chapters.count + 1) 节"
            chapters.append(Chapter(index: chapters.count, title: title, text: trimmed))
        }
        guard !chapters.isEmpty else {
            throw NSError(domain: "EPUBParser", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "这本 EPUB 没提取到正文"])
        }
        return BookContent(title: opf.title.isEmpty ? epubURL.deletingPathExtension().lastPathComponent : opf.title,
                           author: opf.creator,
                           chapters: chapters)
    }

    private static func opfDirRelative(workDir: URL, file: URL) -> String {
        let base = workDir.path + "/"
        return file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : file.path
    }

    private static func normalizePath(_ path: String) -> String {
        // strip #fragment, decode %XX, collapse ./ and ../ segments roughly
        var p = path.components(separatedBy: "#").first ?? path
        p = p.removingPercentEncoding ?? p
        var parts: [String] = []
        for seg in p.split(separator: "/") {
            if seg == "." { continue }
            if seg == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(seg))
        }
        return parts.joined(separator: "/")
    }

    private static func firstHeading(in html: String) -> String? {
        for tag in ["h1", "h2", "h3", "title"] {
            if let r = html.range(of: "<\(tag)[^>]*>(.*?)</\(tag)>",
                                  options: [.regularExpression, .caseInsensitive]) {
                let inner = String(html[r])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return HTMLText.decodeEntities(inner) }
            }
        }
        return nil
    }
}

enum HTMLText {
    static func strip(_ html: String) -> String {
        var s = html
        // drop script/style/head wholesale
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                                       with: "", options: [.regularExpression, .caseInsensitive])
        }
        // block boundaries -> newline
        s = s.replacingOccurrences(of: "<\\s*(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        // all remaining tags -> nothing
        s = s.replacingOccurrences(of: "<[^>]+>", with: "",
                                   options: .regularExpression)
        s = decodeEntities(s)
        // collapse 3+ newlines / long space runs
        s = s.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n",
                                   options: .regularExpression)
        return s
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&ldquo;": "“", "&rdquo;": "”",
            "&lsquo;": "‘", "&rsquo;": "’", "&mdash;": "—", "&hellip;": "…",
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // numeric entities &#123; / &#x4E2D;
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|\\d+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let body = ns.substring(with: m.range(at: 1))
                let value: Int? = body.hasPrefix("x") || body.hasPrefix("X")
                    ? Int(body.dropFirst(), radix: 16) : Int(body)
                if let v = value, let scalar = Unicode.Scalar(v) {
                    result += String(Character(scalar))
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }
}

// MARK: - Tiny XMLParser helpers

private final class ContainerDelegate: NSObject, XMLParserDelegate {
    var rootfilePath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName.lowercased().hasSuffix("rootfile") {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

private func ContainerParser(opfPathIn xml: String) -> String? {
    let delegate = ContainerDelegate()
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.rootfilePath
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var creator = ""
    var manifest: [(id: String, href: String, mediaType: String)] = []
    var spine: [String] = []
    private var currentElement = ""
    private var buffer = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        buffer = ""
        if currentElement.hasSuffix("item") {
            manifest.append((id: attributeDict["id"] ?? "",
                             href: (attributeDict["href"] ?? "").removingPercentEncoding ?? (attributeDict["href"] ?? ""),
                             mediaType: attributeDict["media-type"] ?? ""))
        } else if currentElement.hasSuffix("itemref") {
            if let idref = attributeDict["idref"] { spine.append(idref) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name.hasSuffix("title") && title.isEmpty { title = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name.hasSuffix("creator") && creator.isEmpty { creator = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        buffer = ""
    }
}

private func OPFParser(xml: String) -> OPFDelegate {
    let delegate = OPFDelegate()
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    _ = parser.parse()
    return delegate
}

private final class NCXDelegate: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]
    private var inLabel = false
    private var labelText = ""
    private var pendingSrc = ""
    private var lastLabel = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if name.hasSuffix("text") { inLabel = true; labelText = "" }
        if name.hasSuffix("content"), let src = attributeDict["src"] {
            pendingSrc = src
            if !lastLabel.isEmpty { map[pendingSrc] = lastLabel }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLabel { labelText += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased().hasSuffix("text") && inLabel {
            inLabel = false
            lastLabel = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private func NCXParser(xml: String, ncxDirRelative: String) -> [String: String] {
    let delegate = NCXDelegate()
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    _ = parser.parse()
    // NCX src values are relative to the NCX file's folder; the caller keys
    // chapters by path relative to the EPUB root. NCX usually sits next to
    // the OPF, so a raw src is close enough for title lookup in practice;
    // strip fragments for matching.
    var out: [String: String] = [:]
    for (k, v) in delegate.map {
        out[k.components(separatedBy: "#").first ?? k] = v
    }
    return out
}
