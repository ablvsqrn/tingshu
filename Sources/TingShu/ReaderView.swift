import SwiftUI

struct ReaderView: View {
    let book: BookMeta
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @State private var content: BookContent?
    @State private var showChapters = false
    @State private var showPlayerPanel = false
    @State private var showMiniPlayer = false

    private var currentChapterSentences: [String] {
        guard let content = content,
              content.chapters.indices.contains(player.currentChapter) else { return [] }
        return content.chapters[player.currentChapter].sentences
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if let content = content {
                    chapterHeader(content)
                    sentenceList
                } else {
                    ProgressView("正在解析 EPUB…")
                        .padding()
                }
            }
            if content != nil {
                floatingControls
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
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
                            .contentShape(Rectangle())
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
            .onAppear {
                // Land on the sentence being read, not the top of the chapter.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if player.currentBookID == book.id {
                        proxy.scrollTo(player.currentSentence, anchor: .center)
                    }
                }
            }
            .onChange(of: showPlayerPanel) { _ in
                // Tapping 听书 re-centers the text on the spoken sentence.
                withAnimation { proxy.scrollTo(player.currentSentence, anchor: .center) }
            }
        }
    }

    /// Readest-style floating listening control: a small round button at the
    /// bottom-trailing corner. Tapping it starts playback and expands it into
    /// a floating capsule with transport controls; the slider button opens the
    /// full 听书 panel (voice / speed / sleep timer / Azure key).
    @ViewBuilder
    private var floatingControls: some View {
        if showMiniPlayer {
            HStack(spacing: 18) {
                Button { player.previousSentence() } label: {
                    Image(systemName: "backward.fill")
                }
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 25))
                }
                Button { player.nextSentence() } label: {
                    Image(systemName: "forward.fill")
                }
                Divider().frame(height: 22)
                Button { showPlayerPanel = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showMiniPlayer = false }
                } label: {
                    Image(systemName: "chevron.down")
                }
            }
            .font(.system(size: 18))
            .foregroundColor(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
            )
            .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showMiniPlayer = true }
                if !player.isPlaying { player.play() }
            } label: {
                Image(systemName: player.isPlaying ? "waveform" : "headphones")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
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
