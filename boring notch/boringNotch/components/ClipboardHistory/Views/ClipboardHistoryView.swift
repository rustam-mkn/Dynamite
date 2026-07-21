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
    @StateObject private var quickLookService = QuickLookService()

    @State private var now = Date()
    /// Temp files created so system Quick Look can preview in-memory clipboard data.
    @State private var tempPreviewURLs: [URL] = []
    /// Whether we called `SharingStateManager.beginInteraction` for an open QL session.
    @State private var holdingNotchOpenForQL = false
    /// Copy animation target + phase
    @State private var copyAnimatingID: PersistentIdentifier?
    @State private var copyPhase: ClipboardCopyPhase?
    @State private var closeWorkItem: DispatchWorkItem?
    @State private var promoteWorkItem: DispatchWorkItem?
    /// Debounce QL content swap while arrow-key browsing (avoids size thrash).
    @State private var quickLookUpdateWork: DispatchWorkItem?

    // MARK: Pre-iter6 card geometry (adaptive height, ~140 width)
    private let cardSpacing: CGFloat = 8
    private let cornerRadius: CGFloat = 10
    private let outerHorizontalPadding: CGFloat = 10
    private let bottomSafe: CGFloat = 10
    private let topSafe: CGFloat = 4
    private let stripHorizontalInset: CGFloat = 2

    private var isQuickLookVisible: Bool {
        quickLookService.isQuickLookOpen
    }

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
            closeQuickLook()
            cancelPendingCopyClose()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardTabDidActivate)) { _ in
            activateClipboardSession()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed {
                closeQuickLook()
                cancelPendingCopyClose()
            } else if state == .open, coordinator.currentView == .clipboard {
                activateClipboardSession()
            }
        }
        .onChange(of: manager.selectedIndex) { _, _ in
            if isQuickLookVisible {
                // Debounce keyboard browse so QL reloads once per selection settle
                // and keeps the locked square (instant reload thrash broke scaling).
                scheduleQuickLookUpdateForSelection()
            }
        }
        .onChange(of: quickLookService.isQuickLookOpen) { wasOpen, isOpen in
            if wasOpen, !isOpen {
                cleanupTempPreviews()
                releaseNotchHold()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardRequestCloseQuickLook)) { _ in
            closeQuickLook()
        }
    }

    // MARK: - Metrics

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
                .font(.notch(.title3))
                .foregroundStyle(.secondary)
            Text(L("Clipboard is empty"))
                .font(.notch(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Copy + animation + delayed close

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
        closeQuickLook()

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

    // MARK: - System Quick Look (Space)

    private func toggleQuickLook() {
        if isQuickLookVisible {
            closeQuickLook()
            return
        }
        openQuickLookForSelection(immediate: true)
    }

    private func scheduleQuickLookUpdateForSelection() {
        quickLookUpdateWork?.cancel()
        let work = DispatchWorkItem {
            openQuickLookForSelection(immediate: false)
        }
        quickLookUpdateWork = work
        // Short delay coalesces rapid arrow key events into one reload.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func openQuickLookForSelection(immediate: Bool = true) {
        guard let item = manager.selectedItem else {
            closeQuickLook()
            return
        }
        let prepared = ClipboardQuickLookSupport.previewURLs(for: item)
        guard !prepared.urls.isEmpty else {
            // Keep panel open on empty item only if we have no replacement —
            // browsing past a non-previewable card shouldn't kill a good session
            // when user keeps moving; close only on explicit empty selection.
            if immediate {
                closeQuickLook()
            }
            return
        }
        let previousTemps = tempPreviewURLs
        // Keep previous temps until after show() so reload can still read them
        // if the new item reuses a path; then drop the rest.
        holdNotchOpen()
        quickLookService.show(urls: prepared.urls, selectFirst: true)
        tempPreviewURLs = prepared.temporary
        ClipboardQuickLookSupport.cleanupTemporary(
            previousTemps.filter { !prepared.temporary.contains($0) }
        )
    }

    private func closeQuickLook() {
        quickLookUpdateWork?.cancel()
        quickLookUpdateWork = nil
        quickLookService.hide()
        cleanupTempPreviews()
        releaseNotchHold()
    }

    private func cleanupTempPreviews() {
        ClipboardQuickLookSupport.cleanupTemporary(tempPreviewURLs)
        tempPreviewURLs = []
    }

    private func holdNotchOpen() {
        guard !holdingNotchOpenForQL else { return }
        holdingNotchOpenForQL = true
        SharingStateManager.shared.beginInteraction()
    }

    private func releaseNotchHold() {
        guard holdingNotchOpenForQL else { return }
        holdingNotchOpenForQL = false
        SharingStateManager.shared.endInteraction()
    }

    // MARK: - Keyboard lifecycle

    private func activateClipboardSession() {
        setupKeyboard()
        requestKeyWindow()
    }

    private func setupKeyboard() {
        let monitor = ClipboardKeyboardMonitor.shared
        monitor.startNotchSession()
        monitor.onMove = { dx, dy in
            manager.moveSelection(dx: dx, dy: dy)
        }
        monitor.onEnter = {
            if isQuickLookVisible {
                closeQuickLook()
            }
            guard let item = manager.selectedItem else { return }
            performAnimatedAction(item: item, index: manager.selectedIndex, paste: true)
        }
        monitor.onDelete = {
            manager.deleteSelected()
            if isQuickLookVisible {
                openQuickLookForSelection(immediate: true)
            }
        }
        monitor.onEscape = {
            if isQuickLookVisible {
                closeQuickLook()
            } else {
                vm.close()
            }
        }
        monitor.onSpace = {
            toggleQuickLook()
        }
        monitor.onCopy = {
            guard let item = manager.selectedItem else { return }
            performAnimatedAction(item: item, index: manager.selectedIndex, paste: false)
        }
        monitor.enableClipboardHandlers()
    }

    private func teardownKeyboard() {
        guard BoringViewCoordinator.shared.currentView != .clipboard else { return }
        ClipboardKeyboardMonitor.shared.disableClipboardHandlers()
        closeQuickLook()
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
    static let clipboardTabKeyFocus = Notification.Name("clipboardTabKeyFocus")
    static let clipboardTabDidActivate = Notification.Name("clipboardTabDidActivate")
    static let clipboardRequestCloseQuickLook = Notification.Name("clipboardRequestCloseQuickLook")
}
