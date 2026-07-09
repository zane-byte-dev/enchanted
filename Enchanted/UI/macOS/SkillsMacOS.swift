//
//  SkillsMacOS.swift
//  Enchanted
//
//  Native skills manager, mirroring the Codex "技能" panel: title, search, an
//  "Installed" grid of skill cards, and scope filter tabs. Renders inside the
//  chat detail pane so the conversation sidebar stays visible. Tapping a card
//  opens a detail overlay with the rendered SKILL.md.
//

#if os(macOS)
import SwiftUI
import MarkdownUI

struct SkillsMacOS: View {
    private var store = SkillStore.shared

    @State private var searchText = ""
    @State private var selectedScope: ScopeFilter = .all
    @State private var selectedSkill: PiSkill?

    private enum ScopeFilter: Hashable, CaseIterable {
        case all
        case personal   // .user
        case project    // .project

        var title: String {
            switch self {
            case .all:      return String(localized: "All")
            case .personal: return String(localized: "Personal")
            case .project:  return String(localized: "Project")
            }
        }

        func matches(_ scope: PiSkill.Scope) -> Bool {
            switch self {
            case .all:      return true
            case .personal: return scope == .user || scope == .temporary || scope == .unknown
            case .project:  return scope == .project
            }
        }
    }

    private var filteredSkills: [PiSkill] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return store.skills.filter { skill in
            guard selectedScope.matches(skill.scope) else { return false }
            guard !q.isEmpty else { return true }
            return skill.title.localizedCaseInsensitiveContains(q)
                || skill.name.localizedCaseInsensitiveContains(q)
                || skill.description.localizedCaseInsensitiveContains(q)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                searchField
                scopeTabs

                if store.isLoading && store.skills.isEmpty {
                    loadingState
                } else if filteredSkills.isEmpty {
                    emptyState
                } else {
                    installedSection
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .task { await store.load() }
        .overlay {
            if let skill = selectedSkill {
                SkillDetailOverlay(skill: skill) { selectedSkill = nil }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: selectedSkill)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("技能")
                    .font(.system(size: 30, weight: .bold))
                Text("通过任务专用技能扩展 pi 的能力")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                Task { await store.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reload skills")
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            TextField("搜索技能", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Scope tabs

    private var scopeTabs: some View {
        HStack(spacing: 8) {
            ForEach(ScopeFilter.allCases, id: \.self) { scope in
                let isSelected = selectedScope == scope
                Button { selectedScope = scope } label: {
                    Text(scope.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.gray.opacity(0.15) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Installed grid

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Installed")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(filteredSkills.count)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Divider()

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(filteredSkills) { skill in
                    SkillCard(skill: skill) { selectedSkill = skill }
                }
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 34))
                .foregroundColor(.secondary.opacity(0.5))
            Text(store.lastError ?? String(localized: "No matching skills."))
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Skill card

private struct SkillCard: View {
    let skill: PiSkill
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                SkillIcon(size: 40, corner: 10)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        ScopeBadge(scope: skill.scope)
                    }
                    Text(skill.description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hover ? Color.gray.opacity(0.08) : Color.gray.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(hover ? 0.2 : 0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SkillIcon: View {
    var size: CGFloat
    var corner: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(LinearGradient(
                colors: [Color.orange.opacity(0.9), Color.purple.opacity(0.8)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "cube.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundColor(.white)
            )
    }
}

private struct ScopeBadge: View {
    let scope: PiSkill.Scope
    var body: some View {
        Text(scope.localizedLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.12)))
    }
}

// MARK: - Detail overlay

private struct SkillDetailOverlay: View {
    let skill: PiSkill
    var onClose: () -> Void

    @State private var bodyText: String = ""
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                topBar
                Divider()
                content
                Divider()
                bottomBar
            }
            .frame(maxWidth: 620, maxHeight: 640)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .padding(40)
        }
        .task { load() }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            SkillIcon(size: 44, corner: 12)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(skill.title)
                        .font(.system(size: 24, weight: .bold))
                    Text("Skill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.secondary)
                    ScopeBadge(scope: skill.scope)
                }
                Text(skill.description)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let loadError {
                    Text(loadError)
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                        .padding(.top, 8)
                } else {
                    Divider().padding(.vertical, 4)
                    Markdown(bodyText)
                        .markdownTheme(MarkdownColours.enchantedTheme)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                NSWorkspace.shared.selectFile(skill.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer()

            Button {
                Clipboard.shared.setString("/skill:\(skill.name) ")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("复制 /skill 命令")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func load() {
        guard !skill.path.isEmpty else {
            loadError = String(localized: "Skill file path unavailable.")
            return
        }
        guard let raw = try? String(contentsOfFile: skill.path, encoding: .utf8) else {
            loadError = String(localized: "Could not read skill file.")
            return
        }
        bodyText = Self.stripFrontmatter(raw)
    }

    /// Remove a leading YAML frontmatter block (`---\n...\n---`) so only the
    /// human-readable body renders.
    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        var closingIndex: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = i
            break
        }
        guard let end = closingIndex, end + 1 < lines.count else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
