//
//  WorkspaceStore.swift
//  Enchanted
//
//  Holds the current working directory pi (and future connectors) operate in.
//  Persisted in UserDefaults; changing it restarts the backend in the new cwd.
//

import Foundation

@Observable
@MainActor
final class WorkspaceStore {
    static let shared = WorkspaceStore()
    static let defaultsKey = "piWorkingDirectory"

    var currentDirectory: String

    init() {
        currentDirectory = AgentBackendConfig.piWorkingDirectory
    }

    /// Display name (last path component) for the toolbar.
    var displayName: String {
        URL(fileURLWithPath: currentDirectory).lastPathComponent
    }

    func setDirectory(_ path: String, reconfigureBackend: Bool = true) {
        guard path != currentDirectory else { return }
        currentDirectory = path
        UserDefaults.standard.set(path, forKey: Self.defaultsKey)
        if reconfigureBackend {
            AgentBackendConfig.reconfigure()
        }
    }
}
