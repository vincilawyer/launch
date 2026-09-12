import AppKit
import SwiftUI

enum LauncherChromeLayout {
    static let topBarHeight: CGFloat = 44
    static let searchWidth: CGFloat = 310
    static let settingsSpacing: CGFloat = 9
    static let settingsControlSize: CGFloat = 38
    /// Breathing room below the camera housing on notched displays. This is
    /// intentionally larger than the ordinary top inset so the search field's
    /// highlight and shadow never visually touch the notch.
    static let notchVerticalGap: CGFloat = 24
    static let gridTopGap: CGFloat = 22
    static let gridBottomGap: CGFloat = 18
    static let pageDotHitSize: CGFloat = 44
    static let pageDotsHeight = pageDotHitSize
    static let errorBannerGap: CGFloat = 14

    static var searchTrailingExtent: CGFloat {
        searchWidth / 2 + settingsSpacing + settingsControlSize
    }
}

/// A lightweight wallpaper backdrop that keeps Launch feeling like part of the
/// desktop instead of a separate utility window.
@MainActor
struct LauncherBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let wallpaper: NSImage?

    init(screen: NSScreen? = NSScreen.main) {
        wallpaper = LauncherWallpaperCache.shared.image(for: screen)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(reduceTransparency ? 1 : 1.025)
                    .blur(radius: reduceTransparency ? 0 : 9)
                    .accessibilityHidden(true)
            }

            if reduceTransparency {
                Color.black.opacity(0.72)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.58)
                Color.black.opacity(0.25)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.035),
                        Color.clear,
                        Color.black.opacity(0.28),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [.clear, .black.opacity(0.22)],
                    center: .center,
                    startRadius: 180,
                    endRadius: 900
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct LauncherTopBar: View {
    @Binding var searchText: String
    var searchIsFocused: FocusState<Bool>.Binding
    let isEditing: Bool
    let searchCenterOffset: CGFloat
    let showSettings: () -> Void
    let finishEditing: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isEditing {
                LauncherSearchField(text: $searchText, isFocused: searchIsFocused)
                    .allowsHitTesting(false)
                    .disabled(true)
                    .opacity(0.56)
                    .offset(x: searchCenterOffset)

                HStack {
                    Spacer()
                    Button(action: finishEditing) {
                        Text(LaunchText.value("完成", "Done"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 15)
                            .frame(height: 38)
                            .background(.regularMaterial, in: Capsule())
                            .overlay {
                                Capsule().stroke(.white.opacity(0.16), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 9, y: 3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(
                        LaunchText.value("退出应用编辑模式", "Exit application editing mode")
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            } else {
                HStack(spacing: LauncherChromeLayout.settingsSpacing) {
                    LauncherSearchField(text: $searchText, isFocused: searchIsFocused)

                    Button(action: showSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.84))
                            .frame(
                                width: LauncherChromeLayout.settingsControlSize,
                                height: LauncherChromeLayout.settingsControlSize
                            )
                            .background {
                                LauncherChromeSurface(
                                    shape: Circle(),
                                    isFocused: false
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(LaunchText.value("设置", "Settings"))
                    .accessibilityLabel(LaunchText.value("打开 Launch 设置", "Open Launch settings"))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
                // The search field, not the combined search/settings group,
                // owns the visual center. The gear remains immediately beside
                // it without pulling the field toward the left.
                .offset(
                    x: searchCenterOffset
                        + (LauncherChromeLayout.settingsSpacing
                            + LauncherChromeLayout.settingsControlSize) / 2
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: LauncherChromeLayout.topBarHeight,
            maxHeight: LauncherChromeLayout.topBarHeight
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isEditing)
    }
}

@MainActor
private final class LauncherWallpaperCache {
    static let shared = LauncherWallpaperCache()

    private var images: [URL: NSImage] = [:]
    private var failedURLs: Set<URL> = []

    func image(for screen: NSScreen?) -> NSImage? {
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }

        if let image = images[url] {
            return image
        }
        guard !failedURLs.contains(url) else { return nil }

        guard let image = NSImage(contentsOf: url) else {
            failedURLs.insert(url)
            return nil
        }
        images[url] = image
        return image
    }
}

struct LauncherSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(LaunchText.value("搜索应用", "Search"), text: $text)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LaunchText.value("清除搜索", "Clear search"))
            }
        }
        .font(.system(size: 17, weight: .medium))
        .padding(.horizontal, 14)
        .frame(width: LauncherChromeLayout.searchWidth, height: 40)
        .background {
            LauncherChromeSurface(
                shape: Capsule(),
                isFocused: isFocused.wrappedValue
            )
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isFocused.wrappedValue
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchText.value("搜索应用", "Search applications"))
    }
}

/// Search and settings are one control group, so they share the same material,
/// tint, border and elevation. Keeping the recipe here avoids the gear turning
/// into an opaque floating button next to a lighter search field.
private struct LauncherChromeSurface<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    let isFocused: Bool

    var body: some View {
        shape
            .fill(.black.opacity(0.18))
            .background(.thinMaterial, in: shape)
            .overlay {
                shape.stroke(
                    isFocused
                        ? .white.opacity(0.46)
                        : .white.opacity(0.13),
                    lineWidth: isFocused ? 1.5 : 1
                )
            }
            .shadow(
                color: isFocused ? .white.opacity(0.1) : .black.opacity(0.16),
                radius: isFocused ? 12 : 9,
                y: 3
            )
    }
}

struct LauncherPageDots: View {
    let pageCount: Int
    let currentPage: Int
    let selectPage: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(pageCount, 1), id: \.self) { page in
                Button {
                    selectPage(page)
                } label: {
                    ZStack {
                        Color.clear
                        Capsule()
                            .fill(page == currentPage ? .white : .white.opacity(0.36))
                            .frame(width: page == currentPage ? 20 : 8, height: 8)
                    }
                    .frame(
                        width: LauncherChromeLayout.pageDotHitSize,
                        height: LauncherChromeLayout.pageDotHitSize
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    LaunchText.value(
                        "第 \(page + 1) 页，共 \(max(pageCount, 1)) 页",
                        "Page \(page + 1) of \(max(pageCount, 1))"
                    )
                )
                .accessibilityAddTraits(page == currentPage ? .isSelected : [])
            }
        }
        .frame(height: LauncherChromeLayout.pageDotsHeight)
        .background {
            Capsule()
                .fill(.black.opacity(0.13))
                .frame(height: 24)
        }
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.08), lineWidth: 1)
                .frame(height: 24)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: currentPage)
    }
}

struct LauncherGlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        reduceTransparency
                            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                            : AnyShapeStyle(.regularMaterial)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(Color.black.opacity(0.09))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .white.opacity(0.055)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.32), radius: 32, y: 14)
    }
}
