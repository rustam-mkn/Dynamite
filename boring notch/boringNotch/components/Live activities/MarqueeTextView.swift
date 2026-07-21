//
//  MarqueeTextView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import AppKit
import Defaults
import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    @Binding var text: String
    /// When nil, uses the current notch font for `textStyle`.
    let fontOverride: Font?
    let textStyle: Font.TextStyle
    let weight: Font.Weight
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat

    @Default(.notchFontFamily) private var notchFontFamily
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0

    init(
        _ text: Binding<String>,
        font: Font? = nil,
        nsFont: NSFont.TextStyle = .body,
        textStyle: Font.TextStyle? = nil,
        weight: Font.Weight = .regular,
        textColor: Color = .primary,
        backgroundColor: Color = .clear,
        minDuration: Double = 3.0,
        frameWidth: CGFloat = 200
    ) {
        _text = text
        self.fontOverride = font
        self.textStyle = textStyle ?? Self.mapTextStyle(nsFont)
        self.weight = weight
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
    }

    private var resolvedFont: Font {
        if let fontOverride { return fontOverride }
        // Re-resolve when notchFontFamily changes (@Default).
        _ = notchFontFamily
        return Font.notch(textStyle, weight: weight)
    }

    private var lineHeight: CGFloat {
        _ = notchFontFamily
        return NotchFont.lineHeight(for: textStyle, weight: weight)
    }

    private var needsScrolling: Bool {
        textSize.width > frameWidth
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 20) {
                    Text(text)
                    Text(text)
                        .opacity(needsScrolling ? 1 : 0)
                }
                .id("\(text)-\(notchFontFamily)")
                .font(resolvedFont)
                .foregroundColor(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: self.animate ? offset : 0)
                .animation(
                    self.animate
                        ? .linear(duration: Double(textSize.width / 30))
                            .delay(minDuration)
                            .repeatForever(autoreverses: false)
                        : .none,
                    value: self.animate
                )
                .background(backgroundColor)
                .modifier(MeasureSizeModifier())
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    self.textSize = CGSize(width: size.width / 2, height: lineHeight)
                    self.animate = false
                    self.offset = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        if needsScrolling {
                            self.animate = true
                            self.offset = -(textSize.width + 10)
                        }
                    }
                }
            }
            .frame(width: frameWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: max(textSize.height, lineHeight) * 1.3)
        .onChange(of: notchFontFamily) { _, _ in
            // Force re-measure after font family change.
            animate = false
            offset = 0
            textSize = .zero
        }
    }

    private static func mapTextStyle(_ ns: NSFont.TextStyle) -> Font.TextStyle {
        switch ns {
        case .largeTitle: return .largeTitle
        case .title1: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption1: return .caption
        case .caption2: return .caption2
        default: return .body
        }
    }
}
