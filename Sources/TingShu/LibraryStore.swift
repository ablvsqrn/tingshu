import Foundation

final class LibraryStore: ObservableObject {
    @Published var books: [BookMeta] = []

    private let fm = FileManager.default
    private var libraryFile: URL {
        documentsDir.appendingPathComponent("library.json")
    }
    var documentsDir: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var booksDir: URL {
        let dir = documentsDir.appendingPathComponent("Books", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { load() }

    func epubURL(for book: BookMeta) -> URL { booksDir.appendingPathComponent(book.fileName) }
    func contentURL(for book: BookMeta) -> URL { booksDir.appendingPathComponent(book.id + ".json") }

    /// Import an EPUB picked by the user: copy it in, parse it, cache the text.
    func importBook(from pickedURL: URL) throws -> BookMeta {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let id = UUID().uuidString
        let fileName = id + ".epub"
        let dest = booksDir.appendingPathComponent(fileName)
        try fm.copyItem(at: pickedURL, to: dest)

        let content = try EPUBParser.parse(epubURL: dest)
        let contentData = try JSONEncoder().encode(content)
        try contentData.write(to: booksDir.appendingPathComponent(id + ".json"))

        let meta = BookMeta(id: id,
                            title: content.title,
                            author: content.author,
                            fileName: fileName,
                            addedAt: Date())
        // importBook is called from a background queue; @Published mutation
        // must land on the main thread.
        if Thread.isMainThread {
            books.insert(meta, at: 0)
            save()
        } else {
            DispatchQueue.main.sync {
                books.insert(meta, at: 0)
                save()
            }
        }
        return meta
    }

    func loadContent(for book: BookMeta) -> BookContent? {
        guard let data = try? Data(contentsOf: contentURL(for: book)) else { return nil }
        return try? JSONDecoder().decode(BookContent.self, from: data)
    }

    func delete(_ book: BookMeta) {
        try? fm.removeItem(at: epubURL(for: book))
        try? fm.removeItem(at: contentURL(for: book))
        books.removeAll { $0.id == book.id }
        save()
    }

    func updateProgress(bookID: String, chapter: Int, sentence: Int) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].lastChapter = chapter
        books[i].lastSentence = sentence
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode([BookMeta].self, from: data) else { return }
        books = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }
}
