import Foundation
import SwiftUI

final class LMStudioService: ObservableObject {
    static let defaultBaseURL = "http://localhost:1234/v1"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "lmStudioBaseURL") }
    }
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "lmStudioSelectedModel") }
    }
    @Published var availableModels: [String] = []
    @Published var isConnected: Bool = false
    @Published var isLoadingModels: Bool = false

    init() {
        self.baseURL = UserDefaults.standard.string(forKey: "lmStudioBaseURL") ?? Self.defaultBaseURL
        self.selectedModel = UserDefaults.standard.string(forKey: "lmStudioSelectedModel") ?? ""
        self.availableModels = UserDefaults.standard.stringArray(forKey: "lmStudioAvailableModels") ?? []
    }

    static func normalizedBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/chat/completions") { s.removeLast("/chat/completions".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func parseModels(from data: Data) throws -> [String] {
        struct ModelList: Decodable { let data: [Entry] }
        struct Entry: Decodable { let id: String }
        return try JSONDecoder().decode(ModelList.self, from: data).data.map { $0.id }
    }

    @MainActor
    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        let root = Self.normalizedBaseURL(baseURL)
        guard let url = URL(string: "\(root)/models") else {
            isConnected = false; availableModels = []; return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                isConnected = false; availableModels = []; return
            }
            let models = try Self.parseModels(from: data)
            isConnected = true
            availableModels = models
            UserDefaults.standard.set(models, forKey: "lmStudioAvailableModels")
            if selectedModel.isEmpty, let first = models.first { selectedModel = first }
        } catch {
            isConnected = false
            availableModels = []
        }
    }
}
