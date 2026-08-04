import SwiftUI
import AppKit

/// One recent-file tile: a page-preview card showing the file's first lines, + filename.
struct RecentTile: View {
    let url: URL
    @State private var snippet = ""

    var body: some View {
        Button { WindowManager.shared.open(url) } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.09, green: 0.11, blue: 0.15))
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.19, green: 0.22, blue: 0.27))
                    Text(snippet)
                        .font(.system(size: 7, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(white: 0.78))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(1)
                        .padding(8)
                        .frame(width: 120, height: 92, alignment: .topLeading)
                        .clipped()
                }
                .frame(width: 120, height: 92)
                Text(url.lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(width: 120)
            }
        }
        .buttonStyle(.plain)
        .help(url.path)
        .accessibilityLabel("Open recent file \(url.lastPathComponent)")
        .onAppear { snippet = FilePreview.snippet(for: url) }
    }
}

/// The Recent grid shown on the home screen when there are existing recents.
struct RecentFilesGrid: View {
    let urls: [URL]
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16)]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent").font(.headline).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(urls, id: \.self) { RecentTile(url: $0) }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
