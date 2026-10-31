import AppKit
import AVFoundation
import SwiftUI

// MARK: - First-run introduction

/// Auge's first-run film. Peek's walkthrough, beat for beat — the question, the
/// window and tab answers, "Introducing Auge.", the press-and-hold practice, the
/// shortcut recorder, the settings tour and the accessibility ask — staged the
/// way Apple would: one idea per frame, slow reveals, a cursor that leads the
/// eye, and nothing that moves without a reason.
///
/// ESC or Skip leaves at any point; completion is remembered, and the app menu
/// can replay it.

@MainActor
final class OnboardingController {
    static let shared = OnboardingController()

    private var window: NSWindow?
    private var state = OnboardingState()
    private var completion: (() -> Void)?

    private static let doneKey = "auge.onboarding.completed"

    var hasCompleted: Bool { UserDefaults.standard.bool(forKey: Self.doneKey) }

    func presentIfNeeded(onFinish: (() -> Void)? = nil) {
        guard !hasCompleted else { onFinish?(); return }
        present(force: false, onFinish: onFinish)
    }

    func present(force: Bool, onFinish: (() -> Void)? = nil) {
        if force { state = OnboardingState() }
        completion = onFinish
        guard window == nil else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let rect = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let win = OnboardingWindow(contentRect: rect, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .black
        win.isOpaque = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.contentView = NSHostingView(rootView: OnboardingView(state: state) { [weak self] in
            self?.finish()
        })
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func finish() {
        OnboardingAudio.shared.stop()
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.orderOut(nil)
        window = nil
        let done = completion
        completion = nil
        done?()
    }
}

/// Loop for the walkthrough. The track is optional: drop
/// `Resources/onboarding-music.m4a` (or .mp3) into the app and it is picked up
/// automatically, so the score can be swapped without touching code.
@MainActor
final class OnboardingAudio {
    static let shared = OnboardingAudio()
    private var player: AVAudioPlayer?

    private var url: URL? {
        for ext in ["m4a", "mp3", "aiff", "wav"] {
            if let url = Bundle.main.url(forResource: "onboarding-music", withExtension: ext) { return url }
        }
        return nil
    }

    /// Seconds of score to use, counted from the beginning of the file. Long
    /// sources (a stream rip, say) are cut here and faded out rather than
    /// looping forever.
    private let clip: TimeInterval = 110
    private let fadeOut: TimeInterval = 6

    func play() {
        guard player == nil, let url else { return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.numberOfLoops = 0
        p.volume = 0.5
        p.currentTime = 0
        p.play()
        player = p
        let clipLength = clip
        let fade = fadeOut
        let stop = min(clipLength, p.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, stop - fade)) { [weak p] in
            p?.setVolume(0, fadeDuration: fade)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + stop) { [weak p] in
            p?.stop()
        }
    }

    func setMuted(_ muted: Bool) {
        player?.setVolume(muted ? 0 : 0.5, fadeDuration: 0.35)
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable {
        case question, tabs, introducing, practice, done
    }
    @Published var step: Step = .question
    @Published var shortcut = "Fn"
    @Published var recording = false
    @Published var pressing = false
    @Published var muted = false

    /// Seconds each scene holds before the film moves on.
    func duration(of step: Step) -> Double? {
        switch step {
        case .question: 3.6
        case .tabs: 4.2
        case .introducing: 3.6
        default: nil
        }
    }
}

// MARK: - Root

private struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    let onFinish: () -> Void

    @StateObject private var ui = StageUI()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop(geo)
                scene(geo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                cursorLayer(geo)
                chrome
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) { ui.appeared = true }
            installKeyMonitor()
            OnboardingAudio.shared.play()
            run(.question)
        }
    }

    // MARK: backdrop

    private func backdrop(_ geo: GeometryProxy) -> some View {
        ZStack {
            Color.black
            // Slow drift, so nothing is ever perfectly still.
            RadialGradient(colors: [Color(red: 0.40, green: 0.33, blue: 0.52).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.5 + (ui.appeared ? 0.02 : -0.02), y: 0.34),
                           startRadius: 30, endRadius: geo.size.height * 0.85)
            RadialGradient(colors: [Color(red: 0.18, green: 0.42, blue: 0.62).opacity(0.35), .clear],
                           center: UnitPoint(x: ui.appeared ? 0.74 : 0.70, y: 0.62),
                           startRadius: 20, endRadius: geo.size.height * 0.6)
            LinearGradient(colors: [.black.opacity(0.9), .clear, .clear, .black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
            // Letterbox edges, very soft: the Apple-trailer look.
            VStack { Rectangle().fill(.black.opacity(0.55)).frame(height: geo.size.height * 0.06); Spacer()
                Rectangle().fill(.black.opacity(0.55)).frame(height: geo.size.height * 0.06) }
        }
        .scaleEffect(ui.appeared ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 40), value: ui.appeared)
        .ignoresSafeArea()
    }

    // MARK: scenes

    @ViewBuilder private func scene(_ geo: GeometryProxy) -> some View {
        ZStack {
            switch state.step {
            case .question:
                SceneText(lines: ["How do you reach the things", "that you check so often?"])
            case .tabs:
                VStack(spacing: 34) {
                    SceneText(lines: ["By switching through tabs?"])
                    TabStripMock()
                }
            case .introducing:
                introduceScene
            case .practice:
                practiceScene
            case .done:
                doneScene
            }
        }
        .id(state.step)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 1.02)),
            removal: .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.99))))
        .animation(.spring(response: 0.55, dampingFraction: 0.94), value: state.step)
    }

    private var introduceScene: some View {
        VStack(spacing: 18) {
            if let icon = AppBrand.icon {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .frame(width: 128, height: 128)
                    .shadow(color: Color(red: 0.45, green: 0.75, blue: 1).opacity(0.55), radius: 34)
                    .scaleEffect(ui.appeared ? 1 : 0.86)
                    .animation(.spring(response: 1.1, dampingFraction: 0.82), value: ui.appeared)
            }
            Text("Introducing")
                .font(.system(size: 17, weight: .medium))
                .tracking(3.2)
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            Text("Auge.")
                .font(.system(size: 68, weight: .semibold))
                .tracking(-1.5)
                .foregroundStyle(.white)
            Text("See Beyond.")
                .font(.system(size: 15, weight: .medium))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var practiceScene: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(state.pressing ? 0.24 : 0.08))
                    .frame(width: 104, height: 104)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    .shadow(color: .white.opacity(state.pressing ? 0.35 : 0), radius: 24)
                Text(state.shortcut)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            SceneText(lines: ["Press and hold to peek"], size: 26)
            Text("Hold the key, or click anywhere to carry on.")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.38))
        }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
    }

    private var shortcutScene: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .frame(width: 176, height: 68)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(red: 1, green: 0.42, blue: 0.36).opacity(0.9), lineWidth: 1.5))
                HStack(spacing: 9) {
                    Circle().fill(Color(red: 1, green: 0.42, blue: 0.36))
                        .frame(width: 8, height: 8)
                        .opacity(state.recording ? 1 : 0.25)
                    Text(state.recording ? "Recording…" : state.shortcut)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
            }
            SceneText(lines: ["At least one modifier:  ⇧ Fn ⌃ ⌘"], size: 26)
            Text("Cancel recording").font(.system(size: 12)).foregroundStyle(.white.opacity(0.32))
        }
    }

    private var accessScene: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.9))
            SceneText(lines: ["Accessibility access required", "to peek apps"], size: 26)
            Text("Auge reads the windows behind the overlay to know what you were looking at.\nNothing leaves your Mac.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center).lineSpacing(3)
            HStack(spacing: 14) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Continue") { advance() }.buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
    }

    private var doneScene: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48)).foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.52))
            SceneText(lines: ["You're all set."], size: 34)
            Text("Hold \(state.shortcut) anywhere to peek.")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
            Button("Start peeking") { onFinish() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .onAppear { ui.cursorVisible = false }
    }

    // MARK: cursor

    private func cursorLayer(_ geo: GeometryProxy) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .position(x: ui.cursor.x * geo.size.width, y: ui.cursor.y * geo.size.height)
            .opacity(ui.cursorVisible ? 1 : 0)
            .animation(.easeInOut(duration: 1.15), value: ui.cursor)
            .animation(.easeInOut(duration: 0.4), value: ui.cursorVisible)
    }

    // MARK: chrome

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button { onFinish() } label: {
                    Text("Skip").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(26)
                .opacity(ui.appeared && state.step != .done ? 1 : 0)
            }
            Spacer()
            HStack {
                Button {
                    state.muted.toggle()
                    OnboardingAudio.shared.setMuted(state.muted)
                } label: {
                    Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                        .padding(10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(26)
                Spacer()
                HStack(spacing: 8) {
                    ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                        Capsule()
                            .fill(.white.opacity(step == state.step ? 0.82 : 0.16))
                            .frame(width: step == state.step ? 16 : 5, height: 5)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: state.step)
                    }
                }
                .padding(26)
            }
        }
        .opacity(ui.appeared ? 1 : 0)
    }

    // MARK: direction

    private func run(_ step: OnboardingState.Step) {
        ui.cursorVisible = false
        moveCursor(for: step)
        guard let hold = state.duration(of: step) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            guard state.step == step else { return }
            advance()
        }
    }

    /// Each scene gets one cursor beat: it travels to the thing the copy is
    /// talking about, pauses, and leaves with the cut.
    private func moveCursor(for step: OnboardingState.Step) {
        switch step {
        case .question:
            ui.cursor = CGPoint(x: 0.5, y: 0.62)
        case .tabs:
            withAnimation(.easeInOut(duration: 1.15)) { ui.cursor = CGPoint(x: 0.40, y: 0.66) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { ui.cursorVisible = true }
        case .introducing:
            ui.cursorVisible = false
        default:
            ui.cursorVisible = false
        }
    }

    private func advance() {
        guard let next = OnboardingState.Step(rawValue: state.step.rawValue + 1) else {
            onFinish(); return
        }
        withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) { state.step = next }
        run(next)
    }

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let mods = event.modifierFlags
            if state.step == .practice, mods.contains(.function) {
                state.pressing = true
                advance()
            }
            return event
        }
    }
}

// MARK: - Pieces

/// One line of copy that arrives like a title card: blurred, slightly low, then
/// settles. Leaving is quicker than arriving, which is what makes a cut read.
private struct SceneText: View {
    var lines: [String]
    var size: CGFloat = 31
    @StateObject private var fade = FadeIn()

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: size, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .blur(radius: fade.shown ? 0 : 9)
                    .opacity(fade.shown ? 1 : 0)
                    .offset(y: fade.shown ? 0 : 16)
                    .animation(.spring(response: 0.95, dampingFraction: 0.88)
                        .delay(Double(index) * 0.10), value: fade.shown)
            }
        }
        .onAppear {
            DispatchQueue.main.async { fade.shown = true }
        }
    }
}

private struct WindowSwitcherMock: View {
    @StateObject private var fade = FadeIn()
    private let colours: [Color] = [.yellow, .orange, .gray, .gray, .black, .red, .orange, .blue, .purple, .blue, .teal]

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
                .frame(width: 560, height: 200)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.22)).frame(width: 8, height: 8) }
                        Spacer()
                    }.padding(11)
                }
            HStack(spacing: 9) {
                ForEach(Array(colours.enumerated()), id: \.offset) { index, colour in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(index == 6 ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(colour.opacity(0.8)))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if index == 6 {
                                Image(systemName: "swatchpalette.fill")
                                    .font(.system(size: 14)).foregroundStyle(.black)
                            }
                        }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.10)))
            .scaleEffect(fade.shown ? 1 : 0.94)
            .opacity(fade.shown ? 1 : 0)
        }
        .opacity(fade.shown ? 1 : 0)
        .offset(y: fade.shown ? 0 : 24)
        .animation(.spring(response: 1.0, dampingFraction: 0.86), value: fade.shown)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fade.shown = true } }
    }
}

private struct TabStripMock: View {
    @StateObject private var fade = FadeIn()
    private let tints: [Color] = [.red, .blue, .green, .purple, .orange, .teal, .pink, .indigo, .yellow]

    private var capturedChrome: NSImage? {
        guard let url = Bundle.main.url(forResource: "browser-tabs", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let chrome = capturedChrome {
                // Real macOS tab strip, lifted from the reference walkthrough.
                Image(nsImage: chrome)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                ForEach(Array(tints.enumerated()), id: \.offset) { index, tint in
                    HStack(spacing: 5) {
                        Circle().fill(tint.opacity(0.9)).frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.22)).frame(width: 16, height: 7)
                    }
                    .padding(.horizontal, 6).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(index == 0 ? 0.18 : 0.09)))
                }
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
                .padding(9)
                .background(.white.opacity(0.09))
            }
            HStack(spacing: 9) {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                HStack(spacing: 6) {
                    Circle().fill(.white.opacity(0.32)).frame(width: 9, height: 9)
                    Text("gmail.com").font(.system(size: 11)).foregroundStyle(.white.opacity(0.66))
                    Spacer()
                }
                .padding(.horizontal, 9).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.09)))
                Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(9)
            Rectangle().fill(.white.opacity(0.045)).frame(height: 210)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(fade.shown ? 1 : 0)
        .offset(y: fade.shown ? 0 : 24)
        .animation(.spring(response: 1.0, dampingFraction: 0.86), value: fade.shown)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fade.shown = true } }
    }
}

private struct SettingsMock: View {
    @StateObject private var ui = SettingsUI()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.16)).frame(width: 250, height: 150)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.26)).frame(width: 280, height: 8)
                Text("Hold  ⌃⌥  Fn  to Peek")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 320).padding(26)
            Divider().overlay(.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 15) {
                section("Behavior")
                row("Peek layout", "Freeform")
                row("Trigger mode", "Single tap")
                toggleRow("Sync widgets across displays")
                toggleRow("Pause media when hidden", on: ui.pauseOn)
                section("System").padding(.top, 4)
                toggleRow("Launch at login")
                toggleRow("Hide menu bar icon")
            }
            .padding(26)
            .frame(width: 380, alignment: .leading)
        }
        .frame(width: 700, height: 300)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .opacity(ui.shown ? 1 : 0)
        .offset(y: ui.shown ? 0 : 26)
        .animation(.spring(response: 1.05, dampingFraction: 0.88), value: ui.shown)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ui.shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { ui.pauseOn = true }
            }
        }
    }

    private func section(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.78))
            Spacer()
            Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
        }
    }
    private func toggleRow(_ label: String, on: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.78))
            Spacer()
            Capsule().fill(on ? Color(red: 0.25, green: 0.55, blue: 1) : .white.opacity(0.16))
                .frame(width: 30, height: 17)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                }
        }
    }
}


// MARK: - Local view state
// @State is a macro in this toolchain and the macro plugin is not available to
// this package, so tiny observable holders stand in for it.

private final class StageUI: ObservableObject {
    @Published var appeared = false
    @Published var cursor = CGPoint(x: 0.5, y: 0.62)
    @Published var cursorVisible = false
}

private final class FadeIn: ObservableObject {
    @Published var shown = false
}

private final class SettingsUI: ObservableObject {
    @Published var shown = false
    @Published var pauseOn = false
}
