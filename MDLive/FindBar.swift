import SwiftUI

/// In-document find bar (V8/DEC-V13). Drives the JS highlighter via the model.
struct FindBar: View {
    @ObservedObject var model: PreviewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $model.findQuery)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.findStep(true) }
                .onChange(of: model.findQuery) { _ in model.runFind() }
            Text(model.findCount == 0 ? "" : "\(model.findCurrent)/\(model.findCount)")
                .foregroundStyle(.secondary).font(.caption).monospacedDigit().frame(minWidth: 36)
            Button { model.findStep(false) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
            Button { model.findStep(true) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
            Button { model.closeFind() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .onAppear { focused = true }
        .accessibilityLabel("Find in document")
    }
}
