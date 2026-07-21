//
//  QuickLookService.swift
//  boringNotch
//
//  System Quick Look via QLPreviewPanel only (no SwiftUI .quickLookPreview —
//  dual presentation was fighting over frame/size).
//  Fixed square window, locked min=max, re-asserted after content swaps
//  (keyboard browse must not thrash scale).
//

import Foundation
import UniformTypeIdentifiers
import SwiftUI
import QuickLookUI
import AppKit

@MainActor
final class QuickLookService: ObservableObject {
    @Published var urls: [URL] = []
    @Published var selectedURL: URL?
    @Published var isQuickLookOpen: Bool = false

    private var scopedURLs: [URL] = []
    private let host = QuickLookHostController.shared

    func show(urls: [URL], selectFirst: Bool = true, slideshow: Bool = false) {
        guard !urls.isEmpty else { return }

        // Scope new URLs first, then drop old scopes — avoids a gap while panel reloads.
        var newScoped: [URL] = []
        for url in urls where url.isFileURL {
            if url.startAccessingSecurityScopedResource() {
                newScoped.append(url)
            }
        }
        let previousScoped = scopedURLs
        scopedURLs = newScoped
        for url in previousScoped where !newScoped.contains(url) {
            url.stopAccessingSecurityScopedResource()
        }

        self.urls = urls
        self.isQuickLookOpen = true
        self.selectedURL = selectFirst ? urls.first : (selectedURL.flatMap { urls.contains($0) ? $0 : nil } ?? urls.first)

        // If already open, only swap items — keep the same locked square (no reopen).
        if host.isPanelVisible {
            host.reload(urls: urls)
            return
        }

        host.present(urls: urls) { [weak self] in
            Task { @MainActor in
                self?.handlePanelClosedExternally()
            }
        }
    }

    func hide() {
        host.dismiss()
        finishClosed()
    }

    func showQuickLook(urls: [URL]) {
        show(urls: urls, selectFirst: true, slideshow: false)
    }

    func updateSelection(urls: [URL]) {
        guard isQuickLookOpen else { return }
        show(urls: urls, selectFirst: true)
    }

    private func handlePanelClosedExternally() {
        guard isQuickLookOpen else { return }
        finishClosed()
    }

    private func finishClosed() {
        releaseSecurityScopes()
        selectedURL = nil
        urls.removeAll()
        isQuickLookOpen = false
    }

    private func releaseSecurityScopes() {
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
    }
}

// MARK: - Fixed square (locked)

enum QuickLookPanelSizing {
    /// Constant outer size for every content type.
    private static let preferredSide: CGFloat = 640
    private static let screenMargin: CGFloat = 48
    private static let maxScreenFraction: CGFloat = 0.70

    static func squareSide(on screen: NSScreen) -> CGFloat {
        let visible = screen.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let maxSide = min(visible.width, visible.height) * maxScreenFraction
        return min(preferredSide, maxSide).rounded(.down)
    }

    static func preferredFrame(on screen: NSScreen) -> NSRect {
        let s = squareSide(on: screen)
        let visible = screen.visibleFrame
        return NSRect(
            x: (visible.midX - s / 2).rounded(.down),
            y: (visible.midY - s / 2).rounded(.down),
            width: s,
            height: s
        )
    }

    /// Apply fixed frame + hard min/max lock so QL cannot auto-resize to content.
    static func lockSquare(on panel: QLPreviewPanel) {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = preferredFrame(on: screen)
        let size = frame.size

        // Disable any in-flight frame animation, then pin size.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.minSize = size
        panel.maxSize = size
        panel.setFrame(frame, display: true, animate: false)
        panel.minSize = size
        panel.maxSize = size
        NSAnimationContext.endGrouping()
    }

    /// True when the panel drifted away from our locked square.
    static func needsRelock(_ panel: QLPreviewPanel) -> Bool {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return false }
        let expected = preferredFrame(on: screen)
        let f = panel.frame
        return abs(f.width - expected.width) > 0.5
            || abs(f.height - expected.height) > 0.5
            || abs(f.origin.x - expected.origin.x) > 2
            || abs(f.origin.y - expected.origin.y) > 2
    }
}

// MARK: - Host window + first responder

private final class QuickLookKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickLookHostController {
    static let shared = QuickLookHostController()

    private var hostPanel: NSPanel?
    private let hostView = QuickLookHostView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    private var visibilityTimer: Timer?
    private var relockWorkItems: [DispatchWorkItem] = []
    private var revealWorkItem: DispatchWorkItem?
    private var onClose: (() -> Void)?
    private var isPresenting = false
    /// True while swapping preview items; panel is hidden so auto-resize is invisible.
    private var isContentSwapping = false
    private var resizeObserver: NSObjectProtocol?

    var isPanelVisible: Bool {
        QLPreviewPanel.shared()?.isVisible == true
    }

    private init() {}

    func present(urls: [URL], onClose: @escaping () -> Void) {
        self.onClose = onClose
        hostView.urls = urls
        hostView.onUserClosed = { [weak self] in
            self?.handleUserClosed()
        }

        let host = ensureHostPanel()
        NSApp.activate(ignoringOtherApps: true)
        host.alphaValue = 0
        host.orderFrontRegardless()
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(hostView)

        guard let ql = QLPreviewPanel.shared() else {
            fallbackQLManage(urls: urls)
            return
        }

        isPresenting = true
        isContentSwapping = true
        cancelContentRelocks()
        revealWorkItem?.cancel()

        ql.updateController()
        if ql.dataSource == nil {
            ql.dataSource = hostView
            ql.delegate = hostView
        }

        // Appear invisible at locked size so first paint is never wrong-sized.
        ql.alphaValue = 0
        QuickLookPanelSizing.lockSquare(on: ql)

        ql.currentPreviewItemIndex = 0
        ql.reloadData()
        ql.makeKeyAndOrderFront(nil)

        QuickLookPanelSizing.lockSquare(on: ql)
        observePanelResize(ql)
        startVisibilityWatch()
        revealWhenStable(after: 0.08)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let ql = QLPreviewPanel.shared(), ql.isVisible {
                QuickLookPanelSizing.lockSquare(on: ql)
            } else {
                self.fallbackQLManage(urls: urls)
                self.isPresenting = false
            }
        }
    }

    /// Swap preview items without a large-size flash.
    /// Hides the panel for the duration of `reloadData()` auto-resize, then
    /// re-shows only after the square lock is re-applied.
    func reload(urls: [URL]) {
        hostView.urls = urls
        guard let ql = QLPreviewPanel.shared(), ql.isVisible || isPanelVisible else {
            // Panel gone — present fresh if we still have a close handler.
            if onClose != nil {
                present(urls: urls, onClose: onClose!)
            }
            return
        }

        isContentSwapping = true
        cancelContentRelocks()
        revealWorkItem?.cancel()

        // Instant hide — any content-driven grow happens while invisible.
        ql.alphaValue = 0
        QuickLookPanelSizing.lockSquare(on: ql)
        // Park off-screen as a second line of defense (some QL builds ignore alpha).
        parkOffscreen(ql)

        if ql.dataSource == nil || ql.dataSource as AnyObject? !== hostView {
            ql.dataSource = hostView
            ql.delegate = hostView
        }

        if ql.currentPreviewItemIndex != 0 {
            ql.currentPreviewItemIndex = 0
        }
        ql.reloadData()

        // Still invisible: pin square and move back to center.
        QuickLookPanelSizing.lockSquare(on: ql)
        observePanelResize(ql)
        startVisibilityWatch()
        // Brief settle so the new preview's internal layout finishes under the lock.
        revealWhenStable(after: 0.07)
    }

    func dismiss() {
        stopVisibilityWatch()
        cancelContentRelocks()
        revealWorkItem?.cancel()
        revealWorkItem = nil
        isContentSwapping = false
        stopResizeObserver()
        if let ql = QLPreviewPanel.shared(), ql.isVisible {
            ql.alphaValue = 1
            ql.orderOut(nil)
        }
        clearPanelDataSource()
        hostPanel?.orderOut(nil)
        hostView.urls = []
        onClose = nil
    }

    private func handleUserClosed() {
        stopVisibilityWatch()
        cancelContentRelocks()
        revealWorkItem?.cancel()
        revealWorkItem = nil
        isContentSwapping = false
        stopResizeObserver()
        clearPanelDataSource()
        hostPanel?.orderOut(nil)
        hostView.urls = []
        let cb = onClose
        onClose = nil
        cb?()
    }

    // MARK: - Size enforcement / flash-free reveal

    private func parkOffscreen(_ panel: QLPreviewPanel) {
        let size = panel.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let off = NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setFrame(off, display: false, animate: false)
        NSAnimationContext.endGrouping()
    }

    /// Keep locking while hidden, then reveal only when the frame is the square.
    private func revealWhenStable(after delay: TimeInterval) {
        // Quiet re-locks while invisible (no visible thrash).
        let lockDelays: [TimeInterval] = [0.0, 0.02, 0.04, 0.06]
        for d in lockDelays {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isContentSwapping else { return }
                guard let ql = QLPreviewPanel.shared() else { return }
                QuickLookPanelSizing.lockSquare(on: ql)
            }
            relockWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
        }

        let reveal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let ql = QLPreviewPanel.shared(), ql.isVisible || self.isPanelVisible else {
                self.isContentSwapping = false
                self.isPresenting = false
                return
            }
            QuickLookPanelSizing.lockSquare(on: ql)
            // If still wrong size, one more tick before reveal.
            if QuickLookPanelSizing.needsRelock(ql) {
                QuickLookPanelSizing.lockSquare(on: ql)
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            ql.alphaValue = 1
            NSAnimationContext.endGrouping()
            self.isContentSwapping = false
            self.isPresenting = false
            // Light tail locks after reveal, only if drift detected (keeps flash rare).
            self.scheduleQuietTailLocks()
        }
        revealWorkItem = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reveal)
    }

    private func scheduleQuietTailLocks() {
        let delays: [TimeInterval] = [0.12, 0.28, 0.5]
        for delay in delays {
            let work = DispatchWorkItem {
                guard let ql = QLPreviewPanel.shared(), ql.isVisible else { return }
                // Only correct if drifted — avoid setFrame spam when already square.
                if QuickLookPanelSizing.needsRelock(ql) {
                    // Correct invisibly: hide → lock → show in the same turn.
                    let prev = ql.alphaValue
                    ql.alphaValue = 0
                    QuickLookPanelSizing.lockSquare(on: ql)
                    ql.alphaValue = prev > 0 ? prev : 1
                }
            }
            relockWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelContentRelocks() {
        relockWorkItems.forEach { $0.cancel() }
        relockWorkItems.removeAll()
    }

    private func observePanelResize(_ panel: QLPreviewPanel) {
        stopResizeObserver()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let ql = QLPreviewPanel.shared(), ql.isVisible else { return }
                guard QuickLookPanelSizing.needsRelock(ql) else { return }
                if self.isContentSwapping {
                    // Still hidden — just pin.
                    QuickLookPanelSizing.lockSquare(on: ql)
                } else {
                    // Visible drift: hide for the correction so the user never
                    // sees the oversized frame flash.
                    ql.alphaValue = 0
                    QuickLookPanelSizing.lockSquare(on: ql)
                    ql.alphaValue = 1
                }
            }
        }
    }

    private func stopResizeObserver() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    private func startVisibilityWatch() {
        stopVisibilityWatch()
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let visible = QLPreviewPanel.shared()?.isVisible == true
                if !visible, !self.isPresenting, !self.isContentSwapping {
                    self.handleUserClosed()
                    return
                }
                // Don't fight size while mid-swap (panel is hidden on purpose).
                guard !self.isContentSwapping else { return }
                if let ql = QLPreviewPanel.shared(), visible, QuickLookPanelSizing.needsRelock(ql) {
                    ql.alphaValue = 0
                    QuickLookPanelSizing.lockSquare(on: ql)
                    ql.alphaValue = 1
                }
            }
        }
    }

    private func stopVisibilityWatch() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    private func clearPanelDataSource() {
        if let ql = QLPreviewPanel.shared() {
            if ql.dataSource as AnyObject? === hostView {
                ql.dataSource = nil
            }
            if ql.delegate as AnyObject? === hostView {
                ql.delegate = nil
            }
        }
    }

    private func ensureHostPanel() -> NSPanel {
        if let hostPanel { return hostPanel }

        let p = QuickLookKeyPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 4, height: 4),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.alphaValue = 0
        p.contentView = hostView
        hostPanel = p
        return p
    }

    private func fallbackQLManage(urls: [URL]) {
        let paths = urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else {
            handleUserClosed()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p"] + paths
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.handleUserClosed()
                }
            }
        } catch {
            handleUserClosed()
        }
    }
}

/// First-responder view that QLPreviewPanel discovers in the responder chain.
final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []
    var onUserClosed: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !urls.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        if panel.currentPreviewItemIndex < 0 || panel.currentPreviewItemIndex >= urls.count {
            panel.currentPreviewItemIndex = 0
        }
        // Lock size only — no animated resize.
        QuickLookPanelSizing.lockSquare(on: panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        DispatchQueue.main.async { [weak self] in
            if QLPreviewPanel.shared()?.isVisible != true {
                self?.onUserClosed?()
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as QLPreviewItem
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 {
            panel.orderOut(nil)
            return true
        }
        return false
    }

    /// Suppress zoom-from-source animation (was a source of size thrash).
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        nil
    }

    /// Keep content view filling our locked square (prevents letterbox thrash).
    func previewPanel(_ panel: QLPreviewPanel!, preserveAspectRatioFor item: (any QLPreviewItem)!) -> Bool {
        true
    }
}

// MARK: - SwiftUI helper (no longer presents QL itself)

struct QuickLookPresenter: ViewModifier {
    @ObservedObject var service: QuickLookService

    func body(content: Content) -> some View {
        // Intentionally no `.quickLookPreview` — AppKit QLPreviewPanel owns presentation.
        content
    }
}

extension View {
    func quickLookPresenter(using service: QuickLookService) -> some View {
        self.modifier(QuickLookPresenter(service: service))
    }
}
