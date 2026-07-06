//
//  WorkspaceStore.swift
//  Enchanted
//
//  Holds the current working directory pi (and future connectors) operate in.
//  Persisted in UserDefaults; changing it restarts the backend in the new cwd.
//

import Foundation

@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()
    static let defaultsKey = "piWorkingDirectory"

    var currentDirectory: String

    init() {
        currentDirectory = UserDefaults.standard.string(forKey: Self.defaultsKey)
            ?? AgentBackendConfig.defaultWorkingDirectory
    }

    /// Display name (last path component) for the toolbar.
    var displayName: String {
        URL(fileURLWithPath: currentDirectory).lastPathComponent
    }

    @MainActor
    func setDirectory(_ path: String) {
        guard path != currentDirectory else { return }
        currentDirectory = path
        UserDefaults.standard.set(path, forKey: Self.defaultsKey)
        AgentBackendConfig.reconfigure()
    }
}
