import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerController
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importError: String?
    @State private var importing = false

    private var importTypes: [UTType] {
        var types: [UTType] = []
        types.append(UTType(importedAs: "org.idpf.epub-container"))
        types.append(UTType(importedAs: "org.openxmlformats.wordprocessingml.document"))
        for ext in ["epub", "docx"] {
            if let byExt = UTType(filenameExtension: ext) { types.append(byExt) }
        }
        types.append(.plainText)
        types.append(.pdf)
        types.append(.item)
        return types
    }

    private func importFrom(_ url: URL) {
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try library.importBook(from: url)
                DispatchQueue.main.async { importing = false }
            } catch {
                DispatchQueue.main.async {
                    importing = false
                    importError = error.localizedDescription
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                if importing {
                    HStack {
                        ProgressView()
                        Text("正在导入…").foregroundColor(.secondary)
                    }
                }
                if library.books.isEmpty && !importing {
                    Text("还没有书。支持 EPUB / TXT / PDF / Word(.docx)。三种导入方式：① 点右上角 + 选文件；② 在 Telegram 或「文件」App 里把书分享给「听书」；③ 把文件放进「文件 → 我的 iPhone → 听书」文件夹，重开 App 自动导入。")
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
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importFrom(url)
                } else {
                    importError = "没有拿到所选文件。请再试一次，或把 EPUB 放进「文件」App 的听书文件夹后重开 App 自动导入。"
                }
            case .failure(let error):
                importError = "选择文件失败：" + error.localizedDescription
            }
        }
        .onOpenURL { url in importFrom(url) }
        .alert(isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Alert(title: Text("导入失败"), message: Text(importError ?? ""),
                  dismissButton: .default(Text("好")))
        }
        .onAppear {
            player.onProgress = { [weak library] id, chapter, sentence in
                library?.updateProgress(bookID: id, chapter: chapter, sentence: sentence)
            }
            if let err = library.importLooseBooks(), importError == nil {
                importError = err
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("azureKey") var azureKey = ""
    @AppStorage("azureRegion") var azureRegion = "southeastasia"
    @AppStorage("voice") var voice = "zh-CN-XiaoxiaoNeural"
    @AppStorage("ratePercent") var ratePercent = 0
    @EnvironmentObject var player: PlayerController
    @Environment(\.presentationMode) var presentationMode
    @State private var cacheSize = ""

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
                Section(header: Text("语音缓存")) {
                    Text("已预合成缓存：\(cacheSize)")
                        .font(.caption).foregroundColor(.secondary)
                    Button("清除语音缓存", role: .destructive) {
                        player.clearAudioCache()
                        cacheSize = player.audioCacheSizeText()
                    }
                    Text("听书时会一直提前合成后面 20 句并存下来，下一句秒开、重听不花流量；缓存上限 200 MB，满了自动删最旧的。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .onAppear { cacheSize = player.audioCacheSizeText() }
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
