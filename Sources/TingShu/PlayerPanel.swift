import SwiftUI

/// The full listening panel, opened from the floating mini player's
/// settings (slider) button.
/// Deliberately minimal — model on iReadNote's player: transport controls,
/// the current sentence, then three choices: 读书人 (voice), 语速 (speed),
/// 定时关闭 (sleep timer). Changing voice/speed re-speaks the current
/// sentence with the new settings.
struct PlayerPanel: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.presentationMode) var presentationMode
    @State private var keyInput = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(spacing: 14) {
                        if !player.currentSentenceText.isEmpty {
                            Text(player.currentSentenceText)
                                .font(.system(size: 17))
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 34) {
                            Button { player.previousSentence() } label: {
                                Image(systemName: "backward.fill")
                            }
                            Button {
                                player.isPlaying ? player.pause() : player.play()
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 52))
                            }
                            Button { player.nextSentence() } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .font(.system(size: 22))
                        .frame(maxWidth: .infinity)
                        if !player.statusText.isEmpty {
                            Text(player.statusText)
                                .font(.caption).foregroundColor(.orange)
                        }
                        if player.azureKey.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(spacing: 8) {
                                Text("粘贴你的 Azure 密钥，就能用微软音色（不填则用系统语音）")
                                    .font(.caption).foregroundColor(.secondary)
                                HStack {
                                    TextField("粘贴密钥", text: $keyInput)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                        .textFieldStyle(.roundedBorder)
                                    Button("保存") {
                                        player.azureKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                        keyInput = ""
                                        if player.isPlaying { player.restartCurrentWithNewSettings() }
                                    }
                                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text("读书人")) {
                    ForEach(chineseVoices, id: \.name) { v in
                        Button {
                            player.voice = v.name
                            player.restartCurrentWithNewSettings()
                        } label: {
                            HStack {
                                Text(v.label).foregroundColor(.primary)
                                Spacer()
                                if player.voice == v.name {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("语速")) {
                    Picker("语速", selection: Binding(
                        get: { player.ratePercent },
                        set: { player.ratePercent = $0; player.restartCurrentWithNewSettings() }
                    )) {
                        ForEach(speedOptions, id: \.ratePercent) { s in
                            Text(s.label).tag(s.ratePercent)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("定时关闭")) {
                    Picker("定时关闭", selection: Binding(
                        get: { player.sleepSetting },
                        set: { player.sleepSetting = $0; player.applySleepSetting() }
                    )) {
                        ForEach(sleepOptions, id: \.value) { s in
                            Text(s.label).tag(s.value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        Button("上一章") { player.previousChapter() }
                        Spacer()
                        Button("下一章") { player.nextChapter() }
                    }
                }
            }
            .navigationTitle("听书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}
