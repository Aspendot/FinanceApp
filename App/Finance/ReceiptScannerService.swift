import FinanceCore
import Foundation
import Security
import UIKit
import Vision

/// Persisted user configuration for the AI Vision + On-Device Apple Vision receipt scanner.
struct VisionScannerConfig: Codable, Equatable, Sendable {
    var provider: VisionProvider = .anthropic
    var model: String = VisionProvider.anthropic.defaultModel
    /// Optional custom endpoint URL for OpenAI-compatible gateways.
    var customEndpoint: String = ""
    var preferAIVision: Bool = true
    var defaultSource: String = "Cash"

    static let `default` = VisionScannerConfig()
}

/// Keychain storage for user-supplied AI Vision API keys (`AfterFirstUnlockThisDeviceOnly`).
enum VisionKeyStore {
    private static let service = "FinanceApp.VisionAPIKey"

    static func loadKey(for provider: VisionProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveKey(_ key: String, for provider: VisionProvider) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            clearKey(for: provider)
            return
        }
        let data = Data(clean.utf8)
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            addQuery.removeValue(forKey: kSecValueData as String)
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(addQuery as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw ReceiptScannerError.keychainFailure(updateStatus)
            }
            return
        }
        throw ReceiptScannerError.keychainFailure(addStatus)
    }

    static func clearKey(for provider: VisionProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasKey(for provider: VisionProvider) -> Bool {
        loadKey(for: provider) != nil
    }
}

/// Atomic file storage for `VisionScannerConfig`.
enum VisionScannerStore {
    private static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinanceData", isDirectory: true)
            .appendingPathComponent("vision-scanner-config.json")
    }

    static func load() -> VisionScannerConfig {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(VisionScannerConfig.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ config: VisionScannerConfig) {
        var folder = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var vals = URLResourceValues()
        vals.isExcludedFromBackup = true
        try? folder.setResourceValues(vals)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

enum ReceiptScannerError: Error, LocalizedError {
    case imageEncodingFailed
    case missingAPIKey(VisionProvider)
    case invalidEndpoint
    case httpError(Int, String)
    case unreadableResponse
    case noItemsFound
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Could not prepare the image for scanning."
        case .missingAPIKey(let provider):
            return "Add a \(provider.displayName) API key in More → Receipt scanner."
        case .invalidEndpoint:
            return "The API endpoint URL is not valid."
        case .httpError(let status, let detail):
            return detail.isEmpty ? "Vision API returned HTTP \(status)." : "Vision API (HTTP \(status)): \(detail)"
        case .unreadableResponse:
            return "Could not read structured receipt data from the model response."
        case .noItemsFound:
            return "No receipt totals or payment rows were recognized in this image."
        case .keychainFailure(let status):
            return "Could not save API key to Keychain (code \(status))."
        }
    }
}

/// High-accuracy AI Vision (Claude / Gemini / OpenAI-compatible) + offline Apple Vision OCR receipt scanner.
enum ReceiptScannerService {
    struct ScanResult: Sendable {
        let drafts: [ReceiptDraft]
        let engineLabel: String
        let fallbackNote: String?
    }

    /// Downscales and re-renders into a fresh bitmap so 100% of EXIF/GPS metadata is stripped before upload.
    static func sanitizeAndEncodeJPEG(_ image: UIImage, maxDimension: CGFloat = 1400, quality: CGFloat = 0.82) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? (maxDimension / longest) : 1.0
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let redrawn = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return redrawn.jpegData(compressionQuality: quality)
    }

    /// Scans a receipt, payment slip, or multi-row history screenshot using AI Vision when configured,
    /// falling back automatically to on-device Apple Vision OCR (`ja-JP` + `en-US`).
    static func scan(
        image: UIImage,
        defaultSource: String,
        today: String,
        availableCategories: [(group: String, category: String)],
        rules: RuleSet,
        existingItems: [BudgetItem]
    ) async throws -> ScanResult {
        guard let jpegData = sanitizeAndEncodeJPEG(image) else {
            throw ReceiptScannerError.imageEncodingFailed
        }
        let categorizer = Categorizer(rules: rules)
        let config = VisionScannerStore.load()

        if config.preferAIVision, let apiKey = VisionKeyStore.loadKey(for: config.provider) {
            do {
                let prompt = ReceiptExtraction.systemPrompt(categories: availableCategories, today: today)
                let rawText = try await callVisionAPI(
                    config: config,
                    apiKey: apiKey,
                    prompt: prompt,
                    jpegData: jpegData
                )
                let drafts = ReceiptExtraction.parseAIResponse(
                    rawText,
                    today: today,
                    defaultSource: defaultSource,
                    availableCategories: availableCategories,
                    categorizer: categorizer,
                    existingItems: existingItems
                )
                if !drafts.isEmpty {
                    let modelLabel = config.model.isEmpty ? config.provider.defaultModel : config.model
                    return ScanResult(drafts: drafts, engineLabel: "\(config.provider.displayName) · \(modelLabel)", fallbackNote: nil)
                }
                // Try offline OCR if AI returned no items.
                let fallback = try await runAppleVisionOCR(
                    jpegData: jpegData,
                    today: today,
                    defaultSource: defaultSource,
                    availableCategories: availableCategories,
                    categorizer: categorizer,
                    existingItems: existingItems
                )
                return ScanResult(
                    drafts: fallback,
                    engineLabel: "Apple Vision (on-device)",
                    fallbackNote: "AI returned no structured rows; fell back to on-device OCR."
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Network or quota error -> fall back cleanly to offline Apple Vision OCR.
                if let fallback = try? await runAppleVisionOCR(
                    jpegData: jpegData,
                    today: today,
                    defaultSource: defaultSource,
                    availableCategories: availableCategories,
                    categorizer: categorizer,
                    existingItems: existingItems
                ), !fallback.isEmpty {
                    return ScanResult(
                        drafts: fallback,
                        engineLabel: "Apple Vision (offline fallback)",
                        fallbackNote: error.localizedDescription
                    )
                }
                throw error
            }
        }

        let offline = try await runAppleVisionOCR(
            jpegData: jpegData,
            today: today,
            defaultSource: defaultSource,
            availableCategories: availableCategories,
            categorizer: categorizer,
            existingItems: existingItems
        )
        return ScanResult(
            drafts: offline,
            engineLabel: "Apple Vision (on-device)",
            fallbackNote: config.preferAIVision ? "Add an AI Vision API key in More for higher Japanese receipt accuracy." : nil
        )
    }

    // MARK: - On-Device Apple Vision OCR

    private static func runAppleVisionOCR(
        jpegData: Data,
        today: String,
        defaultSource: String,
        availableCategories: [(group: String, category: String)],
        categorizer: Categorizer,
        existingItems: [BudgetItem]
    ) async throws -> [ReceiptDraft] {
        let lines = try await Task.detached(priority: .userInitiated) { () throws -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ja-JP", "en-US"]
            let handler = VNImageRequestHandler(data: jpegData, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }
        }.value

        let drafts = ReceiptExtraction.parseOfflineOCR(
            lines: lines,
            today: today,
            defaultSource: defaultSource,
            availableCategories: availableCategories,
            categorizer: categorizer,
            existingItems: existingItems
        )
        if drafts.isEmpty {
            throw ReceiptScannerError.noItemsFound
        }
        return drafts
    }

    // MARK: - AI Vision HTTPS Requests (Anthropic / Gemini / OpenAI-Compatible)

    private static func callVisionAPI(
        config: VisionScannerConfig,
        apiKey: String,
        prompt: String,
        jpegData: Data
    ) async throws -> String {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.provider.defaultModel
            : config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let b64 = jpegData.base64EncodedString()

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 35
        sessionConfig.timeoutIntervalForResource = 45
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        switch config.provider {
        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                throw ReceiptScannerError.invalidEndpoint
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1200,
                "temperature": 0,
                "messages": [[
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": b64,
                            ],
                        ],
                        [
                            "type": "text",
                            "text": prompt,
                        ],
                    ],
                ]],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try validateHTTP(response: response, data: data)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]]
            else { throw ReceiptScannerError.unreadableResponse }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.isEmpty else { throw ReceiptScannerError.unreadableResponse }
            return text

        case .gemini:
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
                throw ReceiptScannerError.invalidEndpoint
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let body: [String: Any] = [
                "contents": [[
                    "parts": [
                        ["text": prompt],
                        ["inline_data": ["mime_type": "image/jpeg", "data": b64]],
                    ],
                ]],
                "generationConfig": [
                    "temperature": 0,
                    "responseMimeType": "application/json",
                ],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try validateHTTP(response: response, data: data)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = obj["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]]
            else { throw ReceiptScannerError.unreadableResponse }
            let answerParts = parts.filter { ($0["thought"] as? Bool) != true }
            let chosenParts = answerParts.isEmpty ? parts : answerParts
            let text = chosenParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.isEmpty else { throw ReceiptScannerError.unreadableResponse }
            return text

        case .openAICompatible:
            let endpointStr = config.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: endpointStr.isEmpty ? VisionProvider.openAICompatible.defaultEndpoint : endpointStr) else {
                throw ReceiptScannerError.invalidEndpoint
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = [
                "model": model,
                "temperature": 0,
                "max_tokens": 1200,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
                    ],
                ]],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try validateHTTP(response: response, data: data)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty
            else { throw ReceiptScannerError.unreadableResponse }
            return content
        }
    }

    /// Sends a lightweight text-only ping to verify the configured provider, model ID, and Keychain API key.
    static func testConnection(config: VisionScannerConfig, apiKey: String) async throws -> String {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.provider.defaultModel
            : config.model.trimmingCharacters(in: .whitespacesAndNewlines)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 20
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        switch config.provider {
        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                throw ReceiptScannerError.invalidEndpoint
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 8,
                "messages": [["role": "user", "content": "Reply OK"]],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try validateHTTP(response: response, data: data)
            return "\(config.provider.displayName) connected (\(model))"

        case .gemini:
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
                throw ReceiptScannerError.invalidEndpoint
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let body: [String: Any] = [
                "contents": [["parts": [["text": "Reply OK"]]]],
                "generationConfig": ["maxOutputTokens": 8],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try validateHTTP(response: response, data: data)
            return "\(config.provider.displayName) connected (\(model))"

        case .openAICompatible:
            let endpointStr = config.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: endpointStr.isEmpty ? VisionProvider.openAICompatible.defaultEndpoint : endpointStr) else {
                throw ReceiptScannerError.invalidEndpoint
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 8,
                "messages": [["role": "user", "content": "Reply OK"]],
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            try validateHTTP(response: response, data: data)
            return "\(config.provider.displayName) connected (\(model))"
        }
    }

    private static func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ReceiptScannerError.unreadableResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var message = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String
            {
                message = String(msg.prefix(160))
            }
            throw ReceiptScannerError.httpError(http.statusCode, message)
        }
    }
}
