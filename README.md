# 听书 TingShu — iOS 15 EPUB 听书 App（自研主线）

给 iPhone 11 / iOS 15.7 自用的 EPUB 听书 App：导入 EPUB → 按章按句朗读。
语音用**用户自己的 Azure Speech 资源**（aiyuyintts1，东南亚区，免费层）：
App 直连微软官方 REST 接口合成（晓晓/云扬等），不需要任何自建服务器；
合成失败或没填密钥时自动退回 iOS 系统语音。最低系统 iOS 15.0。

## 架构

- **App（Swift / SwiftUI，iOS 15）**：`Sources/TingShu/`
  - `EPUBParser`：解包 EPUB，解析 container/OPF/spine，把 XHTML 剥成纯文本
  - `AzureSpeechClient`：POST `https://{region}.tts.speech.microsoft.com/cognitiveservices/v1`，
    SSML 正文、`audio-24khz-96kbitrate-mono-mp3` 输出
  - `PlayerController`：逐句取音频 → AVAudioPlayer 播放 → 预取下一句；
    后台播放 + 锁屏控制（MPRemoteCommandCenter / NowPlaying）
  - **密钥只存在手机本地**（设置页填入，AppStorage 保存），不进代码、不进仓库
- **免费额度**：Azure Speech F0 神经语音 50 万字符/月 ≈ 30 小时听书
- `server/` 里是另一条支线的 Edge TTS 代理（给爱阅记 Legado 语音源用），
  本 App 不依赖它

## 构建（GitHub Actions，无签名 IPA + 巨魔）

1. 在 GitHub 新建一个**私有**仓库，把本目录全部内容传上去
2. Actions 页签手动运行 “Build unsigned IPA (TrollStore)”（或 push 到 main 自动触发）
3. 在运行记录的 Artifacts 里下载 `TingShu-unsigned.ipa`
4. 传到手机，用巨魔（TrollStore）安装 — 永久签名，不用续

本地有 Mac 时也可以：`brew install xcodegen && xcodegen generate`，
然后用 Xcode 打开 `TingShu.xcodeproj`。

## 部署 TTS 服务器（Oracle）

```bash
# 把 server/ 拷到 sg-free-01 后：
bash server/install-on-oracle.sh
curl http://127.0.0.1:8765/health          # 本机验证
# 手机开 Tailscale 后访问 http://100.70.147.99:8765/health 应返回 ok
```

上面这条服务器支线只给爱阅记的 Legado 语音源用；主线 App 不依赖它，语音直连 Azure，设置里只有密钥/区域/音色/语速，没有服务器地址。

## 已知取舍（第一版）

- 阅读排版是纯文本滚动（为听书服务），没有分页/字体排版引擎；
  以后可接 Readium Navigator 替换阅读视图，文本提取层不用动
- 阅读页的听书面板里改语速/音色会立即重读当前句；定时有关 15/30/60 分钟和本章结束两档
- Edge TTS 需要联网；整章离线预缓存是后续版本的事
