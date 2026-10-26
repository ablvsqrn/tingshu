import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importError: String?

    var body: some View {
        NavigationView {
            List {
                if library.books.isEmpty {
                    Text("还没有书。点右上角 + 导入一本 EPUB 开始听书。")
                        .foregroundColor(.secondary)
                }
                ForEach(library.books) { book in
                    NavigationLink(destination: ReaderView(book: book)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.headline)
                            if !book.author.isEmpty {
                                Text(book.author).font(.subheadline).foregroundColor(.secondary)
                            }
                            Text("上次听到：第 \(book.lastChapter + 1) 章")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { library.delete(library.books[i]) }
                }
            }
            .navigationTitle("听书")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType(importedAs: "org.idpf.epub-container"), .item],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            _ = try library.importBook(from: url)
                        } catch {
                            DispatchQueue.main.async { importError = error.localizedDescription }
                        }
                    }
                }
            }
            .alert(item: Binding(
                get: { importError.map { ImportError(message: $0) } },
                set: { importError = $0?.message }
            )) { item in
                Alert(title: Text("导入失败"), message: Text(item.message),
                      dismissButton: .default(Text("好")))
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            player.onProgress = { [weak library] id, chapter, sentence in
                library?.updateProgress(bookID: id, chapter: chapter, sentence: sentence)
            }
        }
    }
}

private struct ImportError: Identifiable {
    let id = UUID()
    let message: String
}

struct SettingsView: View {
    @AppStorage("azureKey") var azureKey = ""
    @AppStorage("azureRegion") var azureRegion = "southeastasia"
    @AppStorage("voice") var voice = "zh-CN-XiaoxiaoNeural"
    @AppStorage("ratePercent") var ratePercent = 0
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Azure 语音（你的资源 aiyuyintts1）")) {
                    TextField("粘贴密钥到这里", text: $azureKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("就填这一个框。区域已按你的资源固定为东南亚，不用管。密钥只存在这台手机上，只发给微软官方接口，不进代码、不进 GitHub。没填时用系统语音。免费层每月 50 万字符，约 30 小时听书。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("微软音色")) {
                    Picker("音色", selection: $voice) {
                        ForEach(chineseVoices, id: \.name) { v in
                            Text(v.label).tag(v.name)
                        }
                    }
                }
                Section(header: Text("语速")) {
                    Stepper(value: $ratePercent, in: -50...100, step: 10) {
                        Text(ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%")
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
