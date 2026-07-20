//
//  ClipboardHistoryView.swift
//  boringNotch — clipboard tab (sizing rolled back to pre-iter6 adaptive rectangles)
//

import Defaults
import SwiftData
import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var manager = ClipboardHistoryManager.shared
    @ObservedObject private var keyboard = ClipboardKeyboardMonitor.shared
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    @State private var showTextPopup = false
    @State private var now = Date()
    /// Selected card frame in AppKit screen coords (for popup arrow + placement).
    @State private var selectedCardScreenFrame: CGRect = .null
    /// Copy animation target + phase
    @State private var copyAnimatingID: PersistentIdentifier?
    @State private var copyPhase: ClipboardCopyPhase?
    @State private var closeWorkItem: DispatchWorkItem?
    @State private var promoteWorkItem: DispatchWorkItem?

    // MARK: Pre-iter6 card geometry (adaptive height, ~140 width)
    private let cardSpacing: CGFloat = 8
    private let cornerRadius: CGFloat = 10
    private let outerHorizontalPadding: CGFloat = 10
    private let bottomSafe: CGFloat = 10
    private let topSafe: CGFloat = 4
    private let stripHorizontalInset: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let metrics = layoutMetrics(in: geo.size)
            cardsStrip(metrics: metrics)
                .padding(.horizontal, outerHorizontalPadding)
                .padding(.top, topSafe)
                .padding(.bottom, bottomSafe)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(language.revision)
        .onAppear {
            activateClipboardSession()
        }
        .onDisappear {
            teardownKeyboard()
            closePopup(animated: false)
            cancelPendingCopyClose()
        }
        // Re-bind on every tab re-entry (click / ⌘3 / cycle) — not only first onAppear
        .onReceive(NotificationCenter.default.publisher(for: .clipboardTabDidActivate)) { _ in
            activateClipboardSession()
        }
        // Relative time only; 60s is enough for "now" → "1m" and avoids strip invalidation
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
        .onChange(of: showTextPopup) { _, open in
            keyboard.popupOpen = open
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed {
                closePopup(animated: false)
                cancelPendingCopyClose()
            } else if state == .open, coordinator.currentView == .clipboard {
                activateClipboardSession()
            }
        }
        .onChange(of: manager.selectedIndex) { _, _ in
            if showTextPopup {
                refreshPopupForSelection()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardTextPopupDidHide)) { _ in
            if showTextPopup {
                showTextPopup = false
                keyboard.popupOpen = false
            }
        }
    }

    // MARK: - Metrics (pre-iter6 adaptive rectangles)

    private struct LayoutMetrics {
        let cardHeight: CGFloat
        let cardWidth: CGFloat
        let cornerRadius: CGFloat
    }

    private func layoutMetrics(in size: CGSize) -> LayoutMetrics {
        let available = max(0, size.height - topSafe - bottomSafe)
        let cardH = min(max(available, 56), 120)
        let cardW = max(100, min(cardH * 1.35, 140))
        return LayoutMetrics(cardHeight: cardH, cardWidth: cardW, cornerRadius: cornerRadius)
    }

    // MARK: - Cards

    @ViewBuilder
    private func cardsStrip(metrics: LayoutMetrics) -> some View {
        if manager.visibleItems.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: cardSpacing) {
                        ForEach(Array(manager.visibleItems.enumerated()), id: \.element.persistentModelID) { index, item in
                            let id = item.persistentModelID
                            let phase: ClipboardCopyPhase? = (copyAnimatingID == id) ? copyPhase : nil
                            ClipboardCardView(
                                item: item,
                                isSelected: index == manager.selectedIndex,
                                cardWidth: metrics.cardWidth,
                                cardHeight: metrics.cardHeight,
                                cornerRadius: metrics.cornerRadius,
                                relativeTime: ClipboardRelativeTime.format(item.lastCopiedAt, now: now),
                                copyPhase: phase,
                                onTap: {
                                    handleCardTap(item: item, index: index)
                                },
                                onPin: { manager.togglePin(item) },
                                onDelete: { manager.delete(item) },
                                onPaste: {
                                    manager.selectedIndex = index
                                    manager.pasteItem(item)
                                    vm.close()
                                },
                                onCopyMenu: {
                                    performAnimatedAction(item: item, index: index, paste: false)
                                }
                            )
                            .id(id)
                            .background {
                                if index == manager.selectedIndex {
                                    ScreenFrameReporter { frame in
                                        selectedCardScreenFrame = frame
                                        if showTextPopup {
                                            ClipboardTextPopupController.shared.update(
                                                text: popupText(for: manager.selectedItem),
                                                anchorScreenX: frame.midX
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, stripHorizontalInset)
                }
                .scrollIndicators(.never)
                .onChange(of: manager.selectedIndex) { _, newValue in
                    guard manager.visibleItems.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(
                            manager.visibleItems[newValue].persistentModelID,
                            anchor: .center
                        )
                    }
                }
                .onChange(of: copyPhase) { _, phase in
                    if phase == .flying, let first = manager.visibleItems.first {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            proxy.scrollTo(first.persistentModelID, anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L("Clipboard is empty"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Copy + animation + delayed close

    /// First click selects the card; a second click on the already-selected card copies
    /// (or pastes when `clipboardPasteAutomatically` is on).
    private func handleCardTap(item: HistoryItem, index: Int) {
        if index != manager.selectedIndex {
            manager.selectedIndex = index
            return
        }
        if Defaults[.clipboardPasteAutomatically] {
            performAnimatedAction(item: item, index: index, paste: true)
        } else {
            performAnimatedAction(item: item, index: index, paste: false)
        }
    }

    private func performAnimatedAction(item: HistoryItem, index: Int, paste: Bool) {
        cancelPendingCopyClose()
        manager.selectedIndex = index

        if paste {
            manager.pasteItem(item)
        } else {
            ClipboardService.shared.copy(item)
        }

        let id = item.persistentModelID
        copyAnimatingID = id

        withAnimation(.easeOut(duration: 0.28)) {
            copyPhase = .fill
        }

        let promote = DispatchWorkItem {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                manager.promoteCopied(item)
                copyPhase = .flying
            }
        }
        promoteWorkItem = promote
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: promote)

        let close = DispatchWorkItem {
            copyAnimatingID = nil
            copyPhase = nil
            closePopup(animated: false)
            vm.close()
        }
        closeWorkItem = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72, execute: close)
    }

    private func cancelPendingCopyClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
        promoteWorkItem?.cancel()
        promoteWorkItem = nil
        copyAnimatingID = nil
        copyPhase = nil
    }

    // MARK: - Space popup

    private func popupText(for item: HistoryItem?) -> String? {
        guard let item else { return nil }
        switch item.contentKind {
        case .text, .link:
            let t = item.text ?? item.previewableText
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : t
        default:
            return nil
        }
    }

    private var popupText: String? {
        popupText(for: manager.selectedItem)
    }

    private func togglePopup() {
        if showTextPopup {
            closePopup()
            return
        }
        guard let text = popupText else { return }
        showTextPopup = true
        keyboard.popupOpen = true
        let anchor = selectedCardScreenFrame.isNull ? nil : selectedCardScreenFrame.midX
        ClipboardTextPopupController.shared.show(text: text, anchorScreenX: anchor)
        requestKeyWindow()
    }

    private func refreshPopupForSelection() {
        let text = popupText
        let anchor = selectedCardScreenFrame.isNull ? nil : selectedCardScreenFrame.midX
        if let text {
            ClipboardTextPopupController.shared.update(text: text, anchorScreenX: anchor)
        } else {
            closePopup(animated: false)
        }
    }

    private func closePopup(animated: Bool = true) {
        ClipboardTextPopupController.shared.hide(postNotification: false)
        showTextPopup = false
        keyboard.popupOpen = false
    }

    // MARK: - Keyboard lifecycle

    /// Re-bind clipboard handlers + key focus. Idempotent for monitors; safe on every entry.
    private func activateClipboardSession() {
        setupKeyboard()
        requestKeyWindow()
    }

    private func setupKeyboard() {
        let monitor = ClipboardKeyboardMonitor.shared
        monitor.startNotchSession() // no-op if already running
        monitor.onMove = { dx, dy in
            manager.moveSelection(dx: dx, dy: dy)
        }
        monitor.onEnter = {
            if showTextPopup {
                closePopup()
            }
            guard let item = manager.selectedItem else { return }
            performAnimatedAction(item: item, index: manager.selectedIndex, paste: true)
        }
        monitor.onDelete = {
            manager.deleteSelected()
            if showTextPopup {
                refreshPopupForSelection()
            }
        }
        monitor.onEscape = {
            if showTextPopup {
                closePopup()
            } else {
                vm.close()
            }
        }
        monitor.onSpace = {
            togglePopup()
        }
        monitor.onCopy = {
            guard let item = manager.selectedItem else { return }
            performAnimatedAction(item: item, index: manager.selectedIndex, paste: false)
        }
        monitor.popupOpen = showTextPopup
        monitor.enableClipboardHandlers()
    }

    private func teardownKeyboard() {
        // Transition race: old instance may disappear AFTER a new clipboard tab re-entered.
        // Never clear handlers if clipboard is the active tab again.
        guard BoringViewCoordinator.shared.currentView != .clipboard else { return }
        ClipboardKeyboardMonitor.shared.disableClipboardHandlers()
        closePopup(animated: false)
    }

    private func requestKeyWindow() {
        NotificationCenter.default.post(name: .clipboardTabKeyFocus, object: true)
        DispatchQueue.main.async {
            for window in NSApp.windows {
                if window is BoringNotchSkyLightWindow || window is BoringNotchWindow {
                    window.makeKey()
                }
            }
        }
    }
}

extension Notification.Name {
    /// Allow notch window to become key (clipboard nav + notch-wide ⌘).
    static let clipboardTabKeyFocus = Notification.Name("clipboardTabKeyFocus")
    /// Posted on every entry to the clipboard tab so handlers rebind even if onAppear races.
    static let clipboardTabDidActivate = Notification.Name("clipboardTabDidActivate")
    static let clipboardTextPopupDidHide = Notification.Name("clipboardTextPopupDidHide")
}
