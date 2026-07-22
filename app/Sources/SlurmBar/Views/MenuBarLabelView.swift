import SlurmBarKit
import SwiftUI

/// The menu bar item itself.
///
/// Everything here is deliberately monochrome and system-sized so the item sits correctly
/// beside Apple's own menu bar icons in light mode, dark mode and with menu bar tinting. No
/// hardcoded colours — the only colour used is the accent-free `.red` failure dot, which
/// matches how system items flag attention.
struct MenuBarLabelView: View {
    let label: MenuBarLabel

    var body: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: label.symbolName)
                    // Template rendering is what makes it adopt the menu bar's foreground colour.
                    .renderingMode(.template)

                if label.showsFailureIndicator {
                    Circle()
                        .fill(.red)
                        .frame(width: 5, height: 5)
                        .offset(x: 3, y: -2)
                }
            }

            if let text = label.text {
                Text(text)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.accessibilityLabel)
    }
}

#if DEBUG
#Preview("Counts") {
    MenuBarLabelView(label: MenuBarLabel(
        symbolName: "server.rack",
        text: "3R 2P",
        showsFailureIndicator: false,
        accessibilityLabel: "SlurmBar, 3 running, 2 pending"
    ))
    .padding()
}

#Preview("Failure") {
    MenuBarLabelView(label: MenuBarLabel(
        symbolName: "server.rack",
        text: "37%",
        showsFailureIndicator: true,
        accessibilityLabel: "SlurmBar, 1 running, 0 pending, 1 recently failed"
    ))
    .padding()
}
#endif
