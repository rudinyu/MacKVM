import AppKit
import SwiftUI

enum ControlOwnershipHUDMessage {
    static func make(
        for transition: ControlOwnershipTransition,
        remoteDeviceName: String?
    ) -> String {
        switch transition {
        case .outboundControl:
            let name = remoteDeviceName ?? String(localized: "Other device")
            return String(
                format: String(localized: "Keyboard input now goes to %@"),
                name
            )
        case .inboundControl:
            let name = remoteDeviceName ?? String(localized: "Other device")
            return String(
                format: String(localized: "%@ now controls this Mac"),
                name
            )
        case .returnedLocally:
            return String(localized: "Keyboard input returned to this Mac")
        }
    }
}

@MainActor
final class ControlOwnershipHUDController {
    private var panel: NonActivatingHUDPanel?
    private var dismissalTask: Task<Void, Never>?

    func show(
        _ transition: ControlOwnershipTransition,
        remoteDeviceName: String? = nil
    ) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let message = ControlOwnershipHUDMessage.make(
            for: transition,
            remoteDeviceName: remoteDeviceName
        )
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: ControlOwnershipHUDView(message: message)
        )

        let size = NSSize(width: 390, height: 82)
        let visibleFrame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.maxY - size.height - 34,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.orderFrontRegardless()

        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NonActivatingHUDPanel {
        let panel = NonActivatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private final class NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ControlOwnershipHUDView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.headline)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
    }
}
