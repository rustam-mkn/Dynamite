//
//  ClipboardCardView.swift
//  boringNotch — Pasta-style card (visual media: images + video previews)
//

import AppKit
import SwiftUI
import SwiftData

struct ClipboardCardView: View {
    let item: HistoryItem
    let isSelected: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cornerRadius: CGFloat
    let relativeTime: String
    /// Copy animation phase for this card (nil = idle).
    let copyPhase: ClipboardCopyPhase?
    let onTap: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onPaste: () -> Void
    let onCopyMenu: () -> Void

    private let inset: CGFloat = 8

    /// Pre-resolved static bits so body stays cheap while scrolling.
    private let previewText: String
    private let contentKind: ClipboardContentKind
    private let isPinned: Bool
    private let appIconImage: NSImage?
    private let fileIconImage: NSImage?
    private let fileDisplayName: String
    private let mediaCacheKey: String

    @State private var mediaThumbnail: NSImage?
    @State private var mediaLoadFailed = false

    init(
        item: HistoryItem,
        isSelected: Bool,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        cornerRadius: CGFloat,
        relativeTime: String,
        copyPhase: ClipboardCopyPhase?,
        onTap: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        onCopyMenu: @escaping () -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cornerRadius = cornerRadius
        self.relativeTime = relativeTime
        self.copyPhase = copyPhase
        self.onTap = onTap
        self.onPin = onPin
        self.onDelete = onDelete
        self.onPaste = onPaste
        self.onCopyMenu = onCopyMenu

        self.contentKind = item.contentKind
        self.isPinned = item.isPinned
        self.appIconImage = ClipboardIconCache.appIcon(bundleId: item.application)
        self.fileIconImage = ClipboardIconCache.fileIcon(path: item.fileURLs.first?.path)
        self.fileDisplayName = item.fileURLs.first?.lastPathComponent
            ?? (item.title.isEmpty ? L("File") : item.title)
        // Snapshot text once per identity change (caller recreates view when item content changes)
        if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.previewText = text
        } else {
            let preview = item.previewableText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                self.previewText = preview
            } else {
                let t = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                self.previewText = t.isEmpty ? L("(empty)") : t
            }
        }
        self.mediaCacheKey = "\(item.persistentModelID)_\(item.lastCopiedAt.timeIntervalSince1970)"
        // Seed from cache so re-scrolls don't flash a placeholder.
        let seedSize = CGSize(width: cardWidth * 2, height: cardHeight * 2)
        _mediaThumbnail = State(initialValue: ClipboardMediaThumbnailCache.cached(for: item, size: seedSize))
    }

    private var pressScale: CGFloat {
        switch copyPhase {
        case .fill: return 0.94
        case .flying: return 1.0
        case .none: return 1.0
        }
    }

    private var fillProgress: CGFloat {
        switch copyPhase {
        case .fill, .flying: return 1.0
        case .none: return 0.0
        }
    }

    private var isVisualMedia: Bool { contentKind.isVisualMedia }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if isVisualMedia {
                mediaBackground
            } else {
                bodyPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(inset)
                    .padding(.bottom, 18)
            }

            // Footer: app + pin + relative time
            HStack(spacing: 4) {
                appIcon
                    .frame(width: 14, height: 14)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.notch(size: 8))
                        .foregroundStyle(isVisualMedia ? .white.opacity(0.95) : .orange)
                }
                Spacer(minLength: 2)
                footerTrailing
            }
            .padding(.horizontal, inset)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // Green fill from center (selection accent)
            if copyPhase != nil {
                Circle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: max(cardWidth, cardHeight) * 1.6, height: max(cardWidth, cardHeight) * 1.6)
                    .scaleEffect(fillProgress)
                    .opacity(fillProgress > 0 ? 0.85 : 0)
                    .frame(width: cardWidth, height: cardHeight)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        // Shelf-like selection: accent fill when selected; subtle plate when idle (text needs contrast)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    isSelected || copyPhase != nil
                        ? Color.accentColor.opacity(0.15)
                        : Color.white.opacity(0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected || copyPhase != nil
                        ? Color.accentColor.opacity(0.8)
                        : Color.white.opacity(0.10),
                    lineWidth: isSelected || copyPhase != nil ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .scaleEffect(pressScale)
        // Flatten card into a single layer for smoother horizontal scroll (ProMotion)
        .compositingGroup()
        .drawingGroup(opaque: false)
        // Parent decides select vs copy: first tap selects, second tap on selection activates
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button(isPinned ? L("Unpin") : L("Pin"), action: onPin)
            Button(L("Copy"), action: onCopyMenu)
            Button(L("Paste"), action: onPaste)
            Divider()
            Button(L("Delete"), role: .destructive, action: onDelete)
        }
        .task(id: mediaCacheKey) {
            guard isVisualMedia else { return }
            await loadMediaThumbnail()
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var mediaBackground: some View {
        ZStack {
            if let mediaThumbnail {
                Image(nsImage: mediaThumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
            } else if mediaLoadFailed {
                mediaPlaceholder(systemName: contentKind.systemImage)
            } else {
                mediaPlaceholder(systemName: contentKind.systemImage, showProgress: true)
            }

            // Video: play badge so it is clearly distinct from a still image
            if contentKind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.notch(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    @ViewBuilder
    private func mediaPlaceholder(systemName: String, showProgress: Bool = false) -> some View {
        ZStack {
            Color.white.opacity(0.06)
            if showProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemName)
                    .font(.notch(.title2))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    private func loadMediaThumbnail() async {
        let size = CGSize(width: cardWidth * 2, height: cardHeight * 2)
        if let cached = ClipboardMediaThumbnailCache.cached(for: item, size: size) {
            mediaThumbnail = cached
            return
        }
        let image = await ClipboardMediaThumbnailCache.thumbnail(for: item, size: size)
        if Task.isCancelled { return }
        if let image {
            mediaThumbnail = image
            mediaLoadFailed = false
        } else {
            mediaLoadFailed = mediaThumbnail == nil
        }
    }

    // MARK: - Text / file body

    @ViewBuilder
    private var footerTrailing: some View {
        Text(relativeTime)
            .font(.notch(size: 9, weight: .medium))
            .foregroundStyle(isVisualMedia ? Color.white.opacity(0.9) : Color.secondary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var bodyPreview: some View {
        switch contentKind {
        case .image, .video:
            // Handled by mediaBackground
            EmptyView()
        case .file:
            VStack(alignment: .leading, spacing: 4) {
                if let fileIconImage {
                    Image(nsImage: fileIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                Text(fileDisplayName)
                    .font(.notch(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimitForHeight)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .link:
            Text(previewText)
                .font(.notch(size: 11))
                .foregroundStyle(Color.accentColor)
                .lineLimit(lineLimitForHeight)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .text:
            Text(previewText)
                .font(.notch(size: 11))
                .foregroundStyle(Color.primary.opacity(0.95))
                .lineLimit(lineLimitForHeight)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var lineLimitForHeight: Int {
        // ~14pt per line; leave footer band — pre-iter6 adaptive formula
        max(3, Int((cardHeight - 28) / 13))
    }

    @ViewBuilder
    private var appIcon: some View {
        if let appIconImage {
            Image(nsImage: appIconImage)
                .resizable()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .foregroundStyle(isVisualMedia ? .white.opacity(0.9) : .secondary)
        }
    }
}

// MARK: - Copy animation phase

enum ClipboardCopyPhase: Equatable {
    /// Press-scale + green fill run together (no staggered delay).
    case fill
    case flying
}
