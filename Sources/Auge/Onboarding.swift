import AppKit
import SwiftUI

// MARK: - First-run introduction

/// The first-run walkthrough. It mirrors the flow Peek presents: a dimmed
/// full-screen stage, one line at a time, a mock desktop that answers "how do
/// you reach the things you check so often?", then the practice step where you
/// hold the shortcut for real, the shortcut recorder, the settings tour, the
/// accessibility ask, and a finish card. ESC or Skip leaves at any point.

@MainActor
final class OnboardingController {
    static let shared = OnboardingController()

    private var window: NSWindow?
    private var state = OnboardingState()
    private var completion: (() -> Void)?

    private static let doneKey = "auge.onboarding.completed"

    var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.doneKey)
    }

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
        win.contentView = NSHostingView(rootView: OnboardingView(state: state, onFinish: { [weak self] in
            self?.finish()
        }))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.orderOut(nil)
        window = nil
        let done = completion
        completion = nil
        // The workspace lives in its own full-screen panel; it is kept out of
        // the way until the introduction is over.
        done?()
    }
}

/// Borderless windows refuse key status by default; the practice step needs it.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable {
        case question, windows, tabs, introducing, practice, shortcut, settings, access, done
    }
    @Published var step: Step = .question
    @Published var heldModifiers: Set<String> = []
    @Published var shortcut: String = "Fn"
    @Published var recording = false
    @Published var pressing = false
    @Published var muted = false
}

private struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            backdrop
            stage
            chrome
        }
        .ignoresSafeArea()
        .onAppear { start(); installKeyMonitor() }
        .contentShape(Rectangle())
        .onTapGesture {
            if state.step == .practice { advance() }
        }
    }

    // MARK: backdrop

    private var backdrop: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.42).opacity(0.55), .clear],
                           center: .init(x: 0.5, y: 0.35), startRadius: 40, endRadius: 900)
            LinearGradient(colors: [.black.opacity(0.75), .clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: stage

    @ViewBuilder private var stage: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            switch state.step {
            case .question:
                headline("How do you reach the things\nthat you check so often?")
            case .windows:
                headline("By switching through windows?")
                WindowSwitcherMock()
            case .tabs:
                headline("By switching through tabs?")
                TabStripMock()
            case .introducing:
                VStack(spacing: 10) {
                    Text("Introducing").font(.system(size: 26, weight: .regular)).foregroundStyle(.white.opacity(0.75))
                    Text("Auge.").font(.system(size: 64, weight: .semibold)).foregroundStyle(.white)
                    Text("See beyond the window.")
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.55))
                }
            case .practice:
                practiceStep
            case .shortcut:
                shortcutStep
            case .settings:
                headline("Set it up how you work.")
                SettingsMock()
            case .access:
                accessStep
            case .done:
                doneStep
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.45), value: state.step)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineSpacing(4)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: steps

    private var practiceStep: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(state.pressing ? 0.22 : 0.10))
                    .frame(width: 92, height: 92)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1))
                Text(state.shortcut).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text("Press and hold to peek")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            Text("Hold \(state.shortcut), or click below if you would rather try it later.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var shortcutStep: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .frame(width: 150, height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(red: 1, green: 0.42, blue: 0.36), lineWidth: 1.5))
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.42, blue: 0.36)).frame(width: 8, height: 8)
                    Text(state.recording ? "Recording…" : state.shortcut)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
            }
            Text("At least one modifier:  ⇧ Fn ⌃ ⌘")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            Text("Cancel recording").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var accessStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.85))
            Text("Accessibility access required to peek apps")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
            Text("Auge needs it to read the windows behind the overlay. Nothing leaves your Mac.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Continue") { advance() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Color(red: 0.36, green: 0.85, blue: 0.52))
            Text("You're all set.").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
            Text("Hold \(state.shortcut) anywhere to peek.")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
            Button("Start peeking") { onFinish() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
    }

    // MARK: chrome

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button { onFinish() } label: {
                    Text("Skip").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .opacity(state.step == .done ? 0 : 1)
                .padding(24)
            }
            Spacer()
            HStack {
                Button { state.muted.toggle() } label: {
                    Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(24)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                        Circle()
                            .fill(.white.opacity(step == state.step ? 0.85 : 0.18))
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(24)
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: flow

    /// Fn is Auge's real peek key, so the practice step listens for it; the
    /// recorder captures whichever modifiers the person presses.
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let mods = event.modifierFlags
            if state.step == .practice, mods.contains(.function) {
                state.pressing = true
                advance()
            }
            if state.step == .shortcut {
                var parts: [String] = []
                if mods.contains(.control) { parts.append("⌃") }
                if mods.contains(.option) { parts.append("⌥") }
                if mods.contains(.shift) { parts.append("⇧") }
                if mods.contains(.command) { parts.append("⌘") }
                if mods.contains(.function) { parts.append("Fn") }
                if !parts.isEmpty {
                    state.shortcut = parts.joined()
                    state.recording = false
                    advanceAfter(0.9)
                }
            }
            return event
        }
    }

    private func start() {
        advanceAfter(2.6)
    }

    private func advanceAfter(_ seconds: Double) {
        let current = state.step
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard state.step == current else { return }
            advance()
        }
    }

    private func advance() {
        guard let next = OnboardingState.Step(rawValue: state.step.rawValue + 1) else {
            onFinish(); return
        }
        withAnimation(.easeInOut(duration: 0.4)) { state.step = next }
        switch next {
        case .windows, .settings: advanceAfter(3.4)
        case .tabs: advanceAfter(3.4)
        case .introducing: advanceAfter(2.8)
        default: break
        }
    }
}

// MARK: - Mock stages

private struct WindowSwitcherMock: View {
    private let colours: [Color] = [.yellow, .orange, .gray, .gray, .black, .red, .orange, .blue, .purple, .blue, .teal]
    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.10))
                .frame(width: 560, height: 210)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { _ in Circle().fill(.white.opacity(0.25)).frame(width: 8, height: 8) }
                        Spacer()
                    }
                    .padding(10)
                }
            HStack(spacing: 8) {
                ForEach(Array(colours.enumerated()), id: \.offset) { index, colour in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(index == 6 ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(colour.opacity(0.85)))
                        .frame(width: 30, height: 30)
                        .overlay {
                            if index == 6 {
                                Image(systemName: "swatchpalette.fill")
                                    .font(.system(size: 13)).foregroundStyle(.black)
                            }
                        }
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
        }
    }
}

private struct TabStripMock: View {
    private let tints: [Color] = [.red, .blue, .green, .purple, .orange, .teal, .pink, .indigo, .yellow]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(tints.enumerated()), id: \.offset) { index, tint in
                    HStack(spacing: 5) {
                        Circle().fill(tint.opacity(0.9)).frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.25)).frame(width: 16, height: 7)
                    }
                    .padding(.horizontal, 6).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(index == 0 ? 0.18 : 0.10)))
                }
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(8)
            .background(.white.opacity(0.10))
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                HStack(spacing: 6) {
                    Circle().fill(.white.opacity(0.35)).frame(width: 9, height: 9)
                    Text("gmail.com").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.10)))
                Image(systemName: "square.on.square").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(8)
            Rectangle().fill(.white.opacity(0.05)).frame(height: 220)
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SettingsMock: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.18)).frame(width: 250, height: 150)
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.28)).frame(width: 280, height: 8)
                Text("Hold  ⌃⌥  Fn  to Peek")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 320).padding(26)
            Divider().overlay(.white.opacity(0.1))
            VStack(alignment: .leading, spacing: 14) {
                section("Behavior")
                row("Peek layout", "Freeform")
                row("Trigger mode", "Single tap")
                toggleRow("Sync widgets across displays")
                toggleRow("Pause media when hidden", on: true)
                section("System")
                toggleRow("Launch at login")
                toggleRow("Hide menu bar icon")
            }
            .padding(26)
            .frame(width: 380, alignment: .leading)
        }
        .frame(width: 700, height: 300)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func section(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }
    private func toggleRow(_ label: String, on: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer()
            Capsule().fill(on ? Color(red: 0.25, green: 0.55, blue: 1) : .white.opacity(0.18))
                .frame(width: 30, height: 17)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                }
        }
    }
}
