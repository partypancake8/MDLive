import SwiftUI

/// Version History sidebar (⌥⌘Y): every saved version of this file, newest
/// first, grouped by day. Picking one shows it read only with a banner on top.
struct HistorySidebar: View {
    @ObservedObject var model: DocumentModel

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; f.doesRelativeDateFormatting = true
        return f
    }()
    static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f
    }()

    static func labelText(_ label: String) -> String {
        switch label {
        case "you": return "You"
        case "outside": return "Outside change"
        case "opened": return "Opened"
        case "restored": return "Restored"
        default: return label.capitalized
        }
    }

    private var days: [(String, [HistoryVersion])] {
        var out: [(String, [HistoryVersion])] = []
        for v in model.versions {
            let d = Self.dayFormat.string(from: v.timestamp)
            if out.last?.0 == d { out[out.count - 1].1.append(v) } else { out.append((d, [v])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Version History").font(.headline).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if model.versions.isEmpty {
                Text("No versions yet")
                    .foregroundStyle(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(days, id: \.0) { day in
                        Section(day.0) {
                            ForEach(day.1) { v in row(v) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .accessibilityLabel("Version history")
    }

    private func row(_ v: HistoryVersion) -> some View {
        let selected = model.previewing?.id == v.id
        return Button { model.preview(v) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeFormat.string(from: v.timestamp)).font(.body)
                Text(Self.labelText(v.label)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2).padding(.horizontal, 4)
            .background(selected ? Color.accentColor.opacity(0.25) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

/// Thin bar above the content while an old version is on screen.
struct HistoryBanner: View {
    @ObservedObject var model: DocumentModel
    let version: HistoryVersion

    private static let format: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Text("Viewing version from \(Self.format.string(from: version.timestamp))").font(.callout)
            Spacer()
            Button("Restore") { model.restore(version) }
            Button("Back to current") { model.backToCurrent() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.18))
    }
}
