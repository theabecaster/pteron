import SwiftUI

/// The four steps of an install, top to bottom: done ones checked, the one in progress with a
/// spinner and one line under it, the rest waiting. A bar shows only when the installer reported
/// how far along it is.
struct SetupStepList: View {
    let state: SetupState
    let name: String
    let theme: TermTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SetupState.Step.allCases, id: \.self) { step in row(step) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ step: SetupState.Step) -> some View {
        let mark = state.mark(step)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            glyph(mark)
                .frame(width: 22, height: 22)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.body.weight(mark == .current ? .semibold : .regular))
                    .foregroundStyle(mark == .pending ? theme.chrome.tertiary : theme.fg)
                if let detail = state.detail(step, name: name) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(theme.chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mark == .current, let progress = state.progress {
                    bar(progress)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(mark == .done ? "Done" : mark == .current ? "In progress" : "Waiting")
    }

    @ViewBuilder
    private func glyph(_ mark: SetupState.Mark) -> some View {
        switch mark {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(theme.chrome.done)
        case .current:
            if state.error != nil {
                Image(systemName: "xmark.circle.fill").font(.system(size: 19)).foregroundStyle(theme.chrome.error)
            } else {
                ProgressView().controlSize(.small).tint(theme.accent)
            }
        case .pending:
            Image(systemName: "circle").font(.system(size: 19)).foregroundStyle(theme.chrome.tertiary)
        }
    }

    private func bar(_ progress: Int) -> some View {
        let fraction = CGFloat(min(max(progress, 0), 100)) / 100
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.fg.opacity(0.10))
                Capsule().fill(theme.accent).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 220)
        .padding(.top, 3)
        .animation(.easeOut(duration: 0.25), value: progress)
        .accessibilityLabel("\(progress) percent")
    }
}
