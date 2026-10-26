import SwiftUI

struct ReaderView: View {
    let book: BookMeta
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @State private var content: BookContent?
    @State private var showChapters = false
    @State private var showPlayerPanel = false

    private var currentChapterSentences: [String] {
        guard let content = content,
              content.chapters.indices.contains(player.currentChapter) else { return [] }
        return content.chapters[player.currentChapter].sentences
    }

    var body: some View {
        VStack(spacing: 0) {
            if let content = content {
                chapterHeader(content)
                sentenceList
                playerBar(content)
            } else {
                ProgressView("正在解析 EPUB…")
                    .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadIfNeeded() }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showPlayerPanel) {
            PlayerPanel().environmentObject(player)
        }
        .sheet(isPresented: $showChapters) {
            if let content = content {
                NavigationView {
                    List(content.chapters) { chapter in
                        Button {
                            player.load(bookID: book.id, content: content,
                                        chapter: chapter.index, sentence: 0)
                            showChapters = false
                        } label: {
                            HStack {
                                Text(chapter.title)
                                    .foregroundColor(chapter.index == player.currentChapter ? .accentColor : .primary)
                                Spacer()
                                if chapter.index == player.currentChapter {
                                    Image(systemName: "speaker.wave.2.fill").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    .navigationTitle("目录")
                }
            }
        }
    }

    private func chapterHeader(_ content: BookContent) -> some View {
        HStack {
            Button { showChapters = true } label: {
                Label(content.chapters.indices.contains(player.currentChapter)
                        ? content.chapters[player.currentChapter].title : book.title,
                      systemImage: "list.bullet")
                    .lineLimit(1)
            }
            Spacer()
            if !player.statusText.isEmpty {
                Text(player.statusText).font(.caption).foregroundColor(.orange).lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var sentenceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(currentChapterSentences.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.system(size: 20, design: .serif))
                            .lineSpacing(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .background(
                                pair.offset == player.currentSentence && player.currentBookID == book.id
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear
                            )
                            .id(pair.offset)
                            .onTapGesture { player.jumpTo(sentence: pair.offset) }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .onChange(of: player.currentSentence) { target in
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func playerBar(_ content: BookContent) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 28) {
                Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                Button { player.previousSentence() } label: { Image(systemName: "backward.fill") }
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                Button { player.nextSentence() } label: { Image(systemName: "forward.fill") }
                Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
            }
            .font(.system(size: 20))
            Button { showPlayerPanel = true } label: {
                Label("听书", systemImage: "headphones")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(20)
            }
        }
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func loadIfNeeded() {
        if content == nil {
            content = library.loadContent(for: book)
        }
        if let content = content, player.currentBookID != book.id {
            player.load(bookID: book.id, content: content,
                        chapter: book.lastChapter, sentence: book.lastSentence)
        }
    }
}
