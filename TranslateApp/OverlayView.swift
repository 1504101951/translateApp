import SwiftUI
import TranslateCore

struct OverlayView: View {
    @Bindable var session: SelectionSessionController
    var onActivate: () async -> Void
    var onDismiss: () -> Void
    var onContentChange: () -> Void

    var body: some View {
        content
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .onChange(of: session.snapshot.phase) { _, _ in
                onContentChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayEscape)) { _ in
                onDismiss()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.snapshot.phase {
        case .idle:
            EmptyView()
        case .trigger:
            Button("翻译") {
                Task { await onActivate() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .translating:
            resultColumn(title: "翻译中…", showsProgress: true)
        case .completed:
            resultColumn(title: "译文", showsProgress: false)
        case .failed:
            resultColumn(title: session.snapshot.message ?? "翻译失败", showsProgress: false)
        case .sizeLimited:
            resultColumn(title: session.snapshot.message ?? "选区过长", showsProgress: false)
        }
    }

    private func resultColumn(title: String, showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(resultBody)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 300, height: 180)
        }
    }

    private var resultBody: String {
        let text = session.snapshot.translatedText
        if text.isEmpty {
            return session.snapshot.message ?? ""
        }
        return text
    }
}
