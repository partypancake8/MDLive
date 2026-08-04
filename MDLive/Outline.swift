import SwiftUI

/// TOC sidebar (V10/DEC-V4). Lists headings; tapping scrolls the WebView.
struct OutlineSidebar: View {
    let items: [OutlineItem]
    let onTap: (String) -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary).font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    Button { onTap(item.anchor) } label: {
                        Text(item.text)
                            .lineLimit(1)
                            .font(item.level <= 2 ? .body : .callout)
                            .padding(.leading, CGFloat((item.level - 1) * 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .accessibilityLabel("Document outline")
    }
}
