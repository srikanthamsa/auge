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

    /// Hides the film itself so the live workspace can show through while the
    /// practice key is held.
    /// True while the film is the thing on screen.
    var isOnScreen: Bool { window?.isVisible == true }

    func setStageHidden(_ hidden: Bool) {
        window?.alphaValue = hidden ? 0 : 1
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
        window?.alphaValue = 1
        NotificationCenter.default.post(name: .augePreview, object: false)
        OnboardingAudio.shared.fadeOutAndStop(1.1)
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
        guard player == nil else { debugLog("audio: already playing"); return }
        guard let url else { debugLog("audio: no file in bundle"); return }
        debugLog("audio: loading \(url.lastPathComponent)")
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            start(p)
        } catch {
            debugLog("audio: failed \(error)")
        }
    }

    private func start(_ p: AVAudioPlayer) {
        debugLog("audio: duration \(p.duration)")
        p.numberOfLoops = 0
        p.volume = 0.5
        p.currentTime = 0
        debugLog("audio: play -> \(p.play())")
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

    /// Fades the score away instead of cutting it, then releases the player.
    func fadeOutAndStop(_ seconds: TimeInterval = 1.2) {
        guard let p = player else { return }
        player = nil
        p.setVolume(0, fadeDuration: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak p] in
            p?.stop()
        }
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
        case question, tabsQuestion, habitQuestion, choice, answer, introducing, promise, practice, letGo, done
    }
    @Published var step: Step = .question
    @Published var shortcut = "Fn"
    @Published var recording = false
    @Published var pressing = false
    @Published var muted = false

    enum Choice: String, CaseIterable {
        case windows, tabs, both
        var title: String {
            switch self {
            case .windows: "Windows"
            case .tabs: "Tabs"
            case .both: "Honestly, both"
            }
        }
        var symbol: String {
            switch self {
            case .windows: "macwindow.on.rectangle"
            case .tabs: "rectangle.on.rectangle"
            case .both: "square.stack.3d.up"
            }
        }
    }
    @Published var styleAnswer = 2
    @Published var tabAnswer = 2
    @Published var habitAnswer = 2
    @Published var holdStart: Date?
    @Published var keyOrigin: CGPoint?

    /// What the film says back, using the answer the person actually gave.
    var reply: String {
        switch styleAnswer {
        case 0: return "That's literally 71% of people."
        case 1: return "That's 96% of people. Practically everyone."
        default: return "That's literally 88% of people."
        }
    }

    /// One closing line, built from how they said they work.
    var closing: String {
        let time: String
        switch habitAnswer {
        case 0: time = "every few minutes"
        case 1: time = "every hour"
        default: time = "all day"
        }
        let tabs: String
        switch tabAnswer {
        case 0: tabs = "a few tabs"
        case 1: tabs = "too many tabs"
        default: tabs = "tabs you would rather not count"
        }
        return "You look \(time), through \(tabs)."
    }
    static let symbols = ["macwindow.on.rectangle", "rectangle.on.rectangle", "square.stack.3d.up"]

    /// Seconds each scene holds before the film moves on.
    func duration(of step: Step) -> Double? {
        switch step {
        case .question: 6.6
        case .tabsQuestion, .habitQuestion: nil
        case .answer: 4.6
        case .introducing: 4.8
        case .promise: 5.2
        case .letGo: 2.9
        default: nil          // choice, practice and done wait for the person
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
                if let start = state.holdStart, let origin = state.keyOrigin {
                    Bloom(start: start, origin: origin, stage: geo.size)
                        .allowsHitTesting(false)
                    BloomMark(start: start)
                        .allowsHitTesting(false)
                }
                cursorLayer(geo)
                chrome
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: "stage")
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
                SceneText(lines: ["How do you reach the things", "you check a hundred times a day?"], size: 54)
            case .tabsQuestion:
                ChoiceScene(prompt: "How many tabs are open right now?",
                            options: [AnswerOption(title: "A sensible few", subtitle: "I keep things organised.", symbol: "square.stack.3d.up"),
                                      AnswerOption(title: "Too many to count", subtitle: "It's getting out of hand.", symbol: "rectangle.stack"),
                                      AnswerOption(title: "Don't ask", subtitle: "We don't talk about that.", symbol: "hand.raised")],
                            pick: { state.tabAnswer = $0; advance() })
            case .habitQuestion:
                ChoiceScene(prompt: "And how often do you go looking?",
                            options: [AnswerOption(title: "Every few minutes", subtitle: "I'm constantly checking.", symbol: "clock.arrow.circlepath"),
                                      AnswerOption(title: "Every hour or so", subtitle: "Just checking in occasionally.", symbol: "clock"),
                                      AnswerOption(title: "All day, honestly", subtitle: "It's practically a reflex.", symbol: "sun.max")],
                            pick: { state.habitAnswer = $0; advance() })
            case .choice:
                ChoiceScene(prompt: "Which one is you?",
                            options: [AnswerOption(title: "Windows", subtitle: "One window, one task.", symbol: "macwindow"),
                                      AnswerOption(title: "Tabs", subtitle: "Everything in one place.", symbol: "rectangle.on.rectangle"),
                                      AnswerOption(title: "Honestly, both", subtitle: "Depends on the day.", symbol: "circle.grid.2x2")],
                            pick: { state.styleAnswer = $0; advance() })
            case .answer:
                SceneText(lines: [state.reply, "There is a faster way."], size: 52)
            case .introducing:
                introduceScene
            case .promise:
                SceneText(lines: ["Every window. Every tab.", "One gesture away."], size: 58)
            case .practice:
                practiceScene
            case .letGo:
                SceneText(lines: ["You let go.", "Don't worry, we all do at some point."], size: 50)
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
                    .frame(width: 116, height: 116)
                    .shadow(color: Color(red: 0.45, green: 0.75, blue: 1).opacity(0.55), radius: 34)
                    .scaleEffect(ui.appeared ? 1 : 0.86)
                    .animation(.spring(response: 1.1, dampingFraction: 0.82), value: ui.appeared)
            }
            Text("Introducing")
                .font(AppBrand.uiFont(15, weight: .medium))
                .tracking(5.5)
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            Text("AUGE")
                .font(AppBrand.displayFont(112))
                .tracking(6)
                .foregroundStyle(.white)
            Text("See Beyond.")
                .font(AppBrand.uiFont(15, weight: .medium))
                .tracking(2.4)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var practiceScene: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(state.pressing ? 0.30 : 0.16),
                                                  .white.opacity(state.pressing ? 0.16 : 0.06)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 116, height: 116)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .inset(by: 7)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .shadow(color: .white.opacity(state.pressing ? 0.30 : 0), radius: 26)
                Text(state.shortcut)
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.72)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { publish(keyFrame: g.frame(in: .named("stage"))) }
                    .onChange(of: g.frame(in: .named("stage"))) { _, f in publish(keyFrame: f) }
            })
            .opacity(state.holdStart == nil ? 1 : 0.25)
            SceneText(lines: ["Press and hold \(state.shortcut)"], size: 40)
            Text("Hold it, and keep holding.")
                .font(AppBrand.uiFont(13)).foregroundStyle(.white.opacity(0.38))
        }
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
            ZStack {
                Circle()
                    .fill(Color(red: 0.30, green: 0.95, blue: 0.55).opacity(0.45))
                    .frame(width: 84, height: 84)
                    .blur(radius: 26)
                Circle()
                    .fill(Color(red: 0.34, green: 0.99, blue: 0.60).opacity(0.35))
                    .frame(width: 56, height: 56)
                    .blur(radius: 12)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 0.26, green: 0.92, blue: 0.52))
                    .shadow(color: Color(red: 0.30, green: 1.0, blue: 0.58).opacity(0.9), radius: 14)
            }
            SceneText(lines: ["New ability unlocked.", "See Beyond."], size: 40)
            Text("Hold \(state.shortcut) anywhere to peek.")
                .font(AppBrand.uiFont(14)).foregroundStyle(.white.opacity(0.5))
            GlowButton(title: "See Beyond") { onFinish() }
                .padding(.top, 14)
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
        case .introducing:
            ui.cursorVisible = false
        default:
            ui.cursorVisible = false
        }
    }

    /// Remembers where the shortcut key is drawn, so the hold effect can start
    /// from exactly there.
    private func publish(keyFrame f: CGRect) {
        let p = CGPoint(x: f.midX, y: f.midY)
        if state.keyOrigin == nil || hypot((state.keyOrigin?.x ?? 0) - p.x, (state.keyOrigin?.y ?? 0) - p.y) > 1 {
            state.keyOrigin = p
        }
    }

    private func advance() {
        debugLog("[onb] advance from \(state.step) \(Thread.callStackSymbols.dropFirst().prefix(3).joined(separator: " | "))")
        guard let next = OnboardingState.Step(rawValue: state.step.rawValue + 1) else {
            onFinish(); return
        }
        withAnimation(.spring(response: 0.75, dampingFraction: 0.88)) { state.step = next }
        run(next)
    }

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            debugLog("[onb] mouseDown at \(event.locationInWindow) win=\(event.window?.title ?? "-") step=\(state.step)")
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let mods = event.modifierFlags
            if state.step == .practice {
                let held = mods.contains(.function)
                if held != state.pressing {
                    state.pressing = held
                    if held {
                        state.holdStart = Date()
                    } else {
                        let heldFor = state.holdStart.map { Date().timeIntervalSince($0) } ?? 0
                        state.holdStart = nil
                        // Releasing finishes the film: the bloom is the answer.
                        if heldFor > 0.4 { advance() }   // -> letGo
                    }
                }
            }
            return event
        }
    }
}

/// Held Fn: green fills the screen from the middle, unevenly, like something
/// spreading rather than an animation playing. Growth is driven by the hold
/// clock, so it is as slow as the person holds.
private struct Bloom: View {
    let start: Date
    /// The key's centre, in stage points — the stain begins behind the key
    /// itself, not at the middle of the screen.
    let origin: CGPoint
    let stage: CGSize

    private let green = Color(red: 0.16, green: 0.92, blue: 0.46)
    private let deep = Color(red: 0.03, green: 0.55, blue: 0.30)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let t = context.date.timeIntervalSince(start)
            let reach = 0.040 + sqrt(t) * 0.15
            let unit = min(stage.width, stage.height)
            ZStack {
                ForEach(0..<10, id: \.self) { i in
                    let phase = Double(i) * 2.3
                    let creep = sqrt(t) * (0.09 + Double(i % 4) * 0.03)
                    let breathe = 1 + sin(t * (0.42 + Double(i) * 0.06) + phase) * 0.17
                    let r = unit * (0.030 + reach * (0.55 + Double(i % 3) * 0.24)) * breathe
                    let dx = cos(phase * 2 + t * 0.16) * unit * (0.04 + creep)
                    let dy = sin(phase * 1.7 + t * 0.14) * unit * (0.04 + creep)
                    Circle()
                        .fill(RadialGradient(colors: [green, deep.opacity(0.85)],
                                             center: .center, startRadius: 0, endRadius: r))
                        .frame(width: r * 2, height: r * 2)
                        .blur(radius: unit * 0.10)
                        .position(x: origin.x + dx, y: origin.y + dy)
                }
            }
            .frame(width: stage.width, height: stage.height)
            .opacity(min(1, 0.2 + t * 0.9))
        }
        .allowsHitTesting(false)
    }
}

/// One beat where the person actually answers, so the film has a decision in it
/// instead of seven straight reads.
/// Slow blink, and a fade out after the last line.
private func labelOpacity(_ t: TimeInterval) -> Double {
    let inOpacity = min(1, max(0, (t - 0.55) / 0.7))
    let blink = 0.62 + 0.38 * (0.5 + 0.5 * cos(t * 2.0))
    let out = t > 4.4 ? max(0, 1 - (t - 4.4) / 0.9) : 1
    return inOpacity * blink * out
}

/// The mark rises over the spreading stain as it fills.
private struct BloomMark: View {
    let start: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSince(start)
            let shown = min(1, max(0, (t - 0.35) / 1.1))
            Group {
                if let mark = AppBrand.eyeMarkUntinted ?? AppBrand.eyeMark {
                    Image(nsImage: mark).resizable().interpolation(.high).scaledToFit()
                } else {
                    Text("Auge").font(AppBrand.displayFont(96)).foregroundStyle(.white)
                }
            }
            .frame(width: 260, height: 130)
            .shadow(color: .white.opacity(0.95), radius: 26)
            .shadow(color: .white.opacity(0.7), radius: 54)
            .opacity(shown)
            .scaleEffect(0.92 + shown * 0.08)
            .overlay(alignment: .bottom) {
                Text(t < 2.2 ? "Keep holding." : "Don't let go.")
                    .font(AppBrand.uiFont(19, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: 74)
                    .opacity(labelOpacity(t))
                    .animation(.easeInOut(duration: 0.35), value: t < 2.2)
            }
        }
    }
}

struct AnswerOption {
    let title: String
    let subtitle: String
    var symbol: String = "circle"
}

private struct ChoiceScene: View {
    let prompt: String
    let options: [AnswerOption]
    let pick: (Int) -> Void
    @StateObject private var fade = FadeIn()
    @StateObject private var gate = ChoiceGate()
    @StateObject private var nav = AnswerNav()

    var body: some View {
        VStack(spacing: 30) {
            SceneText(lines: [prompt], size: 54)
            HStack(spacing: 14) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    AnswerCard(option: option,
                               hovered: nav.hovered == index,
                               focused: nav.focused == index,
                               selected: nav.selected == index) {
                        choose(index)
                    }
                    .onHover { inside in
                        if inside { nav.hovered = index }
                        else if nav.hovered == index { nav.hovered = nil }
                    }
                    .opacity(fade.shown ? 1 : 0)
                    .offset(y: fade.shown ? 0 : 16)
                    .animation(.easeOut(duration: 0.45).delay(Double(index) * 0.05), value: fade.shown)
                }
            }
            Text("← → and Return, or click")
                .font(AppBrand.uiFont(12)).tracking(0.3)
                .foregroundStyle(.white.opacity(0.26))
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { fade.shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { gate.armed = true }
            nav.acted = { choose($0) }
            nav.begin(count: options.count)
        }
        .onDisappear { nav.end() }
    }

    private func choose(_ index: Int) {
        guard gate.armed, nav.selected == nil else { return }
        withAnimation(.easeOut(duration: 0.18)) { nav.selected = index }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { pick(index) }
    }
}

private final class ChoiceGate: ObservableObject {
    @Published var armed = false
}

/// Pointer and arrow-key state for a question, plus the keyboard monitor.
private final class AnswerNav: ObservableObject {
    @Published var hovered: Int?
    @Published var focused = 0
    @Published var selected: Int?
    private var monitor: Any?

    func begin(count: Int) {
        hovered = nil; focused = 0; selected = nil
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 123:                                   // left
                self.focused = max(0, self.focused - 1); return nil
            case 124:                                   // right
                self.focused = min(count - 1, self.focused + 1); return nil
            case 48, 36:                                // tab, return
                self.acted?(self.focused); return nil
            case 53:
                return event
            default:
                return event
            }
        }
        _ = monitor
    }

    /// Set by the scene so Return can commit the focused card.
    var acted: ((Int) -> Void)?

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A quiet physical surface: charcoal plate, hairline border, and a lean of a few
/// degrees at most. Selection tints it indigo and drops a small check in.
private struct AnswerCard: View {
    let option: AnswerOption
    let hovered: Bool
    let focused: Bool
    let selected: Bool
    let action: () -> Void

    private var fill: Color {
        if selected { return Color(red: 0.115, green: 0.118, blue: 0.175) }
        if hovered { return Color(red: 0.105, green: 0.110, blue: 0.145) }
        return Color(red: 0.090, green: 0.094, blue: 0.125)      // #171820
    }

    private var border: Color {
        if selected { return Color(red: 0.46, green: 0.48, blue: 0.95).opacity(0.55) }
        if focused  { return Color(red: 0.55, green: 0.60, blue: 1.0).opacity(0.45) }
        if hovered  { return .white.opacity(0.16) }
        return .white.opacity(0.09)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 7) {
                Image(systemName: option.symbol)
                    .font(.system(size: 19, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(selected ? 0.92 : 0.55))
                    .padding(.bottom, 2)
                Text(option.title)
                    .font(AppBrand.uiFont(16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                Text(option.subtitle)
                    .font(AppBrand.uiFont(12))
                    .foregroundStyle(.white.opacity(0.40))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color(red: 0.45, green: 0.47, blue: 0.95)))
                    .padding(9)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .frame(width: 204, height: 128)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .overlay(
            // the faintest lift off the background, no glow
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.035 : 0.012))
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .scaleEffect(hovered ? 1.01 : 1)
        .animation(.easeOut(duration: 0.18), value: hovered)
        .animation(.easeOut(duration: 0.22), value: selected)
        .animation(.easeOut(duration: 0.16), value: focused)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { action() }
    }
}

private struct GlowButton: View {
    let title: String
    let action: () -> Void

    private let inner = Color(red: 0.31, green: 0.85, blue: 1.0)
    private let outer = Color(red: 0.66, green: 0.95, blue: 1.0)
    private let blob1 = Color(red: 0.10, green: 0.85, blue: 1.0).opacity(0.85)
    private let blob2 = Color(red: 0.42, green: 0.30, blue: 1.0).opacity(0.9)
    private let blob3 = Color(red: 1.0, green: 0.28, blue: 0.72).opacity(0.85)
    private let blob4 = Color(red: 0.55, green: 1.0, blue: 0.45).opacity(0.7)

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle().fill(blob1).frame(width: 44, height: 44)
                        .blur(radius: 13)
                        .offset(x: sin(t * 0.9) * 44, y: cos(t * 0.7) * 22)
                    Circle().fill(blob2).frame(width: 46, height: 46)
                        .blur(radius: 15)
                        .offset(x: 46 + cos(t * 0.6) * 34, y: -14 + sin(t * 0.8) * 18)
                    Circle().fill(blob3).frame(width: 44, height: 44)
                        .blur(radius: 16)
                        .offset(x: -12 + sin(t * 0.5) * 30, y: 10 + cos(t * 1.1) * 16)
                    Circle().fill(blob4).frame(width: 40, height: 40)
                        .blur(radius: 12)
                        .offset(x: 58 + sin(t * 0.75) * 28, y: 8 + cos(t * 0.55) * 20)
                }
                .frame(width: 132, height: 46)
                .clipped()
            }
            .frame(width: 132, height: 46)
            .compositingGroup()
            .blendMode(.plusLighter)
            .background(
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(RadialGradient(colors: [inner, outer],
                                         center: .center, startRadius: 2, endRadius: 90))
                    .opacity(0.55)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear, .white.opacity(0.18)],
                                         startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            .shadow(color: Color(red: 0.34, green: 0.87, blue: 1).opacity(0.55), radius: 14)
            .overlay(
                Text(title)
                    .font(AppBrand.uiFont(15, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
            )
        }
        .buttonStyle(.plain)
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
                    .font(AppBrand.uiFont(size, weight: .semibold))
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
