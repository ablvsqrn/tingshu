import Foundation

/// Direct client for the user's own Azure Speech resource (official REST API).
///
/// POST https://{region}.tts.speech.microsoft.com/cognitiveservices/v1
/// Headers: Ocp-Apim-Subscription-Key, Content-Type: application/ssml+xml,
///          X-Microsoft-OutputFormat: audio-24khz-96kbitrate-mono-mp3
/// Body: SSML with the chosen voice and prosody rate.
///
/// The subscription key comes from the app's Settings screen and lives only
/// on the device. It is never in source code or the git repo.
final class AzureSpeechClient {
    let region: String
    let apiKey: String

    init(region: String, apiKey: String) {
        self.region = region.trimmingCharacters(in: .whitespaces).isEmpty
            ? "southeastasia" : region.trimmingCharacters(in: .whitespaces)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
    }

    enum ClientError: Error { case noKey, badURL, http(Int), empty }

    func synthesize(text: String, voice: String, ratePercent: Int,
                    completion: @escaping (Result<Data, Error>) -> Void) {
        guard !apiKey.isEmpty else { completion(.failure(ClientError.noKey)); return }
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            completion(.failure(ClientError.badURL)); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-96kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("TingShu/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let rate = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let lang = voice.hasPrefix("zh-TW") ? "zh-TW" : (voice.hasPrefix("zh-HK") ? "zh-HK" : "zh-CN")
        let ssml = "<speak version='1.0' xml:lang='\(lang)'>"
            + "<voice name='\(voice)'>"
            + "<prosody rate='\(rate)'>\(Self.escapeXML(text))</prosody>"
            + "</voice></speak>"
        request.httpBody = Data(ssml.utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(ClientError.http(http.statusCode))); return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(ClientError.empty)); return
            }
            completion(.success(data))
        }.resume()
    }

    static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
