import AppKit
import SwiftUI

/// The MenuBarExtra (.window style) panel grows with its content but never shrinks back:
/// after Settings was folded away, a short list sat in the middle of a tall glass window
/// (decisions.md D-017). Placed behind the content, this view resizes the panel to the
/// content's size whenever the content is laid out, keeping the top edge under the menu bar.
/// Titled windows (the hotkey / notification window) are left alone: the user sizes those.
struct MenuBarWindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> FitterView { FitterView() }
    func updateNSView(_ view: FitterView, context: Context) {}

    final class FitterView: NSView {
        override func layout() {
            super.layout()
            fit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fit()
        }

        private func fit() {
            guard let window, !window.styleMask.contains(.titled) else { return }
            let wanted = bounds.size
            guard wanted.width > 1, wanted.height > 1 else { return }
            let current = window.contentRect(forFrameRect: window.frame).size
            // Growing is SwiftUI's job; only pull the window in when it is too tall or wide.
            guard current.height > wanted.height + 0.5 || current.width > wanted.width + 0.5 else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: wanted))
            frame.origin.x = window.frame.midX - frame.width / 2
            frame.origin.y = window.frame.maxY - frame.height
            DispatchQueue.main.async { window.setFrame(frame, display: true) }
        }
    }
}
