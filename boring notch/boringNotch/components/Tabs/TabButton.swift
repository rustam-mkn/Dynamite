//
//  TabButton.swift
//  boringNotch
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: SpaceIconKind
    let selected: Bool
    /// 1-based ⌘N badge when command is held; nil to hide.
    var commandIndex: Int? = nil
    let onClick: () -> Void

    var body: some View {
        // Clawd + speedometer read larger than default SF Symbols in the tab strip.
        let iconSize: CGFloat = {
            switch icon {
            case .mascotRed, .mascotWhite: return 20
            case .gauge: return 17
            default: return 14
            }
        }()
        return Button(action: onClick) {
            ZStack(alignment: .top) {
                SpaceIconView(icon: icon, size: iconSize, selected: selected)
                    .padding(.horizontal, icon.prefersLargerTabSize ? 11 : 15)
                    .contentShape(Capsule())

                if let commandIndex, commandIndex >= 1, commandIndex <= 9 {
                    // Shortcut chrome stays on fixed system rounded — independent of notch font setting.
                    Text("⌘\(commandIndex)")
                        .font(NotchFont.shortcutBadge())
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.18))
                        )
                        .offset(y: -10)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.12), value: commandIndex != nil)
        .animation(.easeInOut(duration: 0.12), value: selected)
        .help(label)
    }
}
