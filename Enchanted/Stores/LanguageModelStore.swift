//
//  ModelStore.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation
import OSLog
import SwiftData

@Observable
@MainActor
final class LanguageModelStore {
    static let shared = LanguageModelStore(swiftDataService: SwiftDataService.shared)
    
    private var swiftDataService: SwiftDataService
    var models: [LanguageModelSD] = []
    var supportsImages = false
    var selectedModel: LanguageModelSD?
    
    init(swiftDataService: SwiftDataService) {
        self.swiftDataService = swiftDataService
    }
    
    func setModel(model: LanguageModelSD?) {
        guard let model else {
            selectedModel = nil
            supportsImages = false
            return
        }

        // A conversation and the refreshed model list can contain different
        // SwiftData instances for the same persisted model. Match by stable name
        // instead of object identity so restoring a conversation cannot clear the
        // composer model label.
        guard let availableModel = models.first(where: { $0.name == model.name }) else { return }
        selectedModel = availableModel
        supportsImages = availableModel.supportsImages
    }
    
    func setModel(modelName: String) {
        let model = models.first(where: { $0.name == modelName }) ?? models.first
        setModel(model: model)
    }
    
    func loadModels() async throws {
        let previouslySelectedName = selectedModel?.name
        let remoteModels = try await ConversationStore.shared.backend.models()
        try await swiftDataService.saveModels(models: remoteModels.map {
            LanguageModelSD(
                name: $0.name,
                imageSupport: $0.imageSupport,
                modelProvider: $0.provider,
                providerID: $0.providerID
            )
        })
        
        let storedModels = (try? await swiftDataService.fetchModels()) ?? []
        
        let remoteModelNames = remoteModels.map { $0.name }
        let availableModels = storedModels.filter { remoteModelNames.contains($0.name) }
        self.models = availableModels

        let configuredDefault = UserDefaults.standard.string(forKey: "piDefaultModel")
        let preferredName = previouslySelectedName ?? configuredDefault
        let selection = preferredName.flatMap { preferred in
            availableModels.first(where: { $0.name == preferred })
        } ?? availableModels.first

        self.selectedModel = selection
        self.supportsImages = selection?.supportsImages ?? false
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "subj.Enchanted", category: "ModelSelection")
            .info("Loaded \(availableModels.count) models; selected \(selection?.name ?? "<none>", privacy: .public)")
    }
    
    func deleteAllModels() async throws {
        models = []
        try await swiftDataService.deleteModels()
    }
}
