//
//  UnreachableAPIView.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/02/2024.
//

import SwiftUI
import ActivityIndicatorView

struct UnreachableAPIView: View {
    @State private var showSettings = false
    @State private var diagnostic: PiInstallationDiagnostic = .checking
    @State private var appStore = AppStore.shared

    private var diagnosticMessage: String {
        switch diagnostic {
        case .checking:
            return String(localized: "Checking the pi runtime…")
        case .executableMissing(let path):
            return String(localized: "Pi executable was not found or is not executable: \(path)")
        case .workingDirectoryMissing(let path):
            return String(localized: "The configured working directory does not exist: \(path)")
        case .versionUnavailable(let output):
            return String(localized: "Could not read the pi version. Output: \(output)")
        case .versionTooOld(let found, let required):
            return String(localized: "Pi \(found) is too old. Mox requires pi \(required) or newer.")
        case .rpcUnavailable(let version):
            return String(localized: "Pi \(version) was found, but its RPC service did not respond.")
        case .ready(let version, let modelCount):
            return String(localized: "Pi \(version) is ready with \(modelCount) available models.")
        }
    }

    private var usesBundledRuntime: Bool {
        AgentBackendConfig.isBundledPiExecutable(AgentBackendConfig.piExecutable)
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(usesBundledRuntime ? "Built-in pi needs attention" : "External pi needs attention")
                    .lineLimit(nil)
                    .fontWeight(.medium)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(.label))
                Text(diagnosticMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(
                    usesBundledRuntime
                        ? "Retry the bundled runtime first. You can still choose an external pi as a fallback."
                        : "Let Mox detect pi or choose the executable manually. Release builds include a bundled runtime."
                )
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            if diagnostic == .checking {
                ActivityIndicatorView(isVisible: .constant(true), type: .growingCircle)
                    .frame(width: 21, height: 21)
                    .accessibilityLabel(Text("Checking Pi connection"))
            }

#if os(macOS)
            if let detected = AgentBackendConfig.detectedPiExecutable(),
               detected != AgentBackendConfig.piExecutable {
                Button("Use Detected Pi") { applyExecutable(detected) }
            }
            Button("Choose Pi…", action: chooseExecutable)
#endif

            Button("Retry") { Task { await diagnose() } }
            
            Button(action: { showSettings.toggle() }) {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.accentColor, in: Capsule())
            .buttonStyle(GrowingButton())
            .accessibilityLabel(Text("Open settings"))
        }
        .padding()
        .background(Color(.systemRed).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.systemRed).opacity(0.2), lineWidth: 1)
        }
        .padding()
        .sheet(isPresented: $showSettings) {
            Settings()
        }
        .task { await diagnose() }
    }

    @MainActor
    private func diagnose() async {
        diagnostic = .checking
        diagnostic = await AgentBackendConfig.diagnoseInstallation()
        if case .ready = diagnostic {
            await appStore.refreshReachability()
        }
    }

#if os(macOS)
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Pi")
        if panel.runModal() == .OK, let path = panel.url?.path {
            applyExecutable(path)
        }
    }

    private func applyExecutable(_ path: String) {
        AgentBackendConfig.applyPiSettings(
            executable: path,
            workingDirectory: AgentBackendConfig.piWorkingDirectory
        )
        Task { await diagnose() }
    }
#endif
}

#Preview {
    UnreachableAPIView()
}
