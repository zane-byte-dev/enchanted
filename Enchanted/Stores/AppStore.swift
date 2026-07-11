//
//  AppStore.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 11/12/2023.
//

import Foundation
import Combine
import SwiftUI

enum AppState {
    case chat
    case voice
}

@Observable
@MainActor
final class AppStore {
    static let shared = AppStore()
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var pingInterval: TimeInterval = 5
    private var lastInstallationDiagnosticAt = Date.distantPast
    private var lastInstallationDiagnosticPassed = false
    private var lastDiagnosticExecutable = ""
    var isReachable: Bool = true
    var notifications: [NotificationMessage] = []
    var menuBarIcon: String? = nil
    var appState: AppState = .chat
    /// macOS only: replace main window content with full-page Settings.
    var showSettings: Bool = false
    /// macOS only: replace main window content with the full-page Skills manager.
    var showSkills: Bool = false
    /// macOS only: show the centered conversation search panel.
    var showConversationSearch: Bool = false

    init() {
        if let storedIntervalString = UserDefaults.standard.string(forKey: "pingInterval") {
            pingInterval = Double(storedIntervalString) ?? 5
            
            if pingInterval <= 0 {
                pingInterval = .infinity
            }
        }
        startCheckingReachability(interval: pingInterval)
    }
    
    private func startCheckingReachability(interval: TimeInterval = 5) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { [weak self] in
                let status = await self?.reachable() ?? false
                await self?.updateReachable(status)
            }
        }
    }
    
    private func updateReachable(_ isReachable: Bool) {
        withAnimation {
            self.isReachable = isReachable
        }
    }

    private func stopCheckingReachability() {
        timer?.invalidate()
        timer = nil
    }

    private func reachable() async -> Bool {
        let executable = AgentBackendConfig.piExecutable
        if executable != lastDiagnosticExecutable
            || Date.now.timeIntervalSince(lastInstallationDiagnosticAt) > 60 {
            let diagnostic = await AgentBackendConfig.diagnoseInstallation()
            lastInstallationDiagnosticAt = .now
            lastDiagnosticExecutable = executable
            if case .ready = diagnostic {
                lastInstallationDiagnosticPassed = true
            } else {
                lastInstallationDiagnosticPassed = false
                return false
            }
        }
        guard lastInstallationDiagnosticPassed else { return false }
        let status = await ConversationStore.shared.backend.reachable()
        return status
    }

    func refreshReachability() async {
        updateReachable(await reachable())
    }
    
    func uiLog(message: String, status: NotificationMessage.Status) {
        notifications = [NotificationMessage(message: message, status: status)] + notifications.suffix(5)
    }
}
