import AppKit
import AuthenticationServices
import EventKit
import IOKit.ps
import CoreImage
import QuartzCore
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Combine
import SwiftUI
import WebKit

extension Notification.Name {
    /// Onboarding practice: show or hide the workspace without leaving the film.
    static let augePreview = Notification.Name("AugePreview")
    static let seeEscape = Notification.Name("SeeEscapePressed")
    static let seePeekOpened = Notification.Name("SeePeekOpened")
    static let seePeekClosed = Notification.Name("SeePeekClosed")
}

func debugLog(_ message: String) {
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/auge-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

// MARK: - Brand

/// The icon art, loaded from the app bundle. The menu bar gets the eye as a
/// template so macOS tints it; panels get the full squircle.
@MainActor
enum AppBrand {
    private static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    static var icon: NSImage? {
        image("AugeMark") ?? image("AppIcon-1024") ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "Auge")
    }

    /// Display face for the wordmark. Drop Courages.ttf (or .otf) into the app's
    /// Resources and it is registered at launch and used automatically.
    @MainActor
    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in items where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            debugLog("font \(url.lastPathComponent) registered=\(ok)")
        }
    }

    /// Google Sans when it is installed, otherwise the system face. Any font
    /// dropped into the app Resources is registered at launch, so this picks it
    /// up without another change.
    /// NSFont version of the display face, for AppKit surfaces.
    @MainActor
    static func displayFontNS(_ size: CGFloat) -> NSFont? {
        for name in ["COURAGESDEMORegular", "COURAGES DEMO", "CouragesDemo", "Courages"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return nil
    }

    @MainActor
    static func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Google Sans and Product Sans are proprietary and are not installed on
        // this Mac, so the closest shipping geometric face stands in until the
        // file is dropped into the bundle.
        for name in ["GoogleSans-Regular", "Google Sans", "GoogleSans",
                     "ProductSans-Regular", "Product Sans"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        let avenir: String
        switch weight {
        case .bold, .heavy, .black: avenir = "AvenirNext-Bold"
        case .semibold:             avenir = "AvenirNext-DemiBold"
        case .medium:               avenir = "AvenirNext-Medium"
        case .light, .thin, .ultraLight: avenir = "AvenirNext-Regular"
        default:                    avenir = "AvenirNext-Regular"
        }
        if let f = NSFont(name: avenir, size: size) { return Font(f) }
        return .system(size: size, weight: weight)
    }

    @MainActor
    static func displayFont(_ size: CGFloat, fallbackWeight: Font.Weight = .bold) -> Font {
        let candidates = ["COURAGESDEMORegular", "COURAGES DEMO", "CouragesDemo", "Courages"]
        for name in candidates where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: fallbackWeight)
    }

    /// The transparent eye, used as a template in the menu bar and as-is over
    /// the bloom.
    @MainActor
    static var eyeMark: NSImage? {
        if let cached = eyeMarkCache { return cached }
        guard let url = Bundle.main.url(forResource: "AugeEyeBar", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        // The art is used as drawn. Only saturation is lifted so the pale rim
        // separates from a light menu bar, and a soft dark shadow is dropped to
        // give the shape an edge against anything behind it.
        let height: CGFloat = 18
        let width = height * (src.size.width / max(src.size.height, 1))
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let box = NSRect(x: 0, y: 0, width: width, height: height)
        let art = Self.saturated(src) ?? src
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3.0
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        art.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = false
        eyeMarkCache = img
        return img
    }

    private static func saturated(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        let f = CIFilter(name: "CIColorControls")
        f?.setValue(ci, forKey: kCIInputImageKey)
        f?.setValue(0.0, forKey: kCIInputBrightnessKey)
        f?.setValue(1.7, forKey: kCIInputSaturationKey)
        f?.setValue(1.06, forKey: kCIInputContrastKey)
        guard let out = f?.outputImage else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: image.size)
    }

        private static func brightened(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        let f = CIFilter(name: "CIColorControls")
        f?.setValue(ci, forKey: kCIInputImageKey)
        f?.setValue(0.38, forKey: kCIInputBrightnessKey)
        f?.setValue(1.45, forKey: kCIInputSaturationKey)
        f?.setValue(1.05, forKey: kCIInputContrastKey)
        guard let out = f?.outputImage else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: image.size)
    }

    private static var eyeMarkCache: NSImage?

    /// The same eye, coloured: for the bloom, where the menu bar's tint would
    /// flatten it.
    @MainActor
    static var eyeMarkUntinted: NSImage? {
        if let cached = eyeColorCache { return cached }
        guard let url = Bundle.main.url(forResource: "AugeEye", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        eyeColorCache = src
        return src
    }

    private static var eyeColorCache: NSImage?

    static var menuMark: NSImage? {
        guard let mark = image("AugeMenuMark") ?? image("AugeMarkTemplate") else {
            return NSImage(systemSymbolName: "eye", accessibilityDescription: "Auge")
        }
        // The artwork is 2:1; keep its shape and sit it at menu-bar height.
        mark.isTemplate = true
        let height: CGFloat = 17
        mark.size = NSSize(width: height * mark.size.width / mark.size.height, height: height)
        return mark
    }
}

// MARK: - Entry point

@MainActor
@main
struct AugeApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AugeAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

// MARK: - App delegate (single status item)

@MainActor
private final class AugeAppDelegate: NSObject, NSApplicationDelegate {
    // Keep a single status item alive for the app lifetime.
    private var statusItem: NSStatusItem?
    private var panel: SeeOverlayPanel?
    private var previewVisible = false
    private var statusMenuMonitor: Any?
    private var escapeMonitor: Any?
    private let model = OverlayModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Fonts must be registered before anything draws: on first run the film
        // is presented below and needs the display face.
        AppBrand.registerBundledFonts()
        installMainMenu()
        // Destroy any ghost items left by previous launches in the same process.
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = AppBrand.eyeMark ?? AppBrand.menuMark
        // Template images take their tint from the button's appearance; without
        // this the eye rendered black on a dark menu bar.
        // Let the button follow the menu bar's own appearance; forcing one made
        // the template render dim.
        statusItem?.button?.appearance = nil
        // A menu on the item, not an action: AppKit then opens it for either
        // mouse button, which an action-based item does not do reliably.
        statusItem?.menu = makeStatusMenu()
        statusItem?.button?.toolTip = "See Beyond."
        // First run: the introduction owns the screen; the workspace follows it.
        if !OnboardingController.shared.hasCompleted {
            OnboardingController.shared.presentIfNeeded { [weak self] in self?.showPanel() }
            return
        }
        AppBrand.registerBundledFonts()
        PasskeyBridge.shared.start()
        observePreview()
        installStatusMenuMonitor()
        AdBlocker.shared.prepare()
        showPanel()
    }

    /// The status button's action only fires for left clicks on some builds, so
    /// right clicks are caught by a local monitor scoped to the button's window.
    private func installStatusMenuMonitor() {
        statusMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let button = self.statusItem?.button,
                  let window = button.window, event.window === window else { return event }
            self.showStatusMenu()
            return nil
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Workspace", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Play Introduction…", action: #selector(showIntroduction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Auge", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Auge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        makeStatusMenu().popUp(positioning: nil,
                               at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    private func observePreview() {
        NotificationCenter.default.addObserver(forName: .augePreview, object: nil, queue: .main) { [weak self] note in
            guard let self, let show = note.object as? Bool else { return }
            Task { @MainActor in
                if show { self.showPreview() } else { self.hidePreview() }
            }
        }
    }

    private func showPreview() {
        previewVisible = true
        showPanel()
    }

    private func hidePreview() {
        guard previewVisible else { return }
        previewVisible = false
        hidePanel()
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showStatusMenu()
            return
        }
        togglePanel()
    }

    @objc private func showIntroduction() {
        OnboardingController.shared.present(force: true)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        // The wordmark is set in the house face, like everywhere else it appears.
        let wordmark = NSTextField(labelWithString: "AUGE")
        wordmark.font = AppBrand.displayFontNS(24) ?? NSFont.systemFont(ofSize: 24, weight: .bold)
        wordmark.alignment = .center
        wordmark.frame = NSRect(x: 0, y: 0, width: 240, height: 34)
        alert.messageText = ""
        alert.accessoryView = wordmark
        alert.informativeText = "See Beyond.\n\nWebsites, files and widgets in a freeform workspace."
        if let icon = AppBrand.icon { alert.icon = icon }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// An accessory app has no menu bar, so the standard text key equivalents
    /// (⌘A, ⌘C, ⌘V, ⌘Z) never fire without an Edit menu to carry them.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Introduction", action: #selector(showIntroduction), keyEquivalent: "")
        appMenu.addItem(withTitle: "About Auge", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Auge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || panel?.isVisible != true { showPanel() }
        return true
    }

    @objc private func togglePanel() {
        panel?.isVisible == true ? hidePanel() : showPanel()
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main { panel.setFrame(screen.frame, display: true) }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        // Activation is asynchronous; without this the first click of a peek can
        // be spent activating the window instead of hitting a button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak panel] in
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKey()
        }
        if OnboardingController.shared.hasCompleted { VisionTour.shared.startIfNeeded() }
        NotificationCenter.default.post(name: .seePeekOpened, object: nil)
        if previousApp == nil { previousApp = NSWorkspace.shared.frontmostApplication }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        startFunctionKeyWatch()
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                NotificationCenter.default.post(name: .seeEscape, object: nil)
                return nil
            }
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        model.pinned = false
        for site in model.websites { site.setPicking(false) }
        PointerPump.site?.clearHover()
        NotificationCenter.default.post(name: .seePeekClosed, object: nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                // Hand focus back to whatever the peek covered.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                    self.previousApp = nil
                } else if let previous = self.previousApp, previous.processIdentifier != getpid() {
                    previous.activate(options: [])
                    self.previousApp = nil
                }
            }
        })
    }

    private var previousApp: NSRunningApplication?
    private var fnGlobal: Any?
    private var fnLocal: Any?
    private var fnHeld = false
    private var openedByFn = false

    /// Hold Fn anywhere to peek; release it and See disappears. The menu bar eye
    /// still works for a click-to-open peek.
    private func startFunctionKeyWatch() {
        guard fnGlobal == nil else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let down = event.modifierFlags.contains(.function)
            Task { @MainActor in self.functionKeyChanged(down) }
        }
        fnGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        fnLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
    }

    @MainActor
    private func functionKeyChanged(_ down: Bool) {
        guard down != fnHeld else { return }
        fnHeld = down
        FnState.held = down

        // The introduction owns Fn while it is on screen: the practice beat is
        // using it for the bloom, and the workspace must not open over it.
        if OnboardingController.shared.isOnScreen { return }

        if down {
            openedByFn = true
            if panel?.isVisible != true {
                debugLog("fn held -> peek")
                showPanel()
            }
        } else if openedByFn {
            openedByFn = false
            // Clicking anywhere in the peek (or the pin button) keeps it open;
            // releasing Fn only dismisses an untouched peek.
            guard !model.pinned else {
                debugLog("fn released -> stays (pinned)")
                return
            }
            debugLog("fn released -> hide")
            hidePanel()
        }
    }

    private func makePanel() -> SeeOverlayPanel {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = SeeOverlayPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: SeeOverlay(onClose: { [weak self] in self?.hidePanel() }, model: model).overlay { VisionTourOverlay() })
        return panel
    }

}

private final class SeeOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Wraps a hosting view in a plain container so the window keeps the frame we
/// give it instead of shrinking to the content's fitting size.
private final class HostContainerView<Content: View>: NSView {
    private let host: NSHostingView<Content>
    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

// Borderless panels need this for a click to register before the app is active.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Workspace right-click & drag-to-create monitor

@MainActor
private struct WorkspaceInteractionMonitor: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void
    let onDismiss: (CGPoint) -> Void
    let isSurfaceAt: (CGPoint) -> Bool
    let contextMenuFrame: () -> CGRect?
    let onTouch: (CGPoint) -> Void         // raise whatever was touched
    let onZapAt: (CGPoint) -> Bool         // true when a zapping surface took the click
    let onDragCreating: (CGRect) -> Void   // live rect while drawing
    let onDragCreated: (CGRect) -> Void    // final rect on mouseUp

    func makeNSView(context: Context) -> WorkspaceInteractionView {
        let v = WorkspaceInteractionView()
        update(v); v.installMonitorIfNeeded()
        return v
    }
    func updateNSView(_ v: WorkspaceInteractionView, context: Context) { update(v) }
    private func update(_ v: WorkspaceInteractionView) {
        v.onRightClick = onRightClick
        v.onDismiss = onDismiss
        v.isSurfaceAt = isSurfaceAt
        v.contextMenuFrame = contextMenuFrame
        v.onTouch = onTouch
        v.onZapAt = onZapAt
        v.onDragCreating = onDragCreating
        v.onDragCreated = onDragCreated
    }
}

@MainActor
final class WorkspaceInteractionView: NSView {
    static var monitorInstalled = false
    var onRightClick: ((CGPoint) -> Void)?
    var onDismiss: ((CGPoint) -> Void)?
    var isSurfaceAt: ((CGPoint) -> Bool)?
    var contextMenuFrame: (() -> CGRect?)?
    var onTouch: ((CGPoint) -> Void)?
    var onZapAt: ((CGPoint) -> Bool)?
    var onDragCreating: ((CGRect) -> Void)?
    var onDragCreated: ((CGRect) -> Void)?

    private var eventMonitor: Any?
    private var dragStart: CGPoint?
    private var swallowMouseUp = false
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint = CGPoint(x: -1000, y: -1000)

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installMonitorIfNeeded() }

    func installMonitorIfNeeded() {
        guard eventMonitor == nil, window != nil else { return }
        guard !WorkspaceInteractionView.monitorInstalled else { return }
        WorkspaceInteractionView.monitorInstalled = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            let belongsHere = event.window == nil || event.window === self.window
            if !belongsHere, event.type != .rightMouseDown { return event }
            // Always resolve the point from the live pointer position: a click
            // that arrives while See is inactive (or from an event with no
            // window) carries no trustworthy location of its own.
            guard let window = self.window else { return event }
            let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            switch event.type {
            case .rightMouseDown:
                debugLog("right down at \(point)")
                self.onTouch?(point)
                self.onRightClick?(point); return nil
            case .leftMouseDown:
                // The panel re-delivers a single physical click while it becomes
                // key; the second copy would toggle a control back.
                let t = event.timestamp
                if t - self.lastDownTime < 0.05, hypot(point.x - self.lastDownPoint.x, point.y - self.lastDownPoint.y) < 4 {
                    self.lastDownTime = 0
                    return nil
                }
                self.lastDownTime = t; self.lastDownPoint = point
                self.onTouch?(point)
                if MenuHover.shared.invoke(at: point) {
                    // The action ran on mouse-down; swallow its mouse-up so a
                    // control that appears under the pointer cannot act on the
                    // release (that is what closed the config panel instantly).
                    self.swallowMouseUp = true
                    return nil
                }
                debugLog("left down at \(point) key=\(self.window?.isKeyWindow == true) active=\(NSApp.isActive) menuFrame=\(String(describing: self.contextMenuFrame?())) inMenu=\(self.contextMenuFrame?().map { $0.contains(point) } ?? false)")
                if self.onZapAt?(point) == true { return nil }
                if let menuFrame = self.contextMenuFrame?(), !menuFrame.contains(point) { self.onDismiss?(point) }
                else if self.contextMenuFrame?() == nil { self.onDismiss?(point) }
                // Only start drag-to-create on empty workspace
                if self.isSurfaceAt?(point) == false { self.dragStart = point }
                return event
            case .leftMouseDragged:
                if let start = self.dragStart {
                    let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                     width: abs(point.x - start.x), height: abs(point.y - start.y))
                    if rect.width > 40 || rect.height > 40 { self.onDragCreating?(rect) }
                }
                return event
            case .leftMouseUp:
                if self.swallowMouseUp { self.swallowMouseUp = false; return nil }
                if let start = self.dragStart {
                    let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                     width: abs(point.x - start.x), height: abs(point.y - start.y))
                    self.dragStart = nil
                    if rect.width > 80 && rect.height > 60 { self.onDragCreated?(rect) }
                    else { self.onDragCreating?(CGRect.null) }
                }
                return event
            default: return event
            }
        }
    }

    isolated deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
}

// MARK: - Model

/// Anchors a menu's top-left corner at the click point, clamped to the screen.
private func menuOrigin(for point: CGPoint, size: CGSize, menu: CGSize) -> CGPoint {
    CGPoint(x: min(max(point.x, 10), max(10, size.width - menu.width - 10)),
            y: min(max(point.y, 10), max(10, size.height - menu.height - 10)))
}

private struct WorkspaceMenuSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue(); if next != .zero { value = next }
    }
}

private struct SurfaceMenuSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue(); if next != .zero { value = next }
    }
}

@MainActor
private final class MenuSizes: ObservableObject {
    @Published var workspace: CGSize = MenuMetrics.workspace
    @Published var surface: CGSize = MenuMetrics.surface
}

/// Reports a view's laid-out size so a menu can be placed by its real top-left
/// corner instead of an assumed height.
private struct MenuSizeReader: ViewModifier {
    let onChange: (CGSize) -> Void
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear
                .onAppear { DispatchQueue.main.async { onChange(proxy.size) } }
                .onChange(of: proxy.size) { _, size in DispatchQueue.main.async { onChange(size) } }
        })
    }
}

private enum MenuMetrics {
    static let workspace = CGSize(width: 256, height: 268)
    static let surface = CGSize(width: 232, height: 172)
}

private struct SurfaceMenuTarget: Identifiable {
    let id = UUID()
    let site: WebsiteSurface?
    let widget: NativeWidgetSurface?
    let point: CGPoint
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var websites: [WebsiteSurface] = []
    @Published var widgets: [NativeWidgetSurface] = []
    @Published var focusedID: UUID?
    @Published var hasPlacedInitialSite = false
    @Published var contextMenuPoint: CGPoint? {
        didSet { if contextMenuPoint == nil { MenuHover.shared.clear("ws:") } }
    }
    /// When true the peek stays open after Fn is released.
    @Published var pinned = false
    @Published var showingWidgetPicker = false
    @Published var pendingPickerForRect: CGRect? = nil   // for drag-to-create
    @Published var pickerCategory: WidgetPickerCategory = .websites
    @Published var pickerSearch = ""
    @Published var workspacePanel: WorkspacePanel?
    @Published var backgroundStyle: WorkspaceBackgroundStyle = .midnight
    @Published var backgroundGlow: Double = 0.9
    @Published var backgroundDim: Double = 0.80
    @Published var confirmingRemoveAll = false
    @Published var dragCreatingRect: CGRect = .null      // live drawing rect
    @Published var surfaceMenu: SurfaceMenuTarget? {
        didSet { if surfaceMenu == nil { MenuHover.shared.clear("sf:") } }
    }
    /// The surface whose settings panel is open. Opening it slides that surface
    /// to the left so the panel can sit on the right without covering it (the
    /// Peek arrangement); closing puts it back where it was.
    @Published var configuring: WebsiteSurface? {
        didSet {
            guard configuring !== oldValue else { return }
            if let previous = oldValue { restoreConfigured(previous) }
            if let site = configuring { makeRoomForConfigure(site) }
        }
    }

    /// Workspace size, kept current by the overlay so the layout maths above has
    /// something to work with.
    var workspaceSize: CGSize = CGSize(width: 1710, height: 1107)
    private var configureOrigins: [UUID: CGPoint] = [:]
    private var configureSizes: [UUID: CGSize] = [:]

    /// Settings panel geometry, shared with the slot maths so the surface always
    /// lands right next to the panel instead of across a half-screen gap.
    static func configurePanelFrame(in size: CGSize) -> CGRect {
        let width = min(460, max(320, size.width * 0.3))
        return CGRect(x: size.width - 44 - width, y: 0, width: width, height: size.height)
    }

    private func configureSlot(for site: WebsiteSurface) -> (center: CGPoint, size: CGSize) {
        let size = workspaceSize
        let usable = CGRect(x: 34, y: 92, width: max(240, size.width - 68), height: max(240, size.height - 168))
        let panel = Self.configurePanelFrame(in: size)
        let gap: CGFloat = 34
        let region = CGRect(x: usable.minX, y: usable.minY,
                            width: max(240, panel.minX - gap - usable.minX),
                            height: usable.height)
        var w = site.size.width, h = site.size.height
        let fit = min(1, min((region.width - 24) / max(1, w), (region.height - 24) / max(1, h)))
        w *= fit; h *= fit
        // Sit against the panel, not in the middle of the leftover space.
        return (CGPoint(x: region.maxX - 12 - w / 2, y: region.midY), CGSize(width: w, height: h))
    }

    private func makeRoomForConfigure(_ site: WebsiteSurface) {
        let slot = configureSlot(for: site)
        if configureOrigins[site.id] == nil {
            configureOrigins[site.id] = site.center
            configureSizes[site.id] = site.size
        }
        // The page must be live, not the still image that covered it while a
        // menu was open, or hiding and restoring elements would not show.
        site.exitChromeMode()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            site.size = slot.size
            site.center = slot.center
        }
    }

    private func restoreConfigured(_ site: WebsiteSurface) {
        guard let origin = configureOrigins[site.id] else { return }
        let size = configureSizes[site.id] ?? site.size
        configureOrigins[site.id] = nil; configureSizes[site.id] = nil
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            site.size = size
            site.center = origin
        }
    }

    var chromeVisible: Bool {
        showingWidgetPicker || contextMenuPoint != nil || surfaceMenu != nil
            || configuring != nil || workspacePanel != nil || confirmingRemoveAll
    }

    private var lastSavedJSON = ""
    private var autosaveStarted = false

    init() {
        restore()
        startAutosave()
    }

    // MARK: Persistence

    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(websites: websites.map(\.snapshot),
                          widgets: widgets.map(\.snapshot),
                          background: backgroundStyle.rawValue,
                          glow: backgroundGlow, dim: backgroundDim)
    }

    private func restore() {
        guard let saved = WorkspaceStore.load() else { return }
        backgroundStyle = WorkspaceBackgroundStyle(rawValue: saved.background) ?? .midnight
        backgroundGlow = saved.glow ?? 0.9
        backgroundDim = saved.dim ?? 0.80
        websites = saved.websites.map { item in
            WebsiteSurface(address: item.address, title: item.title,
                           center: CGPoint(x: item.x, y: item.y), id: item.id,
                           size: CGSize(width: item.w, height: item.h),
                           config: item.config, scrollY: item.scrollY)
        }
        widgets = saved.widgets.compactMap { item in
            guard let kind = NativeWidgetKind(rawValue: item.kind) else { return nil }
            let surface = NativeWidgetSurface(kind: kind, center: CGPoint(x: item.x, y: item.y), id: item.id,
                                              size: CGSize(width: item.w, height: item.h), note: item.note)
            surface.sizeLocked = item.sizeLocked ?? false
            return surface
        }
        if !websites.isEmpty || !widgets.isEmpty { hasPlacedInitialSite = true }
        adoptStackingOrder()
        debugLog("restored \(websites.count) sites, \(widgets.count) widgets")
    }

    private func startAutosave() {
        guard !autosaveStarted else { return }
        autosaveStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.saveIfNeeded()
            }
        }
    }

    func saveIfNeeded() {
        let snapshot = snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot), let json = String(data: data, encoding: .utf8) else { return }
        guard json != lastSavedJSON else { return }
        if WorkspaceStore.save(snapshot) { lastSavedJSON = json }
    }

    func saveNow() { lastSavedJSON = ""; saveIfNeeded() }

    // MARK: Surface hit testing

    func website(at point: CGPoint) -> WebsiteSurface? {
        websites.filter { site in
            CGRect(x: site.center.x - site.size.width / 2, y: site.center.y - site.size.height / 2,
                   width: site.size.width, height: site.size.height).contains(point)
        }.max(by: { $0.z < $1.z }) ?? websites.last { site in
            CGRect(x: site.center.x - site.size.width / 2, y: site.center.y - site.size.height / 2,
                   width: site.size.width, height: site.size.height).contains(point)
        }
    }

    func widget(at point: CGPoint) -> NativeWidgetSurface? {
        widgets.filter { widget in
            CGRect(x: widget.center.x - widget.size.width / 2, y: widget.center.y - widget.size.height / 2,
                   width: widget.size.width, height: widget.size.height).contains(point)
        }.max(by: { $0.z < $1.z }) ?? widgets.last { widget in
            CGRect(x: widget.center.x - widget.size.width / 2, y: widget.center.y - widget.size.height / 2,
                   width: widget.size.width, height: widget.size.height).contains(point)
        }
    }

    func openSurfaceMenu(at point: CGPoint) {
        debugLog("openSurfaceMenu at \(point) site=\(website(at: point) != nil) widget=\(widget(at: point) != nil)")
        if let site = website(at: point) {
            surfaceMenu = SurfaceMenuTarget(site: site, widget: nil, point: point)
        } else if let widget = widget(at: point) {
            surfaceMenu = SurfaceMenuTarget(site: nil, widget: widget, point: point)
        }
    }

    // MARK: Stacking

    private var zTop: Double = 10

    func adoptStackingOrder() {
        for (i, site) in websites.enumerated() { site.z = Double(i + 1) }
        zTop = Double(max(websites.count, widgets.count) + 10)
        for (i, widget) in widgets.enumerated() { widget.z = Double(i + 1) }
    }

    func bringToFront(_ site: WebsiteSurface) {
        zTop += 1
        site.z = zTop
        compressStack()
    }

    func bringToFront(_ widget: NativeWidgetSurface) {
        zTop += 1
        widget.z = zTop
        compressStack()
    }

    /// Keeps every surface below the See chrome (which sits at 50+).
    private func compressStack() {
        guard zTop > 40 else { return }
        var order: [(z: Double, apply: (Double) -> Void)] =
            websites.map { site in (site.z, { site.z = $0 }) } +
            widgets.map { widget in (widget.z, { widget.z = $0 }) }
        order.sort { $0.z < $1.z }
        for (i, entry) in order.enumerated() { entry.apply(Double(i + 1)) }
        zTop = Double(order.count + 2)
    }

    /// Whoever the pointer touches last sits on top.
    func raiseSurface(at point: CGPoint) {
        if let site = website(at: point) {
            model_focus(site)
            bringToFront(site)
        } else if let widget = widget(at: point) {
            bringToFront(widget)
        }
    }

    private func model_focus(_ site: WebsiteSurface) {
        focusedID = site.id
    }

    // MARK: Smart placement: find an empty region
    func emptyCenter(for size: CGSize, in workspace: CGSize) -> CGPoint {
        // Keep surfaces clear of the menu bar and the See chrome.
        let usable = CGRect(x: 36, y: 100,
                            width: max(160, workspace.width - 72),
                            height: max(160, workspace.height - 174))

        func clamp(_ p: CGPoint) -> CGPoint {
            let halfW = min(size.width, usable.width) / 2
            let halfH = min(size.height, usable.height) / 2
            return CGPoint(x: min(max(p.x, usable.minX + halfW), usable.maxX - halfW),
                           y: min(max(p.y, usable.minY + halfH), usable.maxY - halfH))
        }

        // Nothing placed yet: the first surface belongs in the middle.
        if websites.isEmpty && widgets.isEmpty {
            return clamp(CGPoint(x: workspace.width / 2, y: workspace.height / 2 + 24))
        }

        let candidates: [CGPoint] = stride(from: 0.12, through: 0.88, by: 0.19).flatMap { fx -> [CGPoint] in
            stride(from: 0.12, through: 0.88, by: 0.19).map { fy in
                CGPoint(x: usable.minX + usable.width * fx,
                        y: usable.minY + usable.height * fy)
            }
        }
        // Prefer no overlap at all, then the spot farthest from other surfaces.
        func score(_ p: CGPoint) -> (CGFloat, CGFloat) {
            (-overlapArea(centeredAt: p, size: size), minDistance(p, size: size))
        }
        let best = candidates.max { a, b in
            let sa = score(a), sb = score(b)
            return sa.0 == sb.0 ? sa.1 < sb.1 : sa.0 < sb.0
        }
        return clamp(best ?? CGPoint(x: workspace.width * 0.5, y: workspace.height * 0.5))
    }

    private func overlapArea(centeredAt point: CGPoint, size: CGSize) -> CGFloat {
        let rect = CGRect(x: point.x - size.width/2, y: point.y - size.height/2,
                          width: size.width, height: size.height)
        var area: CGFloat = 0
        for site in websites {
            let other = CGRect(x: site.center.x - site.size.width/2, y: site.center.y - site.size.height/2,
                               width: site.size.width, height: site.size.height)
            area += rect.intersection(other).isNull ? 0 : rect.intersection(other).width * rect.intersection(other).height
        }
        for widget in widgets {
            let other = CGRect(x: widget.center.x - widget.size.width/2, y: widget.center.y - widget.size.height/2,
                               width: widget.size.width, height: widget.size.height)
            area += rect.intersection(other).isNull ? 0 : rect.intersection(other).width * rect.intersection(other).height
        }
        return area
    }

    private func minDistance(_ point: CGPoint, size: CGSize) -> CGFloat {
        let all: [CGPoint] = websites.map(\.center) + widgets.map(\.center)
        guard !all.isEmpty else { return .infinity }
        return all.map { hypot($0.x - point.x, $0.y - point.y) }.min() ?? .infinity
    }

    func addWebsite(url: String, title: String? = nil, center: CGPoint, size: CGSize? = nil) {
        let site = WebsiteSurface(address: url, title: title ?? Self.hostName(url), center: center)
        if let size { site.size = size }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { websites.append(site) }
        focusedID = site.id
    }

    func remove(_ site: WebsiteSurface) {
        let center = site.center
        withAnimation(.easeInOut(duration: 0.22)) { websites.removeAll { $0.id == site.id } }
        focusedID = websites.last?.id
        offerUndo(at: center, inserted: websites.count) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                self.websites.insert(site, at: min(self.undoInsertIndex, self.websites.count))
            }
            // Restored to the top of the stack: without this it came back
            // underneath whatever had been raised since, so it looked like the
            // undo had done nothing until the next click raised the surface.
            self.bringToFront(site)
            self.focusedID = site.id
        }
    }

    func addWidget(_ kind: NativeWidgetKind, center: CGPoint, size: CGSize? = nil) {
        let widget = NativeWidgetSurface(kind: kind, center: center)
        if let size { widget.size = size }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { widgets.append(widget) }
    }

    func removeWidget(_ widget: NativeWidgetSurface) {
        let center = widget.center
        let index = widgets.firstIndex(where: { $0.id == widget.id }) ?? widgets.count
        withAnimation(.easeInOut(duration: 0.22)) { widgets.removeAll { $0.id == widget.id } }
        offerUndo(at: center, inserted: index) { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                self.widgets.insert(widget, at: min(self.undoInsertIndex, self.widgets.count))
            }
            self.bringToFront(widget)
        }
    }

    // MARK: Undo a removal

    struct UndoOffer: Identifiable {
        let id = UUID()
        let center: CGPoint
        let perform: () -> Void
    }

    @Published var undoOffer: UndoOffer?

    @Published var toast: String?
    private var toastTimer: Timer?

    func showToast(_ message: String) {
        toast = message
        debugLog("toast: \(message)")
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.toast = nil }
        }
    }
    private var undoInsertIndex = 0
    private var undoTimer: Timer?

    private func offerUndo(at center: CGPoint, inserted index: Int, restore: @escaping () -> Void) {
        undoInsertIndex = index
        undoTimer?.invalidate()
        undoTimer = nil
        undoOffer = UndoOffer(center: center, perform: restore)
        debugLog("undo offer shown")
    }

    func expireUndo(_ id: UUID) {
        if undoOffer?.id == id { undoOffer = nil }
    }

    func performUndo() {
        guard let offer = undoOffer else { return }
        undoOffer = nil
        undoTimer?.invalidate()
        offer.perform()
    }

    /// Packs every surface into the free workspace without overlaps: large
    /// surfaces claim space first, each one takes the tightest free rectangle
    /// that still fits it, and the whole arrangement is centred afterwards.
    func tidyLayout(in size: CGSize, style: LayoutStyle = .grid) {
        struct Item {
            let isWidget: Bool
            let index: Int
            let locked: Bool
            let minSize: CGSize
            let natural: CGSize
        }
        struct Placement { let index: Int; let frame: CGRect }

        let gap: CGFloat = 18
        let siteMin = websiteMinSize
        var items: [Item] = websites.enumerated().map {
            Item(isWidget: false, index: $0.offset, locked: $0.element.sizeLocked,
                 minSize: siteMin, natural: $0.element.size)
        }
        items += widgets.enumerated().map {
            Item(isWidget: true, index: $0.offset, locked: $0.element.sizeLocked,
                 minSize: $0.element.kind.minSize, natural: $0.element.size)
        }
        guard !items.isEmpty else { return }

        let usable = CGRect(x: 34, y: 92,
                            width: max(240, size.width - 68),
                            height: max(240, size.height - 168))

        /// Guillotine packer. Each surface either takes its own size, or — when
        /// the space left cannot hold it — shrinks just enough to fit, never below
        /// the minimum it needs to render. Locked surfaces never shrink; if one
        /// cannot be placed at all, the whole attempt fails and nothing moves.
        func pack(order: [Int], scale: CGFloat) -> (placements: [Placement], shrink: CGFloat)? {
            var free = [usable]
            var result: [Placement] = []
            var totalShrink: CGFloat = 0

            for i in order {
                let item = items[i]
                let natural = CGSize(width: min(item.natural.width * scale, usable.width),
                                     height: min(item.natural.height * scale, usable.height))
                var size = item.locked
                    ? natural
                    : CGSize(width: max(item.minSize.width, natural.width),
                             height: max(item.minSize.height, natural.height))

                // Best short-side fit: the tightest rectangle the surface still
                // fits in, which keeps big holes intact for big surfaces.
                func bestFit(for need: CGSize) -> Int? {
                    var best: Int?
                    var bestShort = CGFloat.greatestFiniteMagnitude
                    var bestLong = CGFloat.greatestFiniteMagnitude
                    for (index, rect) in free.enumerated() {
                        guard rect.width >= need.width, rect.height >= need.height else { continue }
                        let short = min(rect.width - need.width, rect.height - need.height)
                        let long = max(rect.width - need.width, rect.height - need.height)
                        if short < bestShort || (short == bestShort && long < bestLong) {
                            bestShort = short; bestLong = long; best = index
                        }
                    }
                    return best
                }

                var slotIndex = bestFit(for: size)
                if slotIndex == nil {
                    guard !item.locked else { return nil }
                    // Shrink into the roomiest rectangle that still fits the
                    // minimum, keeping the aspect ratio.
                    let candidates = free.enumerated()
                        .filter { $0.element.width >= item.minSize.width && $0.element.height >= item.minSize.height }
                        .sorted { $0.element.width * $0.element.height > $1.element.width * $1.element.height }
                    guard let candidate = candidates.first else { return nil }
                    let rect = candidate.element
                    let fit = min(rect.width / size.width, rect.height / size.height)
                    size = CGSize(width: max(item.minSize.width, min(rect.width, size.width * fit)),
                                  height: max(item.minSize.height, min(rect.height, size.height * fit)))
                    totalShrink += max(0, natural.width * natural.height - size.width * size.height)
                    slotIndex = candidate.offset
                }
                guard let index = slotIndex else { return nil }

                let slot = free.remove(at: index)
                let frame = CGRect(x: slot.minX, y: slot.minY, width: size.width, height: size.height)
                result.append(Placement(index: i, frame: frame))

                let spareW = slot.width - size.width - gap
                let spareH = slot.height - size.height - gap
                // Guillotine split: keep BOTH leftovers, orienting the cut along
                // the shorter axis so neither strip becomes a useless sliver.
                if spareW >= 190 && spareH >= 150 {
                    if spareW < spareH {
                        free.append(CGRect(x: slot.minX + size.width + gap, y: slot.minY,
                                           width: spareW, height: size.height))
                        free.append(CGRect(x: slot.minX, y: slot.minY + size.height + gap,
                                           width: slot.width, height: spareH))
                    } else {
                        free.append(CGRect(x: slot.minX + size.width + gap, y: slot.minY,
                                           width: spareW, height: slot.height))
                        free.append(CGRect(x: slot.minX, y: slot.minY + size.height + gap,
                                           width: size.width, height: spareH))
                    }
                } else if spareW >= 190 {
                    free.append(CGRect(x: slot.minX + size.width + gap, y: slot.minY,
                                       width: spareW, height: slot.height))
                } else if spareH >= 150 {
                    free.append(CGRect(x: slot.minX, y: slot.minY + size.height + gap,
                                       width: slot.width, height: spareH))
                }
            }
            return (result, totalShrink)
        }

        // Try a few natural orders and keep the one that needs the least
        // shrinking — big surfaces first, then height, then width.
        let indices = Array(items.indices)
        func area(_ i: Int) -> CGFloat { items[i].natural.width * items[i].natural.height }
        let orders: [[Int]] = [
            indices.sorted { area($0) > area($1) },
            indices.sorted { items[$0].natural.height > items[$1].natural.height },
            indices.sorted { items[$0].natural.width > items[$1].natural.width },
            indices.sorted { max(items[$0].natural.width, items[$0].natural.height)
                          > max(items[$1].natural.width, items[$1].natural.height) }
        ]
        // Everything at its own size first, then progressively tighter. A global
        // scale keeps the proportions between surfaces, so the layout still reads
        // as one composition instead of a pile of random sizes.
        let scales: [CGFloat] = [1.0, 0.95, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6]

        var best: (placements: [Placement], shrink: CGFloat)?
        search: for scale in scales {
            for order in orders {
                guard let attempt = pack(order: order, scale: scale) else { continue }
                if best == nil || attempt.shrink < best!.shrink - 1 { best = attempt }
                if best!.shrink < 1 { break search }
            }
        }

        guard var placements = best?.placements else {
            showToast("Not enough room — unlock a few sizes or remove a surface")
            debugLog("tidy skipped: no packing fits \(items.count) surfaces")
            return
        }

        // Centre the packed block inside the workspace.
        if style == .grid, let union = placements.map({ $0.frame }).reduce(nil, { (acc: CGRect?, frame: CGRect) in
            acc.map { $0.union(frame) } ?? frame
        }) {
            let dx = max(0, (usable.width - union.width) / 2 - (union.minX - usable.minX))
            let dy = max(0, (usable.height - union.height) / 2 - (union.minY - usable.minY))
            placements = placements.map { Placement(index: $0.index, frame: $0.frame.offsetBy(dx: dx, dy: dy)) }
        }

        debugLog("tidy packed \(placements.count)/\(items.count) shrink=\(Int(best?.shrink ?? 0))")

        for (step, entry) in placements.enumerated() {
            let item = items[entry.index]
            let frame = entry.frame
            let delay = Double(step) * 0.035
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    if item.isWidget {
                        guard item.index < self.widgets.count else { return }
                        let widget = self.widgets[item.index]
                        widget.size = frame.size
                        widget.center = CGPoint(x: frame.midX, y: frame.midY)
                    } else {
                        guard item.index < self.websites.count else { return }
                        let site = self.websites[item.index]
                        site.size = frame.size
                        site.center = CGPoint(x: frame.midX, y: frame.midY)
                    }
                    self.objectWillChange.send()
                }
            }
        }
    }

    func addWebsiteFromPicker(_ address: String, in size: CGSize, rect: CGRect? = nil) {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let resolved = SiteCatalog.resolve(value) { value = resolved }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value) else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        // Websites, and files: a local PDF or HTML page drops in the same way.
        guard ["http", "https", "file"].contains(scheme) else { return }
        guard scheme == "file" ? url.isFileURL : url.host != nil else { return }
        let center: CGPoint
        let surfaceSize: CGSize
        if let r = rect, r.width > 24, r.height > 24 {
            // The user drew this rectangle: use it exactly, only nudging it back
            // inside the workspace if it runs past an edge.
            let clamped = r.intersection(CGRect(origin: .zero, size: size))
            let frame = clamped.isNull ? r : clamped
            center = CGPoint(x: frame.midX, y: frame.midY)
            surfaceSize = CGSize(width: max(80, frame.width), height: max(60, frame.height))
        } else {
            center = emptyCenter(for: CGSize(width: min(1060, size.width - 180), height: min(790, size.height - 150)), in: size)
            surfaceSize = CGSize(width: min(1060, size.width - 180), height: min(790, size.height - 150))
        }
        addWebsite(url: url.absoluteString, center: center, size: surfaceSize)
        debugLog("added site center=\(center) size=\(surfaceSize) workspace=\(size)")
        pickerSearch = ""; showingWidgetPicker = false; contextMenuPoint = nil; pendingPickerForRect = nil; dragCreatingRect = .null
    }

    func addNativeWidget(_ kind: NativeWidgetKind, in size: CGSize, rect: CGRect? = nil) {
        let center: CGPoint
        var explicitSize: CGSize?
        if let r = rect, r.width > 24, r.height > 24 {
            // Drawn rectangles are honoured exactly — the user decides how small
            // a widget may be.
            let clamped = r.intersection(CGRect(origin: .zero, size: size))
            let frame = clamped.isNull ? r : clamped
            center = CGPoint(x: frame.midX, y: frame.midY)
            explicitSize = CGSize(width: max(80, frame.width), height: max(60, frame.height))
        } else {
            center = emptyCenter(for: kind.size, in: size)
        }
        addWidget(kind, center: center, size: explicitSize)
        showingWidgetPicker = false; contextMenuPoint = nil; pendingPickerForRect = nil; dragCreatingRect = .null
    }

    static func hostName(_ address: String) -> String {
        URL(string: address)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Website"
    }
}

// MARK: - Data types

private enum NativeWidgetKind: String, CaseIterable, Identifiable {
    case clock = "Clock", calendar = "Calendar", note = "Quick Note"
    case timer = "Timer", battery = "Battery", system = "System"
    case weather = "Weather", worldClock = "World Clock"
    case todo = "To-Do", countdown = "Countdown", cricket = "Cricket"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .calendar: "calendar"
        case .note: "note.text"
        case .timer: "timer"
        case .battery: "battery.75percent"
        case .system: "cpu"
        case .weather: "cloud.sun"
        case .worldClock: "globe"
        case .todo: "checklist"
        case .countdown: "hourglass"
        case .cricket: "figure.cricket"
        }
    }

    var size: CGSize {
        switch self {
        case .clock: CGSize(width: 300, height: 220)
        case .calendar: CGSize(width: 340, height: 340)
        case .note: CGSize(width: 340, height: 280)
        case .timer: CGSize(width: 300, height: 220)
        case .battery: CGSize(width: 300, height: 200)
        case .system: CGSize(width: 340, height: 260)
        case .weather: CGSize(width: 320, height: 240)
        case .worldClock: CGSize(width: 300, height: 240)
        case .todo: CGSize(width: 320, height: 280)
        case .countdown: CGSize(width: 300, height: 220)
        case .cricket: CGSize(width: 360, height: 260)
        }
    }

    /// Deliberately marginal: half of what the content ideally needs, so the
    /// user is free to shrink a widget far down and manage it themselves.
    var minSize: CGSize {
        switch self {
        case .clock: CGSize(width: 70, height: 55)
        case .calendar: CGSize(width: 90, height: 80)
        case .note: CGSize(width: 70, height: 55)
        case .timer: CGSize(width: 70, height: 55)
        case .battery: CGSize(width: 65, height: 50)
        case .system: CGSize(width: 80, height: 60)
        case .weather: CGSize(width: 80, height: 65)
        case .worldClock: CGSize(width: 75, height: 60)
        case .todo: CGSize(width: 80, height: 65)
        case .countdown: CGSize(width: 75, height: 60)
        case .cricket: CGSize(width: 95, height: 70)
        }
    }

    var summary: String {
        switch self {
        case .clock: "Time and date"
        case .calendar: "This month"
        case .note: "A scratchpad"
        case .timer: "Countdown"
        case .battery: "Charge and power"
        case .system: "CPU and memory"
        case .weather: "Local forecast"
        case .worldClock: "Time around the world"
        case .todo: "A short checklist"
        case .countdown: "Days until a date"
        case .cricket: "Live scores"
        }
    }
}

private enum WidgetPickerCategory: String, CaseIterable, Identifiable {
    case websites = "Websites", widgets = "Visions"
    var id: String { rawValue }
}

private enum LayoutStyle { case grid, cascade }
private enum WorkspacePanel { case background, settings }
private enum WorkspaceBackgroundStyle: String, CaseIterable, Identifiable {
    case midnight, charcoal, plum, ocean, forest, ember, rose, daylight, aurora, graphite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: "Midnight"
        case .charcoal: "Charcoal"
        case .graphite: "Graphite"
        case .plum: "Plum"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .ember: "Ember"
        case .rose: "Rose"
        case .daylight: "Daylight"
        case .aurora: "Aurora"
        }
    }

    /// Colour used for the centre bloom of the workspace.
    var tint: Color {
        switch self {
        case .midnight: Color(red: 0.35, green: 0.36, blue: 0.95).opacity(0.14)
        case .charcoal: Color(white: 0.55).opacity(0.10)
        case .graphite: Color(red: 0.42, green: 0.46, blue: 0.52).opacity(0.11)
        case .plum: Color(red: 0.65, green: 0.30, blue: 0.85).opacity(0.15)
        case .ocean: Color(red: 0.20, green: 0.62, blue: 0.92).opacity(0.15)
        case .forest: Color(red: 0.24, green: 0.76, blue: 0.52).opacity(0.14)
        case .ember: Color(red: 0.96, green: 0.45, blue: 0.18).opacity(0.15)
        case .rose: Color(red: 0.96, green: 0.35, blue: 0.55).opacity(0.15)
        case .daylight: Color(red: 0.92, green: 0.88, blue: 0.78).opacity(0.12)
        case .aurora: Color(red: 0.30, green: 0.85, blue: 0.80).opacity(0.15)
        }
    }

    /// Second bloom, offset to the lower right, for a richer backdrop.
    var secondary: Color {
        switch self {
        case .midnight: Color(red: 0.20, green: 0.60, blue: 0.95).opacity(0.10)
        case .charcoal: Color(red: 0.45, green: 0.30, blue: 0.55).opacity(0.07)
        case .graphite: Color(red: 0.30, green: 0.55, blue: 0.60).opacity(0.08)
        case .plum: Color(red: 0.95, green: 0.35, blue: 0.65).opacity(0.10)
        case .ocean: Color(red: 0.15, green: 0.90, blue: 0.85).opacity(0.09)
        case .forest: Color(red: 0.85, green: 0.90, blue: 0.35).opacity(0.07)
        case .ember: Color(red: 0.85, green: 0.20, blue: 0.35).opacity(0.10)
        case .rose: Color(red: 0.99, green: 0.70, blue: 0.30).opacity(0.10)
        case .daylight: Color(red: 0.70, green: 0.85, blue: 1.00).opacity(0.11)
        case .aurora: Color(red: 0.40, green: 0.55, blue: 0.98).opacity(0.11)
        }
    }

    /// Backing dimmer behind the blooms.
    var base: Color {
        switch self {
        case .daylight: Color(white: 0.10)
        default: Color.black
        }
    }
}

// MARK: - Per-widget configuration

private enum WebsiteUserAgent: String, CaseIterable, Codable, Identifiable {
    case chromeMac, safariMac, iPhone, iPad
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chromeMac: "Chrome (macOS)"
        case .safariMac: "Safari (macOS)"
        case .iPhone: "Safari (iPhone)"
        case .iPad: "Safari (iPad)"
        }
    }
    var string: String {
        switch self {
        case .chromeMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        case .safariMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        case .iPhone:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
        case .iPad:
            "Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
        }
    }
}

private struct WebsiteConfig: Codable, Equatable {
    var autoRefresh: Double = 0            // seconds, 0 = off
    var rememberScroll = true
    var userAgent: WebsiteUserAgent = .safariMac
    var hiddenSelectors: [String] = []
    var darkMode = false
    /// CSS the user writes for this surface; injected on every load.
    var customCode: String = ""

    init() {}

    /// Tolerant decoding: new fields must never make an older workspace file
    /// unreadable, which would silently start the user with an empty workspace.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoRefresh = try c.decodeIfPresent(Double.self, forKey: .autoRefresh) ?? 0
        rememberScroll = try c.decodeIfPresent(Bool.self, forKey: .rememberScroll) ?? true
        userAgent = try c.decodeIfPresent(WebsiteUserAgent.self, forKey: .userAgent) ?? .safariMac
        hiddenSelectors = try c.decodeIfPresent([String].self, forKey: .hiddenSelectors) ?? []
        darkMode = try c.decodeIfPresent(Bool.self, forKey: .darkMode) ?? false
        customCode = try c.decodeIfPresent(String.self, forKey: .customCode) ?? ""
    }
}

private enum AutoRefreshOption: Double, CaseIterable, Identifiable {
    case off = 0
    case everyPeek = -1
    case minutes30 = 1800
    case minutes15 = 900
    case minutes5 = 300
    case minute = 60
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .everyPeek: "Every peek"
        case .minutes30: "Every 30 minutes"
        case .minutes15: "Every 15 minutes"
        case .minutes5: "Every 5 minutes"
        case .minute: "Every 1 minute"
        }
    }
    /// Short form for the collapsed control.
    var shortTitle: String {
        switch self {
        case .off: "Off"
        case .everyPeek: "Every peek"
        case .minutes30: "Every 30 min"
        case .minutes15: "Every 15 min"
        case .minutes5: "Every 5 min"
        case .minute: "Every 1 min"
        }
    }
}

// MARK: - Persistence

private struct WebsiteSnapshot: Codable {
    var id: UUID
    var address: String
    var title: String
    var x: Double, y: Double, w: Double, h: Double
    var config: WebsiteConfig
    var scrollY: Double
    var sizeLocked: Bool?
}

private struct WidgetSnapshot: Codable {
    var id: UUID
    var kind: String
    var x: Double, y: Double, w: Double, h: Double
    var note: String
    var sizeLocked: Bool?
}

private struct WorkspaceSnapshot: Codable {
    var version = 1
    var websites: [WebsiteSnapshot] = []
    var widgets: [WidgetSnapshot] = []
    var background: String = WorkspaceBackgroundStyle.midnight.rawValue
    var glow: Double? = 0.9
    var dim: Double? = 0.80
}

private enum WorkspaceStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("Auge", isDirectory: true)
        // Rebranded from See: bring the old workspace across the first time.
        let legacy = base.appendingPathComponent("See", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let items = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for item in items {
                    try? FileManager.default.copyItem(at: item, to: dir.appendingPathComponent(item.lastPathComponent))
                }
            }
        }
        return dir
    }
    static var fileURL: URL { directory.appendingPathComponent("workspace.json") }

    static func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: WorkspaceSnapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            return true
        } catch {
            debugLog("workspace save failed \(error)")
            return false
        }
    }
}

// MARK: - Injected page scripts

/// A small offline catalogue so a name is enough to add a site.
struct SiteSuggestion: Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { url }
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

enum SiteCatalog {
    static let entries: [(String, String, String)] = [
        ("YouTube", "https://www.youtube.com", "video videos music watch"),
        ("X", "https://x.com", "twitter tweets"),
        ("Reddit", "https://www.reddit.com", "forum communities"),
        ("Google", "https://www.google.com", "search"),
        ("Gmail", "https://mail.google.com", "email inbox"),
        ("Google Calendar", "https://calendar.google.com", "schedule"),
        ("Google Drive", "https://drive.google.com", "files docs"),
        ("Google Docs", "https://docs.google.com", "documents writing"),
        ("Google Sheets", "https://sheets.google.com", "spreadsheet"),
        ("ChatGPT", "https://chat.openai.com", "openai gpt ai assistant"),
        ("Claude", "https://claude.ai", "anthropic ai assistant"),
        ("Perplexity", "https://www.perplexity.ai", "ai search"),
        ("Gemini", "https://gemini.google.com", "google ai"),
        ("GitHub", "https://github.com", "code repos git"),
        ("GitLab", "https://gitlab.com", "code repos"),
        ("Stack Overflow", "https://stackoverflow.com", "questions answers code"),
        ("Hacker News", "https://news.ycombinator.com", "startups tech news"),
        ("MDN", "https://developer.mozilla.org", "web docs javascript"),
        ("npm", "https://www.npmjs.com", "packages javascript"),
        ("Docker Hub", "https://hub.docker.com", "containers images"),
        ("Vercel", "https://vercel.com", "deploy hosting"),
        ("Netlify", "https://app.netlify.com", "deploy hosting"),
        ("Cloudflare", "https://dash.cloudflare.com", "dns"),
        ("Supabase", "https://supabase.com", "database postgres"),
        ("Firebase", "https://console.firebase.google.com", "google backend"),
        ("Hugging Face", "https://huggingface.co", "models ai datasets"),
        ("Kaggle", "https://www.kaggle.com", "datasets ml"),
        ("arXiv", "https://arxiv.org", "papers research"),
        ("Notion", "https://www.notion.so", "notes wiki docs"),
        ("Figma", "https://www.figma.com", "design"),
        ("Linear", "https://linear.app", "issues projects"),
        ("Slack", "https://app.slack.com", "chat team"),
        ("Discord", "https://discord.com/app", "chat community"),
        ("Trello", "https://trello.com", "boards"),
        ("Asana", "https://app.asana.com", "tasks"),
        ("Jira", "https://www.atlassian.com/software/jira", "issues agile"),
        ("Miro", "https://miro.com", "whiteboard"),
        ("Spotify", "https://open.spotify.com", "music podcasts"),
        ("YouTube Music", "https://music.youtube.com", "music"),
        ("SoundCloud", "https://soundcloud.com", "music"),
        ("Apple Music", "https://music.apple.com", "music"),
        ("Netflix", "https://www.netflix.com", "movies shows"),
        ("Twitch", "https://www.twitch.tv", "streams live"),
        ("Prime Video", "https://www.primevideo.com", "movies"),
        ("Disney+", "https://www.disneyplus.com", "movies"),
        ("Instagram", "https://www.instagram.com", "photos"),
        ("TikTok", "https://www.tiktok.com", "videos short"),
        ("LinkedIn", "https://www.linkedin.com", "jobs professional"),
        ("Pinterest", "https://www.pinterest.com", "ideas images"),
        ("Bluesky", "https://bsky.app", "social"),
        ("Threads", "https://www.threads.net", "social"),
        ("Mastodon", "https://mastodon.social", "social"),
        ("Tumblr", "https://www.tumblr.com", "blog social"),
        ("Medium", "https://medium.com", "articles blog"),
        ("Substack", "https://substack.com", "newsletters"),
        ("Dev.to", "https://dev.to", "developer articles"),
        ("Product Hunt", "https://www.producthunt.com", "launches startups"),
        ("Wikipedia", "https://www.wikipedia.org", "encyclopedia"),
        ("Amazon", "https://www.amazon.com", "shopping store"),
        ("eBay", "https://www.ebay.com", "shopping auction"),
        ("Etsy", "https://www.etsy.com", "handmade shopping"),
        ("Shopify", "https://admin.shopify.com", "store admin"),
        ("Stripe", "https://dashboard.stripe.com", "payments"),
        ("PayPal", "https://www.paypal.com", "payments"),
        ("Booking", "https://www.booking.com", "hotels travel"),
        ("Airbnb", "https://www.airbnb.com", "stays travel"),
        ("Uber", "https://www.uber.com", "rides"),
        ("Google Maps", "https://maps.google.com", "maps directions"),
        ("IMDb", "https://www.imdb.com", "movies ratings"),
        ("Letterboxd", "https://letterboxd.com", "films diary"),
        ("Goodreads", "https://www.goodreads.com", "books"),
        ("Chess.com", "https://www.chess.com", "chess"),
        ("Lichess", "https://lichess.org", "chess"),
        ("Pokémon Showdown", "https://play.pokemonshowdown.com", "pokemon battles simulator"),
        ("PokeAPI", "https://pokeapi.co", "pokemon api"),
        ("Speedtest", "https://www.speedtest.net", "internet speed"),
        ("Weather", "https://weather.com", "forecast"),
        ("time.is", "https://time.is", "clock time zone"),
        ("DownDetector", "https://downdetector.com", "outage status"),
        ("Hacker News", "https://news.ycombinator.com/newest", "new stories"),
        ("BBC", "https://www.bbc.com", "news"),
        ("Reuters", "https://www.reuters.com", "news"),
        ("The Verge", "https://www.theverge.com", "tech news"),
        ("TechCrunch", "https://techcrunch.com", "startup news"),
        ("Bloomberg", "https://www.bloomberg.com", "markets news"),
        ("Hacker News", "https://news.ycombinator.com", "tech"),
        ("Dribbble", "https://dribbble.com", "design inspiration"),
        ("Behance", "https://www.behance.net", "design portfolio"),
        ("Unsplash", "https://unsplash.com", "photos"),
        ("Coursera", "https://www.coursera.org", "courses"),
        ("Udemy", "https://www.udemy.com", "courses"),
        ("Duolingo", "https://www.duolingo.com", "languages"),
        ("Khan Academy", "https://www.khanacademy.org", "learn"),
        ("Gumroad", "https://gumroad.com", "sell digital"),
        ("Cal.com", "https://app.cal.com", "scheduling"),
        ("Calendly", "https://calendly.com", "scheduling"),
        ("Excalidraw", "https://excalidraw.com", "diagram sketch"),
        ("Photopea", "https://www.photopea.com", "photo editor"),
        ("CodeSandbox", "https://codesandbox.io", "code sandbox"),
        ("Replit", "https://replit.com", "code editor"),
        ("Codepen", "https://codepen.io", "frontend snippets"),
        ("Twitch", "https://www.twitch.tv/directory", "live streams")
    ]

    static func suggestions(for query: String, limit: Int = 6) -> [SiteSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var scored: [(Int, SiteSuggestion)] = []
        for (name, url, keywords) in entries {
            let n = name.lowercased()
            let host = (URL(string: url)?.host ?? "").lowercased()
            var score = 0
            if n == q { score = 100 }
            else if n.hasPrefix(q) { score = 80 }
            else if n.contains(q) { score = 60 }
            else if host.contains(q) { score = 50 }
            else if keywords.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { score = 40 }
            else if q.count > 2 && keywords.contains(q) { score = 30 }
            guard score > 0 else { continue }
            scored.append((score, SiteSuggestion(name: name, url: url)))
        }
        scored.sort { $0.0 > $1.0 }
        var seen = Set<String>()
        return scored.compactMap { entry in
            guard seen.insert(entry.1.url).inserted else { return nil }
            return entry.1
        }.prefix(limit).map { $0 }
    }

    /// Turns whatever was typed into something that opens: a catalogue entry,
    /// a bare domain, or a web search for an unknown phrase.
    static func resolve(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let best = suggestions(for: raw, limit: 1).first, best.name.lowercased().hasPrefix(raw.lowercased()) {
            return best.url
        }
        if raw.contains(".") && !raw.contains(" ") {
            return raw.contains("://") ? raw : "https://" + raw
        }
        if let best = suggestions(for: raw, limit: 1).first { return best.url }
        let query = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return "https://duckduckgo.com/?q=" + query
    }
}

private enum PageScripts {
    /// Google's identity services read `window.webkit.messageHandlers` as proof
    /// that they are inside an embedded web view and then refuse to sign in
    /// ("Google sign-in can't finish here"). See drives the page from Swift
    /// through evaluateJavaScript and registers no script message handlers, so
    /// the bridge can be hidden from page scripts without losing anything.
    /// Runs before the document so nothing can cache the original reference.
    static let hideWebViewBridge = """
    (() => {
      try {
        // `window.webkit` itself is non-configurable, but its messageHandlers
        // property can be neutralised on the instance and on the prototype, so
        // frames created later inherit the neutral version too.
        const neutralize = (ns) => {
          if (!ns) return;
          try { Object.defineProperty(ns, 'messageHandlers', {value: undefined, configurable: true}); } catch (_) {}
          try {
            const proto = Object.getPrototypeOf(ns);
            if (proto) Object.defineProperty(proto, 'messageHandlers', {value: undefined, configurable: true});
          } catch (_) {}
        };
        neutralize(window.webkit);
      } catch (_) {}
    })();
    """


    /// Watches for clicks on third-party sign-in buttons. Some of those flows
    /// need a browser capability an embedded WKWebView does not have (Google's
    /// One Tap needs FedCM), so See can tell the user instead of leaving a dead
    /// button.
    static let authWatcher = #"""
    (function(){
      if (window.__seeAuthWatcher) { return; }
      window.__seeAuthWatcher = true;
      var providers = [
        ['google', /(continue|sign ?in|sign ?up|log ?in) with google|google/i],
        ['apple', /(continue|sign ?in|sign ?up|log ?in) with apple/i],
        ['facebook', /(continue|sign ?in) with facebook/i],
        ['github', /(continue|sign ?in) with github/i],
        ['microsoft', /(continue|sign ?in) with (microsoft|outlook)/i]
      ];
      document.addEventListener('click', function (event) {
        var node = event.target;
        var text = '';
        for (var depth = 0; depth < 5 && node; depth++) {
          text = ((node.innerText || node.textContent || '') + ' ' + (node.getAttribute && (node.getAttribute('aria-label') || '') || '')).trim();
          if (text.length > 1) { break; }
          node = node.parentElement;
        }
        if (!text) { return; }
        for (var i = 0; i < providers.length; i++) {
          if (providers[i][1].test(text) && text.length < 120) {
            try { window.webkit.messageHandlers.seeAuth.postMessage(providers[i][0]); } catch (e) {}
            return;
          }
        }
      }, true);
    })();
    """#

    static let scrollReporter = """
    (function(){
      if (window.__seeScrollHooked) { return; }
      window.__seeScrollHooked = true;
      var t = 0;
      window.addEventListener('scroll', function(){
        clearTimeout(t);
        t = setTimeout(function(){
          try { window.webkit.messageHandlers.seeScroll.postMessage(window.scrollY || 0); } catch (e) {}
        }, 220);
      }, true);
    })();
    """

    /// Smart dark mode: instead of inverting the whole page (which turns every
    /// hue and photo inside out), walk the DOM and darken only the light
    /// surfaces, lighten only the dark text, and keep every hue where it was.
    /// Same idea as the dynamic mode in Dark Reader, kept small enough to run on
    /// a live page.
    static let darkMode = """
    (function(){
      var MAX_NODES = 4500;
      var store = window.__seeDarkStore || (window.__seeDarkStore = new Map());
      var scheduled = false;

      function ensureStyle(){
        var style = document.getElementById('__see_dark');
        if (!style) {
          style = document.createElement('style');
          style.id = '__see_dark';
          (document.head || document.documentElement).appendChild(style);
        }
        style.textContent = [
          'html{background:#0f1013 !important;color-scheme:dark !important}',
          'body{background-color:#0f1013 !important;color:#e6e6ea !important}',
          '::selection{background:#3a3d46 !important;color:#ffffff !important}',
          'input,textarea,select,button{color-scheme:dark !important}',
          'img,video,picture,canvas{filter:none !important;opacity:1 !important}'
        ].join(String.fromCharCode(10));
        return style;
      }

      function parse(color){
        var m = (color || '').match(/[0-9.]+/g);
        if (!m || m.length < 3) { return null; }
        var a = m.length > 3 ? parseFloat(m[3]) : 1;
        return [parseFloat(m[0]), parseFloat(m[1]), parseFloat(m[2]), a];
      }

      function rgbToHsl(r, g, b){
        r /= 255; g /= 255; b /= 255;
        var max = Math.max(r, g, b), min = Math.min(r, g, b);
        var h = 0, s = 0, l = (max + min) / 2;
        if (max !== min) {
          var d = max - min;
          s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
          if (max === r) { h = (g - b) / d + (g < b ? 6 : 0); }
          else if (max === g) { h = (b - r) / d + 2; }
          else { h = (r - g) / d + 4; }
          h /= 6;
        }
        return [h, s, l];
      }

      function hslToRgb(h, s, l){
        function hue(p, q, t){
          if (t < 0) { t += 1; }
          if (t > 1) { t -= 1; }
          if (t < 1 / 6) { return p + (q - p) * 6 * t; }
          if (t < 1 / 2) { return q; }
          if (t < 2 / 3) { return p + (q - p) * (2 / 3 - t) * 6; }
          return p;
        }
        if (s === 0) { var v = Math.round(l * 255); return [v, v, v]; }
        var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        var p = 2 * l - q;
        return [Math.round(hue(p, q, h + 1 / 3) * 255),
                Math.round(hue(p, q, h) * 255),
                Math.round(hue(p, q, h - 1 / 3) * 255)];
      }

      function remember(el, prop){
        var key = el;
        var props = store.get(key);
        if (!props) { props = {}; store.set(key, props); }
        if (!(prop in props)) { props[prop] = el.style.getPropertyValue(prop); }
      }

      function setProp(el, prop, value){
        if (el.style.getPropertyValue(prop) === value
            && el.style.getPropertyPriority(prop) === 'important') { return; }
        remember(el, prop);
        el.style.setProperty(prop, value, 'important');
      }

      function darken(alpha, hsl){
        var l = Math.min(0.22, Math.max(0.09, 0.09 + (1 - hsl[2]) * 0.18));
        var s2 = Math.min(hsl[1], 0.40);
        var rgb = hslToRgb(hsl[0], s2, l);
        return 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + alpha + ')';
      }

      function lighten(hsl){
        // Keep the hue of coloured text, just lift it enough to read on dark.
        var s2 = Math.min(hsl[1], 0.90);
        var l = Math.max(hsl[2], 0.72);
        var rgb = hslToRgb(hsl[0], s2, l);
        return 'rgb(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ')';
      }

      function skip(el){
        var tag = el.tagName;
        return tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS' || tag === 'IFRAME'
          || tag === 'PICTURE' || tag === 'SOURCE' || tag === 'SVG' || tag === 'PATH';
      }

      function tune(el){
        if (!el || el.nodeType !== 1 || skip(el)) { return; }
        var cs;
        try { cs = getComputedStyle(el); } catch (err) { return; }
        if (cs.display === 'none' || cs.visibility === 'hidden') { return; }

        var bg = parse(cs.backgroundColor);
        var lightSurface = false;
        if (bg && bg[3] > 0.04) {
          var b = rgbToHsl(bg[0], bg[1], bg[2]);
          if (b[2] > 0.40) {
            setProp(el, 'background-color', darken(bg[3], b));
            lightSurface = true;
          }
        }

        var fg = parse(cs.color);
        if (fg && fg[3] > 0.2) {
          var f = rgbToHsl(fg[0], fg[1], fg[2]);
          if (f[2] < 0.45 || (lightSurface && f[2] < 0.72)) {
            setProp(el, 'color', lighten(f));
          }
        }

        ['border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color']
          .forEach(function(prop){
            var side = parse(cs.getPropertyValue(prop));
            if (!side || side[3] < 0.1) { return; }
            var s2 = rgbToHsl(side[0], side[1], side[2]);
            if (s2[2] > 0.55) {
              var rgb = hslToRgb(s2[0], Math.min(s2[1], 0.25), 0.24);
              setProp(el, prop, 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + side[3] + ')');
            }
          });

        // Inline SVG icons are painted with currentColor or a literal light
        // fill; keep strokes visible without touching real artwork.
        var fill = parse(cs.fill);
        if (fill && fill[3] > 0.2) {
          var fl = rgbToHsl(fill[0], fill[1], fill[2]);
          if (fl[2] < 0.35) { setProp(el, 'fill', lighten(fl)); }
        }
      }

      function walk(){
        ensureStyle();
        var root = document.body || document.documentElement;
        if (!root) { return; }
        var all = root.getElementsByTagName('*');
        var limit = Math.min(all.length, MAX_NODES);
        for (var i = 0; i < limit; i++) { tune(all[i]); }
      }

      function schedule(){
        if (scheduled) { return; }
        scheduled = true;
        setTimeout(function(){ scheduled = false; try { walk(); } catch (err) {} }, 180);
      }

      function dbg(msg){ try { window.webkit.messageHandlers.seeDebugLog.postMessage(msg); } catch (err) {} }
      try { walk(); } catch (err) { dbg('dark error ' + err); }
      setTimeout(walk, 400);
      setTimeout(walk, 1400);
      setTimeout(walk, 3000);
      if (!window.__seeDarkObserver) {
        window.__seeDarkObserver = new MutationObserver(function(){
          for (var i = 0; i < window.__seeDarkObserver.takeRecords().length; i++) {}
          schedule();
        });
        window.__seeDarkObserver.observe(document.documentElement,
          { childList: true, subtree: true, characterData: false });
      }
    })();
    """

    /// Reverts every inline style the dark mode wrote, so turning it off is exact.
    static let darkModeOff = """
    (function(){
      if (window.__seeDarkObserver) { window.__seeDarkObserver.disconnect(); window.__seeDarkObserver = null; }
      var store = window.__seeDarkStore;
      if (store) {
        store.forEach(function(props, el){
          if (!el || !el.style) { return; }
          Object.keys(props).forEach(function(prop){
            if (props[prop]) { el.style.setProperty(prop, props[prop]); }
            else { el.style.removeProperty(prop); }
          });
        });
        store.clear();
      }
      window.__seeDarkStore = null;
      var style = document.getElementById('__see_dark');
      if (style) { style.textContent = ''; }
      document.documentElement.style.removeProperty('color-scheme');
      document.documentElement.style.removeProperty('background');
    })();
    """

    static func hideCSS(_ selectors: [String]) -> String {
        let encoded = (try? JSONEncoder().encode(selectors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function(){
          // One shared value: an observer created by an earlier call used to
          // re-assert the old selectors after "Clear all".
          window.__seeHideCSS = \(encoded).map(function(s){
            return s + '{display:none !important;visibility:hidden !important;pointer-events:none !important}';
          }).join(String.fromCharCode(10));
          function ensure(){
            var style = document.getElementById('__see_hide');
            if (!window.__seeHideCSS) {
              // Nothing hidden: remove the sheet outright rather than leaving an
              // empty one behind, which is what Peek does.
              if (style) { style.remove(); }
              return;
            }
            // Replacing the sheet (rather than editing it) makes the page
            // recompute styles: editing textContent in place was ignored by some
            // virtualised pages until a reload.
            if (style) { style.remove(); }
            style = document.createElement('style');
            style.id = '__see_hide';
            style.setAttribute('data-see-managed', 'true');
            style.textContent = window.__seeHideCSS;
            (document.head || document.documentElement).appendChild(style);
          }
          ensure();
          if (!window.__seeHideObserver) {
            window.__seeHideObserver = new MutationObserver(function(){ ensure(); });
            window.__seeHideObserver.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
          }
          if (!window.__seeHideRaf) {
            var ticks = 0;
            window.__seeHideRaf = setInterval(function(){ ensure(); if (++ticks > 40) { clearInterval(window.__seeHideRaf); window.__seeHideRaf = null; } }, 50);
          }
        })();
        """
    }

    /// Page-local element zapper. The page owns the registry, so a zap is an
    /// inline `display:none` on one element (not a stylesheet rule) and a
    /// restore is `display = ''` — which always brings it back, without a reload
    /// and without depending on a selector still matching a re-rendered DOM.
    static let zapper = #"""
    (function () {
      if (window.__seeZapper) { return; }
      var STORAGE_KEY = 'zapped_elements_registry';

      function ensureStyles() {
        if (document.getElementById('zapper-core-styles')) { return; }
        var style = document.createElement('style');
        style.id = 'zapper-core-styles';
        style.textContent = [
          '.zapper-target-hover { outline: 2px dashed #ff3366 !important;',
          '  background-color: rgba(255, 51, 102, 0.15) !important;',
          '  cursor: crosshair !important; }'
        ].join(String.fromCharCode(10));
        (document.head || document.documentElement).appendChild(style);
      }

      function getDOMPath(el) {
        var path = [];
        while (el && el.nodeType === Node.ELEMENT_NODE) {
          var index = 0, sibling = el.previousSibling;
          while (sibling) {
            if (sibling.nodeType === Node.ELEMENT_NODE) { index++; }
            sibling = sibling.previousSibling;
          }
          path.unshift({ tag: el.nodeName.toLowerCase(), index: index });
          el = el.parentNode;
          if (el && (el.nodeName === 'BODY' || el.nodeName === 'HTML')) { break; }
        }
        return path;
      }

      function getRegistry() {
        try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]'); }
        catch (e) { return []; }
      }

      function notify() {
        try {
          window.webkit.messageHandlers.seeZap.postMessage({ items: getRegistry() });
        } catch (e) {}
      }

      function saveToRegistry(data) {
        var registry = getRegistry();
        registry.push(data);
        localStorage.setItem(STORAGE_KEY, JSON.stringify(registry));
        notify();
      }

      function removeFromRegistry(id) {
        var registry = getRegistry().filter(function (item) { return item.id !== id; });
        localStorage.setItem(STORAGE_KEY, JSON.stringify(registry));
        notify();
      }

      function findElementByPath(path) {
        var current = document.body;
        for (var i = 0; i < path.length; i++) {
          if (i === 0 && path[i].tag === 'body') { continue; }
          if (!current) { return null; }
          var children = Array.prototype.slice.call(current.children);
          var matchedByTag = children.filter(function (child) {
            return child.nodeName.toLowerCase() === path[i].tag;
          });
          current = children[path[i].index] || matchedByTag[0] || null;
        }
        return current;
      }

      function applyHides() {
        ensureStyles();
        getRegistry().forEach(function (item) {
          var target = findElementByPath(item.path);
          if (target && target.style.display !== 'none') { target.style.display = 'none'; }
        });
      }

      var reapplyTimer = null;
      function scheduleReapply() {
        if (reapplyTimer) { return; }
        reapplyTimer = setTimeout(function () { reapplyTimer = null; applyHides(); }, 120);
      }

      // Single-page apps rebuild their DOM after a route change, which brings a
      // zapped element back until the page is reloaded. Re-apply on any mutation.
      function watch() {
        if (window.__seeZapObserver) { return; }
        window.__seeZapObserver = new MutationObserver(function () {
          if (getRegistry().length) { scheduleReapply(); }
        });
        window.__seeZapObserver.observe(document.documentElement, { childList: true, subtree: true });
        window.addEventListener('popstate', scheduleReapply);
        window.addEventListener('hashchange', scheduleReapply);
        var push = history.pushState, replace = history.replaceState;
        history.pushState = function () { var r = push.apply(this, arguments); scheduleReapply(); return r; };
        history.replaceState = function () { var r = replace.apply(this, arguments); scheduleReapply(); return r; };
      }

      function hideZappedElements() {
        applyHides();
        watch();
        notify();
      }

      var highlighted = null;
      var active = false;

      function hover(x, y) {
        var el = document.elementFromPoint(x, y);
        if (el === highlighted) { return; }
        if (highlighted && highlighted.classList) { highlighted.classList.remove('zapper-target-hover'); }
        highlighted = null;
        if (!el || el === document.body || el === document.documentElement) { return; }
        el.classList.add('zapper-target-hover');
        highlighted = el;
      }

      function clearHover() {
        if (highlighted && highlighted.classList) { highlighted.classList.remove('zapper-target-hover'); }
        highlighted = null;
      }

      function zapElement(el) {
        if (!el || el === document.body || el === document.documentElement) { return null; }
        if (el.classList) { el.classList.remove('zapper-target-hover'); }
        highlighted = null;
        var path = getDOMPath(el);
        var data = {
          id: (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(36).slice(2)),
          tag: el.nodeName.toLowerCase(),
          classes: Array.prototype.slice.call(el.classList).join(' '),
          snippet: (el.outerHTML || '').slice(0, 120),
          path: path,
          timestamp: Date.now()
        };
        saveToRegistry(data);
        el.style.display = 'none';
        return data;
      }

      function zapAt(x, y) {
        clearHover();
        return zapElement(document.elementFromPoint(x, y));
      }

      function restore(id) {
        var registry = getRegistry();
        for (var i = 0; i < registry.length; i++) {
          if (registry[i].id === id) {
            var target = findElementByPath(registry[i].path);
            if (target) { target.style.display = ''; }
            break;
          }
        }
        removeFromRegistry(id);
      }

      function clearAll() {
        var registry = getRegistry();
        registry.forEach(function (item) {
          var target = findElementByPath(item.path);
          if (target) { target.style.display = ''; }
        });
        localStorage.setItem(STORAGE_KEY, '[]');
        notify();
      }

      function handleMouseMove(e) { if (active) { hover(e.clientX, e.clientY); } }

      function handleClick(e) {
        if (!active) { return; }
        e.preventDefault();
        e.stopPropagation();
        zapElement(e.target);
      }

      function enable() {
        ensureStyles();
        active = true;
        document.addEventListener('mousemove', handleMouseMove, true);
        document.addEventListener('click', handleClick, true);
      }

      function disable() {
        active = false;
        clearHover();
        document.removeEventListener('mousemove', handleMouseMove, true);
        document.removeEventListener('click', handleClick, true);
      }

      window.__seeZapper = {
        enable: enable,
        disable: disable,
        hover: hover,
        zapAt: zapAt,
        restore: restore,
        clearAll: clearAll,
        refresh: hideZappedElements,
        reapply: applyHides,
        list: getRegistry,
        isActive: function () { return active; }
      };

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', hideZappedElements);
      } else {
        hideZappedElements();
      }
    })();
    """#

    static let picker = """
    (function(){
      if (window.__seePickerActive) { return; }
      window.__seePickerActive = true;
      var target = null;
      var box = document.createElement('div');
      box.id = '__see_zap_box';
      box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff453a;'
        + 'background:rgba(255,69,58,0.16);border-radius:6px;transition:all .07s ease-out;'
        + 'box-shadow:0 0 0 1px rgba(0,0,0,0.35),0 8px 30px rgba(255,69,58,0.28);display:none;';
      var label = document.createElement('div');
      label.id = '__see_zap_label';
      label.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;'
        + 'font:600 11px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff;'
        + 'background:#ff453a;padding:3px 8px;border-radius:6px;letter-spacing:.2px;'
        + 'box-shadow:0 4px 14px rgba(0,0,0,0.35);display:none;white-space:nowrap;';
      label.textContent = 'Zap this element';
      function attach(){
        if (!box.isConnected) { document.documentElement.appendChild(box); }
        if (!label.isConnected) { document.documentElement.appendChild(label); }
      }
      function clear(){
        target = null;
        box.style.display = 'none';
        label.style.display = 'none';
      }
      function paint(el){
        if (!el || el.nodeType !== 1) { clear(); return; }
        target = el;
        var r = el.getBoundingClientRect();
        attach();
        box.style.display = 'block';
        box.style.left = r.left + 'px';
        box.style.top = r.top + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
        label.style.display = 'block';
        label.textContent = 'Zap  ' + el.tagName.toLowerCase()
          + (el.id ? '#' + el.id : '')
          + (typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\\s+/)[0] : '');
        var ly = r.top > 26 ? r.top - 24 : r.bottom + 6;
        ly = Math.max(4, Math.min(ly, window.innerHeight - 24));
        label.style.left = Math.max(4, Math.min(r.left, window.innerWidth - 130)) + 'px';
        label.style.top = ly + 'px';
      }
      function deepest(el, x, y){
        var node = el;
        for (var i = 0; i < 16; i++) {
          var next = null;
          var kids = node.children || [];
          for (var k = 0; k < kids.length; k++) {
            var kid = kids[k];
            if (kid === box || kid === label) { continue; }
            var r = kid.getBoundingClientRect();
            if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < window.innerHeight
                && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) { next = kid; break; }
          }
          if (!next) { break; }
          node = next;
        }
        return node;
      }

      function uniqueSelector(sel){
        try { return document.querySelectorAll(sel).length === 1; } catch (err) { return false; }
      }
      function classesOf(el){
        var raw = (typeof el.className === 'string') ? el.className : '';
        return raw.trim().split(/\\s+/).filter(function(c){
          return c && c.length < 40 && !/^[0-9]/.test(c) && !/^(ng|css|jsx|sc)-/.test(c);
        }).slice(0, 2);
      }
      function pathFor(el){
        if (!el || el.nodeType !== 1) { return null; }
        if (el.id) {
          var byId = '#' + CSS.escape(el.id);
          if (uniqueSelector(byId)) { return byId; }
        }
        var cls = classesOf(el);
        if (cls.length) {
          var byClass = el.tagName.toLowerCase() + cls.map(function(c){ return '.' + CSS.escape(c); }).join('');
          if (uniqueSelector(byClass)) { return byClass; }
        }
        var parts = [], node = el, depth = 0;
        while (node && node.nodeType === 1 && depth < 8 && node !== document.documentElement) {
          var parent = node.parentElement;
          if (node.id) {
            parts.unshift('#' + CSS.escape(node.id));
            var withId = parts.join(' > ');
            if (uniqueSelector(withId)) { return withId; }
            node = parent; depth++; continue;
          }
          var part = node.tagName.toLowerCase();
          var own = classesOf(node)[0];
          if (own) { part += '.' + CSS.escape(own); }
          if (parent) {
            var index = 1, sibling = node;
            while ((sibling = sibling.previousElementSibling)) {
              if (sibling.tagName === node.tagName) { index++; }
            }
            part += ':nth-of-type(' + index + ')';
          }
          parts.unshift(part);
          var candidate = parts.join(' > ');
          if (uniqueSelector(candidate)) { return candidate; }
          node = parent; depth++;
        }
        return parts.join(' > ');
      }
      // An icon or label usually sits inside the thing the user means to zap.
      function actionable(el){
        var node = el, up = 0;
        while (node && node !== document.body && node !== document.documentElement && up < 8) {
          var tag = node.tagName.toLowerCase();
          if (tag === 'button' || tag === 'a' || tag === 'input' || tag === 'textarea' || tag === 'select') { return node; }
          if (node.getAttribute) {
            var role = node.getAttribute('role');
            if (role === 'button' || role === 'link' || role === 'menuitem' || role === 'tab') { return node; }
          }
          if (tag === 'svg' || tag === 'path' || tag === 'use' || tag === 'g') { node = node.parentElement; up++; continue; }
          if (tag === 'span' || tag === 'i' || tag === 'b' || tag === 'em') {
            var parent = node.parentElement;
            if (parent) {
              var pt = parent.tagName.toLowerCase();
              if (pt === 'button' || pt === 'a' || parent.getAttribute && parent.getAttribute('role') === 'button') { node = parent; continue; }
            }
          }
          break;
        }
        return node || el;
      }
      var lastDebug = 0;
      function dbg(text){
        var now = Date.now();
        if (now - lastDebug < 400) { return; }
        lastDebug = now;
        try { window.webkit.messageHandlers.seeDebugLog.postMessage(text); } catch (err) {}
      }
      window.__seePickerMove = function(e){
        attach();
        try {
          dbg('move ' + e.clientX + ',' + e.clientY + ' hit=' + (document.elementFromPoint(e.clientX, e.clientY) || {}).tagName);
        } catch (err) { dbg('err ' + err); }
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (el && (el === box || el === label)) { return; }
        // Nothing but page background under the cursor: don't frame the whole page.
        if (!el || el === document.body || el === document.documentElement) { clear(); return; }
        el = deepest(el, e.clientX, e.clientY);
        if (el === document.body || el === document.documentElement) { clear(); return; }
        el = actionable(el);
        paint(el);
      };
      window.__seePickerClick = function(e){
        e.preventDefault(); e.stopPropagation();
        var el = document.elementFromPoint(e.clientX, e.clientY) || e.target;
        if (el === box || el === label) { el = target; }
        el = deepest(el, e.clientX, e.clientY);
        el = actionable(el);
        var selector = pathFor(el);
        clear();
        if (selector) {
          // Hide instantly so the user sees the zap land, before the app replies.
          el.style.setProperty('display', 'none', 'important');
          try { window.webkit.messageHandlers.seePicked.postMessage(selector); } catch (err) {}
        }
      };
      window.__seeHoverAt = function(x, y){
        attach();
        var el = document.elementFromPoint(x, y);
        if (!el || el === box || el === label || el === document.body || el === document.documentElement) { clear(); return; }
        el = deepest(el, x, y);
        if (el === document.body || el === document.documentElement) { clear(); return; }
        el = actionable(el);
        if (el !== target) { paint(el); }
      };
      window.__seePickerScroll = function(){ if (target) { paint(target); } };
      window.__seePickerKey = function(e){ if (e.key === 'Escape') { clear(); } };
      window.__seePickerMoveEvt = function(e){
        if (e.target === box || e.target === label) { return; }
        attach();
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === document.body || el === document.documentElement) { clear(); return; }
        el = deepest(el, e.clientX, e.clientY);
        if (el === document.body || el === document.documentElement) { clear(); return; }
        if (el !== target) { paint(el); }
      };
      document.addEventListener('mouseover', window.__seePickerMove, true);
      document.addEventListener('mousemove', window.__seePickerMoveEvt, true);
      document.addEventListener('click', window.__seePickerClick, true);
      document.addEventListener('keydown', window.__seePickerKey, true);
      window.addEventListener('scroll', window.__seePickerScroll, true);
      document.documentElement.style.cursor = 'crosshair';
      attach();
    })();
    """

    /// Reports the page's own cursor for a point, so links and buttons inside a
    /// surface can show a hand even though the web view never gets mouse-moved
    /// events while See's panel is not the key window.
    static let cursorProbe = """
    (function(){
      window.__seeCursorAt = function(x, y){
        var name = 'default';
        var el = document.elementFromPoint(x, y);
        var depth = 0;
        while (el && el.nodeType === 1 && depth < 12) {
          var tag = el.tagName;
          if (tag === 'A' && el.getAttribute('href')) { name = 'pointer'; break; }
          if (tag === 'BUTTON' || tag === 'SUMMARY') { name = 'pointer'; break; }
          if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
            var type = (el.getAttribute('type') || '').toLowerCase();
            name = (type === 'checkbox' || type === 'radio' || type === 'button' || type === 'submit') ? 'pointer' : 'text';
            break;
          }
          var role = el.getAttribute && el.getAttribute('role');
          if (role === 'button' || role === 'link' || role === 'tab' || role === 'menuitem' || role === 'option') { name = 'pointer'; break; }
          if (el.isContentEditable) { name = 'text'; break; }
          var value = '';
          try { value = getComputedStyle(el).cursor || ''; } catch (err) { value = ''; }
          if (value && value !== 'auto' && value !== 'default' && value !== 'inherit') { name = value; break; }
          el = el.parentElement; depth++;
        }
        var hover = '';
        try {
          var h = document.querySelectorAll(':hover');
          if (h.length) { var last = h[h.length - 1]; hover = last.tagName + '.' + (last.className || '').toString().slice(0, 24); }
        } catch (err) {}
        try { window.webkit.messageHandlers.seeCursor.postMessage(name + '|' + hover); } catch (err) {}
        return name;
      };

      // WebKit never forwards mouse moves to a page inside See's overlay, so
      // `:hover` styles (button highlights, tooltips) stay dark. Rebuild the
      // page's own hover rules against a class we control and move that class
      // to whatever is under the pointer.
      var hoverChain = [];
      var hoverLast = null;
      function fire(el, type, x, y){
        if (!el || !el.dispatchEvent) { return; }
        var bubbles = (type !== 'mouseenter' && type !== 'mouseleave');
        try {
          el.dispatchEvent(new MouseEvent(type, { bubbles: bubbles, cancelable: true, view: window, clientX: x, clientY: y }));
        } catch (err) {}
      }
      function buildHoverCSS(){
        var out = [];
        var sheets = document.styleSheets;
        for (var i = 0; i < sheets.length; i++) {
          var rules = null;
          try { rules = sheets[i].cssRules; } catch (err) { continue; }
          if (!rules) { continue; }
          collect(rules, out);
        }
        var style = document.getElementById('__see_hover_css');
        if (!style) {
          style = document.createElement('style');
          style.id = '__see_hover_css';
          (document.head || document.documentElement).appendChild(style);
        }
        var css = out.join(String.fromCharCode(10));
        if (style.textContent.length !== css.length) { style.textContent = css; }
      }
      function collect(rules, out){
        for (var i = 0; i < rules.length; i++) {
          var rule = rules[i];
          if (rule.selectorText && rule.selectorText.indexOf(':hover') >= 0) {
            var parts = rule.selectorText.split(',');
            var converted = [];
            for (var j = 0; j < parts.length; j++) {
              var sel = parts[j].trim();
              if (sel.indexOf(':hover') < 0) { continue; }
              converted.push(sel.replace(/:hover/g, '.__see-hover'));
            }
            if (converted.length) {
              try { out.push(converted.join(',') + '{' + rule.style.cssText + '}'); } catch (err) {}
            }
          } else if (rule.cssRules) {
            collect(rule.cssRules, out);
          }
        }
      }
      var hoverBuilt = 0;
      function releaseHover(x, y){
        for (var i = hoverChain.length - 1; i >= 0; i--) {
          var node = hoverChain[i];
          fire(node, 'mouseout', x, y);
          fire(node, 'mouseleave', x, y);
          node.classList.remove('__see-hover');
        }
        hoverChain = [];
        hoverLast = null;
      }
      window.__seeSmartHover = function(x, y){
        var now = Date.now();
        if (now - hoverBuilt > 2500) { hoverBuilt = now; try { buildHoverCSS(); } catch (err) {} }
        var el = document.elementFromPoint(x, y);
        if (el === hoverLast) { return; }
        releaseHover(x, y);
        if (!el || el === document.documentElement || el === document.body) { return; }
        hoverLast = el;
        var chain = [], node = el, depth = 0;
        while (node && node !== document.documentElement && depth < 8) {
          chain.push(node); node = node.parentElement; depth++;
        }
        // Enter from the outside in, the way a real pointer would.
        for (var j = chain.length - 1; j >= 0; j--) {
          fire(chain[j], 'mouseover', x, y);
          fire(chain[j], 'mouseenter', x, y);
          chain[j].classList.add('__see-hover');
        }
        fire(el, 'mousemove', x, y);
        hoverChain = chain;
      };
      window.__seeSmartHoverClear = function(){
        releaseHover(0, 0);
      };
    })();
    """

    static func customCSS(_ css: String) -> String {
        let payload = (try? JSONEncoder().encode(css)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        (function(){
          var css = \(payload);
          var style = document.getElementById('__see_custom');
          if (!css.trim().length) { if (style) { style.remove(); } return; }
          if (!style) {
            style = document.createElement('style');
            style.id = '__see_custom';
            (document.head || document.documentElement).appendChild(style);
          }
          if (style.textContent !== css) { style.textContent = css; }
        })();
        """
    }

    /// A dark canvas from the first byte of a new document, removed once the
    /// page has painted. Without it every back/forward shows WebKit's white
    /// default before the page's own background arrives.
    static let flashGuard = """
    (function(){
      if (window.__seeFlashGuard) { return; }
      window.__seeFlashGuard = true;
      var install = function(){
        if (!document.documentElement) { return; }
        // Reuse one element: readystatechange fires more than once and a second
        // element would survive the cleanup below.
        var style = document.getElementById('__see_flash');
        if (!style) {
          style = document.createElement('style');
          style.id = '__see_flash';
          document.documentElement.appendChild(style);
        }
        style.textContent = 'html,body{background-color:#0f1013 !important}';
      };
      install();
      document.addEventListener('readystatechange', install, true);
      setTimeout(function(){
        var all = document.querySelectorAll('#__see_flash');
        for (var i = 0; i < all.length; i++) { all[i].remove(); }
      }, 2500);
    })();
    """

    /// Removes any leftover zap overlay. Injected on every load so a session
    /// that ended while the page was busy can never leave a red box behind.
    static let clearPicker = """
    (function(){
      function scrub(){
        if (window.__seePickerActive) { return; }
        var strays = document.querySelectorAll('#__see_zap_box, #__see_zap_label');
        for (var i = 0; i < strays.length; i++) { strays[i].remove(); }
        if (document.documentElement.style.cursor === 'crosshair') {
          document.documentElement.style.cursor = '';
        }
      }
      scrub();
      setTimeout(scrub, 300);
      setTimeout(scrub, 1500);
      // Whatever painted an overlay without a live session, it must not stay.
      if (!window.__seePickerScrubber) {
        window.__seePickerScrubber = new MutationObserver(scrub);
        window.__seePickerScrubber.observe(document.documentElement,
          { childList: true, subtree: true });
      }
    })();
    """

    static let stopPicker = """
    (function(){
      window.__seePickerActive = false;
      if (window.__seePickerMove) { document.removeEventListener('mouseover', window.__seePickerMove, true); }
      if (window.__seePickerClick) { document.removeEventListener('click', window.__seePickerClick, true); }
      if (window.__seePickerKey) { document.removeEventListener('keydown', window.__seePickerKey, true); }
      document.documentElement.style.cursor = '';
      window.__seePickerActive = false;
      ['__see_zap_box', '__see_zap_label'].forEach(function(id){
        var el = document.getElementById(id);
        if (el) { el.style.display = 'none'; el.remove(); }
      });
      window.__seePickerTarget = null;
      window.__seePickerActive = false;
    })();
    """
}

// MARK: - Web message bridge

@MainActor
private final class SeeWebBridge: NSObject, WKScriptMessageHandler {
    weak var site: WebsiteSurface?
    var onPick: ((String) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "seePicked":
            if let selector = message.body as? String { onPick?(selector) }
        case "seeDebugLog":
            if let text = message.body as? String { debugLog("picker: \(text)") }
        case "seeCursor":
            if let body = message.body as? String {
                let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                site?.pageCursor = String(parts.first ?? "default")
            }
        case "seeScroll":
            if let value = message.body as? Double { site?.scrollY = value }
            else if let value = message.body as? NSNumber { site?.scrollY = value.doubleValue }
        case "seeAuth":
            if let provider = message.body as? String { site?.noteAuthProvider(provider) }
        case "seeZap":
            if let body = message.body as? [String: Any],
               let items = body["items"] as? [[String: Any]] {
                site?.updateZapped(items)
            }
        default:
            break
        }
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: SeeWebBridge?
    init(_ target: SeeWebBridge) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}


// MARK: - Surface models

@MainActor
private final class NativeWidgetSurface: ObservableObject, Identifiable {
    let id: UUID
    let kind: NativeWidgetKind
    @Published var center: CGPoint
    @Published var size: CGSize
    @Published var note: String
    @Published var isDragging = false
    /// Tidy keeps a locked widget's size; only its position may change.
    @Published var sizeLocked = false
    /// Stacking order: the surface touched last carries the highest value.
    @Published var z: Double = 0

    init(kind: NativeWidgetKind, center: CGPoint, id: UUID = UUID(), size: CGSize? = nil, note: String = "") {
        self.id = id; self.kind = kind; self.center = center
        self.size = size ?? kind.size; self.note = note
    }

    var snapshot: WidgetSnapshot {
        WidgetSnapshot(id: id, kind: kind.rawValue,
                       x: center.x, y: center.y, w: size.width, h: size.height, note: note,
                       sizeLocked: sizeLocked)
    }
}

/// One zapped element as the page reports it.
struct ZappedSummary: Identifiable, Equatable {
    let id: String
    let tag: String
    let classes: String
    let snippet: String

    var label: String { classes.isEmpty ? tag : tag + "." + classes.split(separator: " ").joined(separator: ".") }
}

@MainActor
private final class WebsiteSurface: ObservableObject, Identifiable {
    let id: UUID
    @Published var address: String
    @Published var title: String
    @Published private(set) var requestedURL: URL
    @Published private(set) var requestID = 0
    @Published var center: CGPoint
    @Published var size: CGSize {
        didSet { debugLog("site size \(oldValue.width)x\(oldValue.height) -> \(size.width)x\(size.height)") }
    }
    /// 0…1 for the loading beam that runs along the card's bottom edge.
    @Published var loadProgress: Double = 0
    @Published var isLoading = false
    @Published var config: WebsiteConfig
    @Published var scrollY: Double = 0
    @Published var isPickingElements = false
    /// Stacking order: the surface touched last carries the highest value.
    @Published var z: Double = 0
    /// Tidy keeps a locked site's size; only its position may change.
    @Published var sizeLocked = false
    /// Set when the page starts a third-party sign-in that cannot finish here.
    @Published var authNotice: String?
    /// Elements the page itself has zapped, mirrored here for the config panel.
    @Published private(set) var zapped: [ZappedSummary] = []
    /// Cursor the page itself wants at the last probed point (`pointer`, `text`…).
    @Published var pageCursor: String = "default"

    /// Still image shown in place of the live page while a See panel is open.
    @Published var chromeSnapshot: NSImage?
    weak var webView: WKWebView?
    weak var webHost: WebsiteHostView?
    private var refreshTimer: Timer?

    init(address: String, title: String, center: CGPoint, id: UUID = UUID(),
         size: CGSize? = nil, config: WebsiteConfig = WebsiteConfig(), scrollY: Double = 0) {
        let safe = URL(string: address) ?? URL(string: "https://example.com")!
        self.id = id
        self.address = safe.absoluteString; self.title = title
        self.requestedURL = safe; self.center = center
        self.size = size ?? CGSize(width: 1060, height: 790)
        self.config = config; self.scrollY = scrollY
    }

    var snapshot: WebsiteSnapshot {
        WebsiteSnapshot(id: id, address: address, title: title,
                        x: center.x, y: center.y, w: size.width, h: size.height,
                        config: config, scrollY: scrollY, sizeLocked: sizeLocked)
    }

    func navigate() {
        var candidate = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme),
              scheme == "file" ? url.isFileURL : url.host != nil else { return }
        address = url.absoluteString; requestedURL = url
        title = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.lastPathComponent
        requestID += 1
    }

    func reload() { webView?.reload() }

    /// File URLs need loadFileURL: a plain request is refused by WebKit.
    func load(into webView: WKWebView) {
        let url = requestedURL
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func refreshOnPeekIfNeeded() {
        guard config.autoRefresh == AutoRefreshOption.everyPeek.rawValue else { return }
        webView?.reload()
    }

    // The live web view is an AppKit subview, so it always draws above
    // SwiftUI panels in the same window. Freeze it to an image and hide it
    // while a panel is open, then bring the live page straight back.
    func enterChromeMode() {
        guard let webView, chromeSnapshot == nil else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                self.chromeSnapshot = image
                self.webView?.isHidden = true
            }
        }
    }

    func exitChromeMode() {
        debugLog("exitChromeMode hidden=\(String(describing: webView?.isHidden)) snap=\(chromeSnapshot != nil)")
        guard chromeSnapshot != nil || webView?.isHidden == true else { return }
        chromeSnapshot = nil
        webView?.isHidden = false
    }

    // MARK: Tuning

    /// Push the current configuration into the live web view.
    /// Single path for restoring a zapped element: model, page, persistence.
    /// Puts back everything the page has hidden, then reloads.
    func restoreAllZaps() {
        config.hiddenSelectors.removeAll()
        webView?.evaluateJavaScript("""
        (function(){
          try {
            var raw = localStorage.getItem('zapped_elements_registry');
            var list = [];
            try { list = JSON.parse(raw || '[]'); } catch (e) {}
            localStorage.setItem('zapped_elements_registry', '[]');
            if (window.__seeZapper && window.__seeZapper.clearAll) { window.__seeZapper.clearAll(); }
            if (window.__seeZapper && window.__seeZapper.refresh) { window.__seeZapper.refresh(); }
            return 'cleared ' + list.length;
          } catch (e) { return 'error:' + e; }
        })();
        """) { value, _ in
            debugLog("restore all -> \(String(describing: value))")
        }
        zapped = []
        applyHiddenSelectors()
        applyTuning(reload: false)
        pullZappedRegistry()
    }

    func removeHidden(_ selector: String) {
        config.hiddenSelectors.removeAll { $0 == selector }
        MenuHover.shared.clear("uh:" + selector)
        debugLog("unhide \(selector) remaining=\(config.hiddenSelectors.count)")
        applyTuning(reload: false)
        verifyUnhidden(selector)
    }

    func applyTuning(reload: Bool) {
        guard let webView else { return }
        if config.darkMode {
            webView.evaluateJavaScript(PageScripts.darkMode, completionHandler: nil)
        } else {
            webView.evaluateJavaScript(PageScripts.darkModeOff, completionHandler: nil)
        }
        webView.evaluateJavaScript("JSON.stringify({t: document.title, n: (document.body ? document.body.innerText.length : -1), bg: getComputedStyle(document.body||document.documentElement).backgroundColor, url: location.href})") { v, e in
            debugLog("load state \(self.title) -> \(String(describing: v)) err=\(String(describing: e))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak webView] in
            webView?.evaluateJavaScript("JSON.stringify({t: document.title, n: (document.body ? document.body.innerText.length : -1), html: document.documentElement.outerHTML.length, url: location.href, bg: getComputedStyle(document.body||document.documentElement).backgroundColor, scripts: document.scripts.length})") { v, _ in
                debugLog("settled \(self.title) -> \(String(describing: v))")
            }
        }
        webView.customUserAgent = config.userAgent.string
        webView.appearance = config.darkMode ? NSAppearance(named: .darkAqua) : nil
        installUserScripts(in: webView)
        webView.evaluateJavaScript(PageScripts.customCSS(config.customCode), completionHandler: nil)
        scheduleAutoRefresh()
        applyHiddenSelectors()
        if reload {
            webView.reload()
        }
    }

    func installUserScripts(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        if let list = AdBlocker.shared.list { controller.add(list) }
        // The zapper owns the "hidden elements" list in the page's own storage,
        // so it has to exist before the document paints.
        controller.addUserScript(WKUserScript(source: PageScripts.authWatcher,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: PageScripts.zapper,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: PageScripts.hideWebViewBridge,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if config.darkMode {
            controller.addUserScript(WKUserScript(source: PageScripts.darkMode,
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: false))
            controller.addUserScript(WKUserScript(source: PageScripts.darkMode,
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        if !config.customCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.addUserScript(WKUserScript(source: PageScripts.customCSS(config.customCode),
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: PageScripts.flashGuard,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: PageScripts.scrollReporter,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: PageScripts.cursorProbe,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        if isPickingElements {
            // Main frame only: `stopPicker` is evaluated on the main frame, so an
            // overlay created inside an iframe could never be removed.
            controller.addUserScript(WKUserScript(source: PageScripts.picker,
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else {
            controller.addUserScript(WKUserScript(source: PageScripts.clearPicker,
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
    }

    func applyHiddenSelectors() {
        guard let webView else { return }
        // An empty list clears the stylesheet, which is how an "unzap" becomes
        // visible immediately instead of after a reload.
        webView.evaluateJavaScript(PageScripts.hideCSS(config.hiddenSelectors), completionHandler: nil)
        if config.hiddenSelectors.isEmpty {
            webView.evaluateJavaScript("var s=document.getElementById('__see_hide'); s ? s.textContent.length : -1") { value, _ in
                debugLog("hide cleared, css length=\(String(describing: value))")
            }
        }
        // Hiding or restoring an element changes the layout under a virtualised
        // page (X, Google), which will not re-measure until something tells it
        // to. Nudge it so removed rules show up without a reload.
        webView.evaluateJavaScript("""
        (function(){
          window.dispatchEvent(new Event('resize'));
          var nudge = function(){ if (document.body) { document.body.offsetHeight; } };
          nudge();
          requestAnimationFrame(function(){ nudge(); requestAnimationFrame(nudge); });
        })();
        """, completionHandler: nil)
        webView.needsDisplay = true
        // Any hide or restore drops the still image and keeps the surface live.
        // Re-taking a snapshot here was the bug: the web view is hidden at that
        // point, so the new image was painted from the stale document and the
        // change never showed.
        if chromeSnapshot != nil || webView.isHidden {
            chromeSnapshot = nil
            webView.isHidden = false
            debugLog("live edit: snapshot dropped")
        }
        installUserScripts(in: webView)
        refreshChromeSnapshot()
    }

    func setPicking(_ picking: Bool) {
        isPickingElements = picking
        guard let webView else { return }
        if picking {
            exitChromeMode()
            webView.evaluateJavaScript("window.__seeZapper && window.__seeZapper.enable();", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.__seeZapper && window.__seeZapper.disable();", completionHandler: nil)
            refreshChromeSnapshot()
        }
        webHost?.refreshHandles()
        debugLog("setPicking \(picking) hidden=\(String(describing: webView.isHidden))")
    }

    private var lastHoverAt = CFAbsoluteTimeGetCurrent()

    /// App-driven highlighter: WKWebView does not receive mouse-moved events under
    /// the accessory panel, so the window forwards the pointer position instead.
    func hoverAt(_ point: CGPoint) {
        guard isPickingElements, let webView else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHoverAt < 0.016 { return }
        lastHoverAt = now
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        guard x >= 0, y >= 0, x <= Int(size.width), y <= Int(size.height) else { return }
        webView.evaluateJavaScript("window.__seeZapper ? window.__seeZapper.hover(\(x), \(y)) : (window.__seeHoverAt && window.__seeHoverAt(\(x), \(y)));", completionHandler: nil)
    }

    /// Asks the page what cursor it wants at a point (throttled).
    private var lastProbeAt = CFAbsoluteTimeGetCurrent()
    private var lastProbePoint = CGPoint(x: -100, y: -100)

    func probeCursor(at point: CGPoint) {
        guard let webView else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let moved = hypot(point.x - lastProbePoint.x, point.y - lastProbePoint.y)
        guard moved > 2 || now - lastProbeAt > 0.4 else { return }
        lastProbeAt = now; lastProbePoint = point
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        guard x >= 0, y >= 0, x <= Int(size.width), y <= Int(size.height) else { return }
        webView.evaluateJavaScript("window.__seeSmartHover && window.__seeSmartHover(\(x), \(y)); window.__seeCursorAt && window.__seeCursorAt(\(x), \(y));", completionHandler: nil)
    }

    /// Belt and braces for "the element did not come back": if the page still
    /// reports it hidden after an unhide (some SPA stylesheets win), reload the
    /// surface instead of making the user do it.
    func verifyUnhidden(_ selector: String) {
        guard let webView else { return }
        let quoted = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak webView] in
            guard let webView else { return }
            let js = """
            (function(){
              var sheet = document.getElementById('__see_hide');
              if (sheet && sheet.textContent) { return 'managed'; }
              var e = document.querySelector('\(quoted)');
              if (!e) { return 'absent'; }
              var s = getComputedStyle(e);
              return s.display + '/' + s.visibility;
            })();
            """
            webView.evaluateJavaScript(js) { value, _ in
                guard let text = value as? String, text != "managed", text != "absent" else { return }
                if text.hasPrefix("none") || text.contains("hidden") {
                    debugLog("unhide left it \(text) -> reloading")
                    webView.reload()
                }
            }
        }
    }

    func clearHover() {
        webView?.evaluateJavaScript("window.__seeSmartHoverClear && window.__seeSmartHoverClear();", completionHandler: nil)
    }

    // MARK: Zapper

    func updateZapped(_ items: [[String: Any]]) {
        let mapped: [ZappedSummary] = items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return ZappedSummary(id: id,
                                 tag: item["tag"] as? String ?? "element",
                                 classes: item["classes"] as? String ?? "",
                                 snippet: item["snippet"] as? String ?? "")
        }
        debugLog("zapped list \(mapped.count) for \(title)")
        if mapped.map(\.id) != zapped.map(\.id) { zapped = mapped }
        if isPickingElements, !mapped.isEmpty, let last = mapped.last {
            debugLog("zapper added \(last.tag).\(last.classes) total=\(mapped.count)")
            refreshChromeSnapshot()
        }
    }

    func zap(at point: CGPoint) {
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        guard x >= 0, y >= 0, x <= Int(size.width), y <= Int(size.height) else { return }
        webView?.evaluateJavaScript("window.__seeZapper && window.__seeZapper.zapAt(\(x), \(y));", completionHandler: nil)
    }

    /// A third-party sign-in button was pressed. Record it so the surface can
    /// offer a route that actually works.
    func noteAuthProvider(_ provider: String) {
        let name = provider.prefix(1).uppercased() + provider.dropFirst()
        authNotice = name
        debugLog("auth: \(provider) sign-in pressed on \(title)")
    }

    func dismissAuthNotice() { authNotice = nil }

    func openInBrowser() {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    func startZapper() { webView?.evaluateJavaScript("window.__seeZapper && window.__seeZapper.enable();", completionHandler: nil) }
    func stopZapper() { webView?.evaluateJavaScript("window.__seeZapper && window.__seeZapper.disable();", completionHandler: nil) }

    func restoreZapped(_ id: String) {
        webView?.evaluateJavaScript("window.__seeZapper && window.__seeZapper.restore(\"\(id)\");") { [weak self] _, _ in
            guard let self else { return }
            MenuHover.shared.clear("uz:" + id)
            self.pullZappedRegistry()
            self.refreshChromeSnapshot()
        }
        debugLog("zapper restore \(id)")
    }

    func clearZapped() {
        webView?.evaluateJavaScript("""
        (function(){
          try {
            localStorage.setItem('zapped_elements_registry', '[]');
            if (window.__seeZapper && window.__seeZapper.clearAll) { window.__seeZapper.clearAll(); }
            return 'cleared';
          } catch (e) { return 'error:' + e; }
        })();
        """) { [weak self] _, _ in
            guard let self else { return }
            self.config.hiddenSelectors.removeAll()
            self.zapped = []
            self.applyHiddenSelectors()
            self.pullZappedRegistry()
            self.refreshChromeSnapshot()
        }
        debugLog("zapper clear all")
    }

    /// Reads the page's registry directly — the page's own post goes through the
    /// bridge we hide from third-party scripts, so it never arrives.
    private var zappedPoll: Timer?

    /// Zaps happen long after the load, so the list has to be read back while the
    /// page is open — this is what the load-time read alone was missing.
    func startZappedPoll() {
        guard zappedPoll == nil else { return }
        zappedPoll = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullZappedRegistry() }
        }
    }

    func stopZappedPoll() {
        zappedPoll?.invalidate()
        zappedPoll = nil
    }

    func pullZappedRegistry() {
        webView?.evaluateJavaScript("localStorage.getItem('zapped_elements_registry') || '[]'") { [weak self] raw, _ in
            guard let self, let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            self.updateZapped(items)
        }
    }

    func refreshChromeSnapshot() {
        guard chromeSnapshot != nil || webView?.isHidden == true else { return }
        chromeSnapshot = nil
        webView?.isHidden = false
        guard !isPickingElements else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.enterChromeMode()
        }
    }

    func didFinishLoad(in webView: WKWebView) {
        // The page paints its own background now; drop the dark canvas.
        webView.evaluateJavaScript("(function(){ var all = document.querySelectorAll('#__see_flash'); for (var i = 0; i < all.length; i++) { all[i].remove(); } return all.length; })()", completionHandler: nil)
        webView.customUserAgent = config.userAgent.string
        webView.appearance = config.darkMode ? NSAppearance(named: .darkAqua) : nil
        // Zaps happen after the load, so the list is read back while the page is
        // open; without this a zap only appeared after a manual reload.
        startZappedPoll()
        if config.rememberScroll, scrollY > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, \(Int(scrollY)));", completionHandler: nil)
        }
        // Ask the page what it has hidden, and install the zapper when the
        // document-start injection did not take — otherwise the panel never gets
        // the list even though elements really are removed.
        webView.evaluateJavaScript("""
        (function(){
          try {
            if (window.__seeZapper && window.__seeZapper.refresh) { window.__seeZapper.refresh(); return 'refreshed'; }
            return 'no-zapper';
          } catch (e) { return 'error:' + e; }
        })();
        """) { [weak self] value, _ in
            let probe = (value as? String) ?? "nil"
            debugLog("zap probe -> \(probe)")
            guard let self else { return }
            // Read the registry directly: the page's own post goes through the
            // bridge we deliberately hide from third-party scripts, so it never
            // arrived and the panel stayed empty.
            webView.evaluateJavaScript("localStorage.getItem('zapped_elements_registry') || '[]'") { [weak self] raw, _ in
                guard let self, let json = raw as? String,
                      let data = json.data(using: .utf8),
                      let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
                self.updateZapped(items)
            }
            guard probe == "no-zapper" else { return }
            webView.evaluateJavaScript(PageScripts.zapper) { _, _ in
                webView.evaluateJavaScript("window.__seeZapper && window.__seeZapper.refresh(); 'ok'", completionHandler: nil)
            }
        }
        if isPickingElements {
            webView.evaluateJavaScript("window.__seeZapper && window.__seeZapper.enable();", completionHandler: nil)
        }
    }

    private func scheduleAutoRefresh() {
        refreshTimer?.invalidate(); refreshTimer = nil
        guard config.autoRefresh > 0 else { return }
        let timer = Timer(timeInterval: config.autoRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.webView?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    isolated deinit { refreshTimer?.invalidate() }
}
// MARK: - WebKit views

@MainActor
private struct WebsiteView: NSViewRepresentable {
    @ObservedObject var site: WebsiteSurface
    let onHoverChange: (Bool) -> Void
    let onClose: () -> Void
    let onPick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WebsiteHostView {
        let host = WebsiteHostView(site: site)
        host.onHoverChange = onHoverChange
        host.onClose = onClose
        host.onPick = onPick
        host.webView.allowsBackForwardNavigationGestures = true
        // An opaque backing store plus a dark under-page colour is what stops
        // the white flash while back/forward swaps documents: WebKit paints the
        // under-page colour, never its default white.
        host.webView.setValue(true, forKey: "drawsBackground")
        host.webView.underPageBackgroundColor = NSColor(calibratedRed: 0.086, green: 0.090, blue: 0.098, alpha: 1)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedRed: 0.086, green: 0.090, blue: 0.098, alpha: 1).cgColor
        host.webView.customUserAgent = site.config.userAgent.string
        host.webView.appearance = site.config.darkMode ? NSAppearance(named: .darkAqua) : nil
        site.webView = host.webView
        site.webHost = host
        site.installUserScripts(in: host.webView)
        context.coordinator.lastRequestID = site.requestID
        site.load(into: host.webView)
        site.applyTuning(reload: false)
        return host
    }

    // WebKit's default UA makes some sites (Google included) serve their
    // simplified legacy markup, so present a current desktop Chrome identity.
    static let modernUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    func updateNSView(_ host: WebsiteHostView, context: Context) {
        host.onHoverChange = onHoverChange
        host.onClose = onClose
        host.onPick = onPick
        site.webView = host.webView
        let blank = host.webView.url == nil
        guard context.coordinator.lastRequestID != site.requestID || blank else { return }
        context.coordinator.lastRequestID = site.requestID
        site.load(into: host.webView)
    }

    final class Coordinator { var lastRequestID = -1 }
}

/// The loading line, measured off a screen recording of the reference build and
/// copied pixel for pixel:
///
/// - a 1.5pt line sitting on the card's bottom edge, top row #1E95CB over a
///   lighter #62C4EC, uniform along its length — no head, no taper;
/// - a soft cyan bloom that rises about 12pt above the line and fades to
///   nothing, brightest right against the line;
/// - it grows from the card's left edge with load progress, holds between
///   progress steps, and on completion the tail catches up to the head so the
///   line is swallowed from the left before it disappears.
///
/// Drawn in AppKit because SwiftUI overlays paint under a WKWebView.
@MainActor
private final class PageLoadBeamView: NSView {
    private let container = CALayer()
    private let bloom = CAGradientLayer()
    private let line = CAGradientLayer()
    private let reveal = CALayer()

    private enum Phase { case idle, loading, finishing }

    private var head: CGFloat = 0
    private var tail: CGFloat = 0
    private var phase: Phase = .idle
    private var lifecycleToken = 0
    private var lastProgress: Double = 0
    private var pendingFinish: DispatchWorkItem?

    static let core = NSColor(srgbRed: 0.118, green: 0.584, blue: 0.796, alpha: 1)   // 1E95CB
    static let light = NSColor(srgbRed: 0.384, green: 0.769, blue: 0.925, alpha: 1)  // 62C4EC

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        container.masksToBounds = true
        layer?.addSublayer(container)

        bloom.startPoint = CGPoint(x: 0.5, y: 1)
        bloom.endPoint = CGPoint(x: 0.5, y: 0)
        // Measured off the reference: ~72% of the line colour two points above
        // it, ~36% at five, ~12% at nine, gone by fourteen.
        bloom.colors = [PageLoadBeamView.core.withAlphaComponent(0.86).cgColor,
                        PageLoadBeamView.core.withAlphaComponent(0.62).cgColor,
                        PageLoadBeamView.core.withAlphaComponent(0.34).cgColor,
                        PageLoadBeamView.core.withAlphaComponent(0.12).cgColor,
                        PageLoadBeamView.core.withAlphaComponent(0.0).cgColor]
        bloom.locations = [0, 0.14, 0.34, 0.62, 1]
        container.addSublayer(bloom)

        line.startPoint = CGPoint(x: 0.5, y: 0)
        line.endPoint = CGPoint(x: 0.5, y: 1)
        line.colors = [PageLoadBeamView.core.cgColor,
                       PageLoadBeamView.core.cgColor,
                       PageLoadBeamView.light.cgColor]
        line.locations = [0, 0.45, 1]
        container.addSublayer(line)

        reveal.backgroundColor = NSColor.white.cgColor
        container.mask = reveal

        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    /// One pass per navigation, driven by the navigation delegate rather than
    /// by `isLoading` and `estimatedProgress`: WebKit restarts both when a
    /// redirect or a subresource arrives, which is what made the line jump back
    /// to a smaller percentage and run again. Progress may only push the head
    /// forward within a pass.
    func begin() {
        guard bounds.width > 0 else { return }
        guard phase != .loading else { return }   // a redirect continues the pass
        beginLoad()
    }

    func grow(progress value: Double) {
        guard bounds.width > 0, phase == .loading else { return }
        let clamped = min(max(value, 0), 1)
        lastProgress = max(lastProgress, clamped)
        let target = max(2, bounds.width * CGFloat(lastProgress))
        if target > head { head = target }
        animateReveal(duration: 0.34)
    }

    func complete() {
        guard bounds.width > 0, phase == .loading else { return }
        pendingFinish?.cancel()
        pendingFinish = nil
        finishLoad()
    }

    private func beginLoad() {
        phase = .loading
        lifecycleToken += 1
        lastProgress = 0
        tail = 0
        head = 2
        setVisible(true, duration: 0.10)
        // Anchor at the left edge with no animation: animating from the previous
        // wipe's position made the line fly in from the right before growing.
        applyRevealNow()
    }

    private func applyRevealNow() {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reveal.frame = CGRect(x: tail, y: 0, width: max(0, head - tail), height: bounds.height)
        CATransaction.commit()
    }

    private func finishLoad() {
        phase = .finishing
        lifecycleToken += 1
        let token = lifecycleToken
        head = bounds.width
        animateReveal(duration: 0.16)
        // The tail catches up to the head: the line is swallowed from the left,
        // exactly like the reference.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, token == self.lifecycleToken else { return }
            self.tail = self.bounds.width
            self.animateReveal(duration: 0.30)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self, token == self.lifecycleToken else { return }
                self.setVisible(false, duration: 0.12)
                self.phase = .idle
                self.tail = 0
                self.head = 2
                self.applyRevealNow()
            }
        }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); layoutLayers() }
    override func layout() { super.layout(); layoutLayers() }

    private var lineHeight: CGFloat { 1.5 }
    private var bloomHeight: CGFloat { 7 }

    private func layoutLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let lineY = bounds.height - lineHeight
        line.frame = CGRect(x: 0, y: lineY, width: bounds.width, height: lineHeight)
        bloom.frame = CGRect(x: 0, y: lineY - bloomHeight, width: bounds.width, height: bloomHeight)
        if phase != .finishing { head = min(head, bounds.width) }
        if phase == .idle { reveal.frame = .zero }
        CATransaction.commit()
    }

    private func animateReveal(duration: TimeInterval) {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        reveal.frame = CGRect(x: tail, y: 0, width: max(0, head - tail), height: bounds.height)
        CATransaction.commit()
    }

    private func setVisible(_ visible: Bool, duration: TimeInterval) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = target
        }
    }
}

@MainActor
private final class WebsiteHostView: NSView, WKNavigationDelegate, WKUIDelegate {
    private let site: WebsiteSurface
    let webView: WKWebView
    private let handles: WebsiteHandleView
    private let beam = PageLoadBeamView(frame: .zero)
    private let bridge = SeeWebBridge()
    var onHoverChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onPick: ((String) -> Void)? {
        didSet { bridge.onPick = onPick }
    }

    init(site: WebsiteSurface) {
        self.site = site
        handles = WebsiteHandleView(site: site)
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let handler = WeakScriptHandler(bridge)
        controller.add(handler, name: "seePicked")
        controller.add(handler, name: "seeScroll")
        controller.add(handler, name: "seeDebugLog")
        controller.add(handler, name: "seeCursor")
        controller.add(handler, name: "seeZap")
        controller.add(handler, name: "seeAuth")
        configuration.userContentController = controller
        // Sign-in flows ("Continue with Google") are popups; without this the
        // button does nothing at all.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        bridge.site = site
        bridge.onPick = onPick
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [.new], context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.isLoading), options: [.new], context: nil)
        beam.autoresizingMask = [.width, .minYMargin]
        addSubview(webView)
        addSubview(beam)
        addSubview(handles, positioned: .above, relativeTo: beam)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard object as AnyObject? === webView else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        switch keyPath {
        case #keyPath(WKWebView.estimatedProgress):
            let value = webView.estimatedProgress
            if value > site.loadProgress || value >= 1 { site.loadProgress = value }
            if !harnessActive { beam.grow(progress: site.loadProgress) }
        case #keyPath(WKWebView.isLoading):
            site.isLoading = webView.isLoading
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    /// Temporary harness: AUGE_FAKE_PROGRESS=1 drives the loader at a known pace
    /// so the animation can be compared frame by frame against a reference.
    func startFakeProgress() {
        guard ProcessInfo.processInfo.environment["AUGE_FAKE_PROGRESS"] != nil else { return }
        fakeStart = Date()
        fakeTimer?.invalidate()
        beam.begin()
        fakeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.fakeStart else { return }
                let p = min(1, Date().timeIntervalSince(started) / 3.0)
                self.beam.grow(progress: p)
                if p >= 1 { self.beam.complete(); self.fakeTimer?.invalidate() }
            }
        }
    }

    private var fakeStart: Date?
    private var fakeTimer: Timer?

    func stopObservingProgress() {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.isLoading))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            if !harnessActive { beam.complete() }
            site.didFinishLoad(in: webView)
            return
        }
        // A sign-in popup that lands on an empty page (Google's form-post
        // callback, for instance) has already handed control back to the opener;
        // leaving it on screen is the white sheet people see after a failed
        // login. Close it once we know it is blank.
        // An OAuth provider that redirects back to the site's own domain can be
        // finished in the surface itself: loading that URL here yields the
        // session cookie, so the widget comes back signed in.
        if let popupURL = webView.url,
           let siteHost = URL(string: site.address)?.host,
           let popupHost = popupURL.host,
           popupHost == siteHost || popupHost == "www." + siteHost || siteHost == "www." + popupHost,
           popupSawForeignHost {
            debugLog("popup landed back on the site -> reloading the surface")
            popupSawForeignHost = false
            dismissPopup()
            // The popup shares this web view's cookie store, so the session is
            // already here; reload instead of loading the callback page (which
            // can be a blank hand-off page and leaves the widget black).
            self.webView.reload()
            return
        }
        if let host = webView.url?.host, host != URL(string: site.address)?.host {
            popupSawForeignHost = true
        }

        // Only the identity callback page is safe to drop: closing a real page
        // would break the flow the opener is still waiting on.
        let url = webView.url?.absoluteString ?? ""
        webView.evaluateJavaScript("JSON.stringify({h: location.host, p: location.pathname, o: !!window.opener, t: (document.body?document.body.innerText.length:-1), top: window===top, webkit: !!window.webkit, handlers: !!window.webkit?.messageHandlers, chrome: !!window.chrome, fedcm: !!window.FedCM, credsGet: !!(navigator.credentials&&navigator.credentials.get), uad: !!navigator.userAgentData, ua: navigator.userAgent.slice(0,80)})") { v, _ in
            debugLog("popup nav -> \(String(describing: v))")
        }
        let isCallback = url.contains("gis_transform") || url.contains("oauth2") == false && url.contains("gsi")
        guard isCallback || url.hasSuffix("redirect_uri") else { return }
        webView.evaluateJavaScript("(document.body ? document.body.innerText.trim().length : 0)") { [weak self, weak webView] value, _ in
            guard let self, let webView, webView === self.popup else { return }
            let length = (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
            guard length < 5 else { return }
            debugLog("popup callback blank -> closing")
            // The opener posts its credential on load; give that a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, webView === self.popup else { return }
                self.dismissPopup()
            }
        }
    }

    // MARK: Popups (sign-in with Google and friends)

    private var popup: WKWebView?
    private var popupSawForeignHost = false

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        dismissPopup()
        // WebKit requires the configuration it handed us: anything else breaks
        // the window relationship and `window.open` then returns null.
        let child = WKWebView(frame: bounds, configuration: configuration)
        child.autoresizingMask = [.width, .height]
        child.customUserAgent = site.config.userAgent.string
        child.navigationDelegate = self
        child.uiDelegate = self
        // A failed sign-in leaves a blank white sheet over the page unless the
        // popup paints like the rest of See.
        child.setValue(true, forKey: "drawsBackground")
        child.underPageBackgroundColor = NSColor(calibratedRed: 0.086, green: 0.090, blue: 0.098, alpha: 1)
        child.layer?.backgroundColor = NSColor(calibratedRed: 0.086, green: 0.090, blue: 0.098, alpha: 1).cgColor
        addSubview(child, positioned: .below, relativeTo: handles)
        popup = child
        addPopupCloseButton(over: child)
        installPopupEscape()
        // Do NOT load the request by hand: WebKit loads it into this very web
        // view as part of the window relationship, and a fresh load() throws
        // that away — `window.opener` then reads as null and Google's
        // "Sign in with Google" refuses with "a popup that can talk back".
        debugLog("popup open host=\(navigationAction.request.url?.host ?? "-") opener=\(configuration.websiteDataStore === webView.configuration.websiteDataStore)")
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView !== self.webView else { return }
        dismissPopup()
        debugLog("popup closed")
    }

    private var popupCloseButton: NSButton?
    private var popupKeyMonitor: Any?

    /// Escape closes a sign-in sheet, the way it closes a browser window.
    private func installPopupEscape() {
        guard popupKeyMonitor == nil else { return }
        popupKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popup != nil else { return event }
            guard event.keyCode == 53 else { return event }
            self.dismissPopup()
            return nil
        }
    }

    private func removePopupEscape() {
        if let popupKeyMonitor { NSEvent.removeMonitor(popupKeyMonitor) }
        popupKeyMonitor = nil
    }

    private func addPopupCloseButton(over child: WKWebView) {
        popupCloseButton?.removeFromSuperview()
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        button.contentTintColor = .white.withAlphaComponent(0.8)
        button.frame = NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 24, height: 24)
        button.autoresizingMask = [.minXMargin, .minYMargin]
        button.target = self
        button.action = #selector(closePopupTapped)
        addSubview(button)
        button.layer?.zPosition = 10
        popupCloseButton = button
    }

    @objc private func closePopupTapped() { dismissPopup() }

    private func dismissPopup() {
        removePopupEscape()
        popupSawForeignHost = false
        popup?.removeFromSuperview()
        popup = nil
        popupCloseButton?.removeFromSuperview()
        popupCloseButton = nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    var harnessActive: Bool {
        ProcessInfo.processInfo.environment["AUGE_FAKE_PROGRESS"] != nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, !harnessActive else { return }
        site.loadProgress = 0
        beam.begin()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        debugLog("nav fail \(site.title): \(error.localizedDescription)")
        if webView === self.webView { beam.complete() }
        if webView === popup { dismissPopup() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        debugLog("nav provisional fail \(site.title): \(error.localizedDescription)")
        if webView === self.webView { beam.complete() }
        if webView === popup { dismissPopup() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Without this AppKit never delivers mouseMoved, so the proximity
        // handles would never appear.
        window?.acceptsMouseMovedEvents = true
        startFakeProgress()
    }

    private var hoverTracking: NSTrackingArea?
    private var trackedSize = NSSize.zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Rebuilding an identical tracking area makes AppKit synthesize an
        // exit/enter pair under the cursor, which made the close button blink.
        guard bounds.size != trackedSize else { return }
        trackedSize = bounds.size
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func layout() {
        super.layout(); webView.frame = bounds; handles.frame = bounds; handles.needsDisplay = true
        let beamHeight: CGFloat = 18
        beam.frame = CGRect(x: 0, y: bounds.height - beamHeight, width: bounds.width, height: beamHeight)
    }

    override func mouseEntered(with event: NSEvent) {
        // WebKit only forwards pointer events to the page while the web view is
        // the first responder.
        window?.makeFirstResponder(webView)
        onHoverChange?(true); debugLog("site hover enter bounds=\(bounds)")
        handles.isNearClose = true; handles.needsDisplay = true
        updateProximity(at: convert(event.locationInWindow, from: nil))
    }

    private func updateProximity(at local: CGPoint) {
        let near = moveRect.insetBy(dx: -18, dy: -10).contains(local)
            || resizeRect.insetBy(dx: -12, dy: -12).contains(local)
        if near != handles.isNearControl { handles.isNearControl = near; handles.needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) {
        // Ignore spurious exits while the pointer is still inside the surface.
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) { return }
        onHoverChange?(false)
        debugLog("site hover exit")
        if handles.isNearControl { handles.isNearControl = false; handles.needsDisplay = true }
        if handles.isNearClose { handles.isNearClose = false; handles.needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if moveRect.contains(local) || closeRect.contains(local) { return self }
        if resizeRect.contains(local), !site.sizeLocked { return self }
        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        // The cursor is owned by SeeOverlay.updateCursor: setting it here as
        // well made it flicker between the handle cursor and the arrow.
        updateProximity(at: convert(event.locationInWindow, from: nil))
    }

    private var lastForward = CFAbsoluteTimeGetCurrent()

    /// Replays the global pointer position into the page. See's panel is never
    /// the key window, so AppKit never delivers mouse-moved events on its own
    /// and `:hover` styles (button highlights, tooltips) never fired.
    func forwardHover(atWindowPoint point: CGPoint) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastForward > 0.012, let window else { return }
        lastForward = now
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        webView.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if closeRect.contains(pt) { activeClose = true; return }
        activeHandle = moveRect.contains(pt) ? .move : (resizeRect.contains(pt) ? .resize : nil)
        debugLog("site mouseDown pt=\(pt) moveRect=\(moveRect) resizeRect=\(resizeRect) handle=\(String(describing: activeHandle)) bounds=\(bounds)")
        guard activeHandle != nil else { return }
        dragStart = event.locationInWindow; startCenter = site.center; startSize = site.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = activeHandle else { return }
        let loc = event.locationInWindow; let dx = loc.x - dragStart.x; let dy = dragStart.y - loc.y
        debugLog("site drag \(h) dx=\(dx) dy=\(dy) startSize=\(startSize)")
        var tx = Transaction(); tx.animation = nil
        withTransaction(tx) {
            if h == .move {
                let desired = CGPoint(x: startCenter.x + dx, y: startCenter.y + dy)
                site.center = AlignmentGuides.shared.snap(center: desired, size: site.size, excluding: site.id)
            }
            else {
                // Honour the real minimum: the old hard-coded 480x360 floor
                // snapped any card already smaller than that back up, which made
                // the corner feel dead.
                let floor = websiteMinSize
                let desired = CGSize(width: max(floor.width, startSize.width + dx),
                                     height: max(floor.height, startSize.height + dy))
                site.size = AlignmentGuides.shared.snap(size: desired, center: site.center, excluding: site.id)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        AlignmentGuides.shared.clear()
        if activeClose { activeClose = false; onClose?(); return }
        activeHandle = nil; handles.needsDisplay = true
    }

    private var activeClose = false

    // Proximity zones: draw targets are small; grab zone is generous
    func refreshHandles() { handles.needsDisplay = true }

    private var moveRect: CGRect { CGRect(x: bounds.midX - 52, y: bounds.height - 22, width: 104, height: 22) }
    private var resizeRect: CGRect { CGRect(x: bounds.width - 34, y: bounds.height - 34, width: 34, height: 34) }
    private var closeRect: CGRect { CGRect(x: bounds.width - 38, y: 0, width: 38, height: 38) }

    private var activeHandle: SurfaceHandleKind?
    private var dragStart = CGPoint.zero
    private var startCenter = CGPoint.zero
    private var startSize = CGSize.zero
}

@MainActor
private final class WebsiteHandleView: NSView {
    private let site: WebsiteSurface
    var isNearControl = false   // only show when near
    var isNearClose = false

    init(site: WebsiteSurface) { self.site = site; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Real AppKit hit area for the zapping pill: a SwiftUI overlay would be
    /// drawn above the page but the web view still takes the click.
    var doneRect: CGRect {
        let width = min(260, max(180, bounds.width - 40))
        return CGRect(x: bounds.midX - width / 2, y: 12, width: width, height: 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isNearClose {
            let circle = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 36, y: 8, width: 28, height: 28))
            NSColor.black.withAlphaComponent(0.72).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let x = NSBezierPath(); x.lineWidth = 1.8; x.lineCapStyle = .round
            x.move(to: CGPoint(x: bounds.maxX - 28, y: 16)); x.line(to: CGPoint(x: bounds.maxX - 16, y: 28))
            x.move(to: CGPoint(x: bounds.maxX - 16, y: 16)); x.line(to: CGPoint(x: bounds.maxX - 28, y: 28))
            x.stroke()
        }

        guard isNearControl else { return }
        let alpha: CGFloat = 0.88
        NSColor.white.withAlphaComponent(alpha).setStroke()

        // Move bar – centered at bottom
        let move = NSBezierPath(); move.lineWidth = 4; move.lineCapStyle = .round
        move.move(to: CGPoint(x: bounds.midX - 23, y: bounds.maxY - 13))
        move.line(to: CGPoint(x: bounds.midX + 23, y: bounds.maxY - 13))
        move.stroke()

        // Resize arc – rounded bottom-right
        let resize = NSBezierPath(); resize.lineWidth = 3; resize.lineCapStyle = .round
        resize.move(to: CGPoint(x: bounds.maxX - 33, y: bounds.maxY - 3))
        resize.curve(to: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 33),
                     controlPoint1: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3),
                     controlPoint2: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3))
        resize.stroke()
    }
}


/// Smallest a website card may be dragged (points).
let websiteMinSize = CGSize(width: 120, height: 90)

/// A real resize cursor where the OS has one; a two-way arrow otherwise.
func seeResizeCursor() -> NSCursor {
    if #available(macOS 15.0, *) {
        return NSCursor.frameResize(position: .bottomRight, directions: .all)
    }
    return NSCursor.resizeLeftRight
}

private enum SurfaceHandleKind: Equatable { case move, resize }

private enum SurfaceCursorZone: Equatable { case close, move, resize }

@MainActor
private final class PointerPump {
    static weak var site: WebsiteSurface?
}

@MainActor
private final class FnState { static var held = false }

@MainActor
private final class CursorZoneState {
    static var key: String = ""
    static var applied: NSCursor?
}

/// Handle hit zones in screen coordinates, matching the surface's control layout.
private func surfaceCursorZone(_ p: CGPoint, _ rect: CGRect, close: Bool) -> SurfaceCursorZone? {
    // Kept tight on purpose: the page's own links and buttons live right next
    // to these edges and the handles used to swallow them.
    let resize = CGRect(x: rect.maxX - 30, y: rect.maxY - 30, width: 30, height: 30)
    let move = CGRect(x: rect.midX - 52, y: rect.maxY - 22, width: 104, height: 22)
    let closeRect = CGRect(x: rect.maxX - 38, y: rect.minY, width: 38, height: 38)
    if close && closeRect.contains(p) { return .close }
    if resize.contains(p) { return .resize }
    if move.contains(p) { return .move }
    return nil
}

/// A short message that slides up from the bottom of the workspace.
@MainActor
private struct ToastBanner: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.35))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.45)))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .padding(.bottom, 54)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: message)
    }
}

@MainActor
private final class UndoMeter: ObservableObject {
    @Published var remaining: CGFloat = 1
}

/// A five-second offer to undo a removal. The border drains from green to red.
@MainActor
private struct UndoOfferPill: View {
    let id: UUID
    let center: CGPoint
    let onUndo: () -> Void
    let onExpire: () -> Void
    @StateObject private var meter = UndoMeter()

    private var tint: Color {
        Color(hue: 0.33 * Double(meter.remaining), saturation: 0.72, brightness: 0.92)
    }

    var body: some View {
        Group {
            HStack(spacing: 7) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text("Undo").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.black.opacity(0.35)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .trim(from: 0, to: meter.remaining)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
            }
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            MenuHover.shared.setAction("undo:" + id.uuidString, onUndo)
                            MenuHover.shared.register("undo:" + id.uuidString, proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, new in
                            MenuHover.shared.register("undo:" + id.uuidString, new)
                        }
                }
            }
            .onTapGesture(perform: onUndo)
        }
        .position(x: center.x, y: center.y)
        .onAppear {
            meter.remaining = 1
            withAnimation(.linear(duration: 5)) { meter.remaining = 0 }
        }
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            onExpire()
        }
        .onDisappear { MenuHover.shared.clear("undo:" + id.uuidString) }
    }
}

private struct RoundedResizeCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - 1, y: rect.minY), control: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1))
        return p
    }
}

// MARK: - Drag-create rubber band overlay

private struct DragCreatingOverlay: View {
    let rect: CGRect
    var body: some View {
        if rect != .null && rect.width > 40 && rect.height > 40 {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [7, 4]))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .animation(.linear(duration: 0), value: rect)
        }
    }
}

// MARK: - Placed surfaces
// Each surface observes its own geometry so dragging re-renders only that
// surface instead of invalidating the entire workspace (which caused jitter).

@MainActor
private struct PlacedWebsiteView: View {
    @ObservedObject var site: WebsiteSurface
    let isFocused: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    let onPick: (String) -> Void

    var body: some View {
        WebsiteSurfaceView(site: site, isFocused: isFocused, onFocus: onFocus, onClose: onClose, onPick: onPick)
            .overlay {
                if let provider = site.authNotice {
                    AuthNoticeCard(provider: provider,
                                   onEmail: { site.dismissAuthNotice() },
                                   onBrowser: { site.openInBrowser(); site.dismissAuthNotice() },
                                   onDismiss: { site.dismissAuthNotice() })
                }
            }
            .position(x: site.center.x, y: site.center.y)
    }
}

/// Shown when a site starts a sign-in that an embedded WebKit view cannot
/// finish (Google One Tap needs FedCM, popups have no `window.opener`).
@MainActor
private struct AuthNoticeCard: View {
    let provider: String
    let onEmail: () -> Void
    let onBrowser: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.35))
                Text("\(provider) sign-in can't finish here")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer(minLength: 6)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("This provider needs a browser feature WebKit doesn't give embedded views (FedCM, or a popup that can talk back to the page). Use the site's email and password instead, or sign in in your browser.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onEmail) {
                    Text("Use email")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain)
                Button(action: onBrowser) {
                    Text("Open in Browser")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.92), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.55)))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        .padding(18)
    }
}

@MainActor
private struct PlacedWidgetView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let onClose: () -> Void

    var body: some View {
        NativeWidgetView(widget: widget, onClose: onClose)
            .position(x: widget.center.x, y: widget.center.y)
    }
}


// MARK: - Ad blocking

/// Content blocking built from real filter lists (AdGuard Base's ad-server
/// section plus EasyList's), compiled into a WKContentRuleList and cached so
/// later launches do not wait. A small built-in list is installed immediately;
/// the downloaded list replaces it as soon as it compiles.
@MainActor
private final class AdBlocker: ObservableObject {
    static let shared = AdBlocker()

    @Published private(set) var list: WKContentRuleList?
    @Published private(set) var ruleCount = 0

    weak var model: OverlayModel?

    private static let identifier = "see-adblock"
    private static let cacheVersion = 4

    /// Enough to cover the worst offenders before anything is downloaded.
    private static let builtIn = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "adservice.google.com",
        "scorecardresearch.com", "quantserve.com", "moatads.com", "adnxs.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "criteo.com",
        "criteo.net", "taboola.com", "outbrain.com", "amazon-adsystem.com",
        "adsrvr.org", "casalemedia.com", "33across.com", "hotjar.com",
        "mixpanel.com", "segment.io", "amplitude.com", "appsflyer.com",
        "connect.facebook.net", "sc-static.net", "tr.snapchat.com"
    ]

    static let sources = [
        "https://raw.githubusercontent.com/AdguardTeam/AdGuardFilters/master/BaseFilter/sections/adservers.txt",
        "https://raw.githubusercontent.com/easylist/easylist/master/easylist/easylist_adservers.txt"
    ]

    func prepare() {
        if let cached = Self.cachedRuleJSON() {
            compile(cached, note: "cached")
        } else {
            compile(Self.ruleJSON(for: Self.builtIn), note: "built-in")
            Task { await refresh() }
        }
    }

    private func refresh() async {
        var domains = Set<String>()
        for url in Self.sources {
            guard let u = URL(string: url) else { continue }
            var request = URLRequest(url: u)
            request.timeoutInterval = 20
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("||") else { continue }
                var host = trimmed.dropFirst(2)
                if let stop = host.firstIndex(where: { $0 == "^" || $0 == "$" || $0 == "/" }) {
                    host = host[host.startIndex..<stop]
                }
                let domain = host.lowercased()
                guard !domain.isEmpty, !domain.contains("*"), !domain.contains(" "),
                      domain.contains(".") else { continue }
                domains.insert(domain)
            }
        }
        guard !domains.isEmpty else {
            debugLog("adblock: no domains downloaded, keeping built-in")
            return
        }
        let capped = Array(domains.sorted().prefix(40_000))
        let json = Self.ruleJSON(for: capped)
        Self.storeCache(json)
        compile(json, note: "downloaded \(capped.count)")
    }

    private func compile(_ json: String, note: String) {
        let started = Date()
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: Self.identifier,
                                                                encodedContentRuleList: json) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil, let list else {
                    debugLog("adblock: compile failed (\(note)) \(error?.localizedDescription ?? "-")")
                    // A cached list that no longer compiles must not block the
                    // real download forever.
                    if note == "cached" {
                        Self.clearCache()
                        Task { await self.refresh() }
                    }
                    return
                }
                self.list = list
                self.ruleCount = json.components(separatedBy: "\"action\"").count - 1
                debugLog(String(format: "adblock: %.1fs %@ rules=%d",
                                Date().timeIntervalSince(started), note, self.ruleCount))
                self.applyToLiveSurfaces()
            }
        }
    }

    private func applyToLiveSurfaces() {
        guard let model, let list else { return }
        for site in model.websites {
            guard let controller = site.webView?.configuration.userContentController else { continue }
            controller.removeAllContentRuleLists()
            controller.add(list)
        }
    }

    private static func ruleJSON(for domains: [String]) -> String {
        let rules: [[String: Any]] = domains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            // WebKit's content-blocker regex engine rejects disjunction groups
            // (`([:/]|$)`), so the host is matched as a prefix instead.
            return ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)*\(escaped)"],
                    "action": ["type": "block"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static var cacheURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let dir = base.appendingPathComponent("Auge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("adblock-v\(cacheVersion).json")
    }

    private static func cachedRuleJSON() -> String? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        let age = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        if let age, Date().timeIntervalSince(age) > 7 * 86_400 { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func clearCache() {
        guard let url = cacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func storeCache(_ json: String) {
        guard let url = cacheURL else { return }
        try? json.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

// MARK: - Passkeys

/// Passkeys ("Sign in with Google/Apple" with Face ID or Touch ID) only work in
/// a WKWebView when the host app adopts the browser side of WebAuthn: WebKit
/// hands the request to the system credential manager instead of its own
/// sandboxed UI. Peek does this; without it every site falls back to passwords.
@MainActor
private final class PasskeyBridge {
    static let shared = PasskeyBridge()

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()

    private(set) var authorized: Bool = false

    func start() {
        let state = manager.authorizationStateForPlatformCredentials
        debugLog("passkeys state \(state.rawValue)")
        switch state {
        case .authorized:
            authorized = true
        case .notDetermined:
            manager.requestAuthorizationForPublicKeyCredentials { [weak self] state in
                Task { @MainActor in
                    self?.authorized = (state == .authorized)
                    debugLog("passkeys requested -> \(state.rawValue)")
                }
            }
        default:
            authorized = false
        }
    }
}

// MARK: - Alignment guides

/// Peek-style cue lines while a surface is dragged or resized: when an edge or
/// centre comes within a few points of another surface's, the surface snaps and
/// the matching line is drawn across the workspace.
@MainActor
private final class AlignmentGuides: ObservableObject {
    static let shared = AlignmentGuides()

    @Published private(set) var verticals: [CGFloat] = []
    @Published private(set) var horizontals: [CGFloat] = []

    weak var model: OverlayModel?

    private let threshold: CGFloat = 6

    func clear() {
        if !verticals.isEmpty { verticals = [] }
        if !horizontals.isEmpty { horizontals = [] }
    }

    private func otherRects(excluding id: UUID) -> [CGRect] {
        guard let model else { return [] }
        var rects: [CGRect] = []
        for site in model.websites where site.id != id {
            rects.append(CGRect(x: site.center.x - site.size.width / 2,
                                y: site.center.y - site.size.height / 2,
                                width: site.size.width, height: site.size.height))
        }
        for widget in model.widgets where widget.id != id {
            rects.append(CGRect(x: widget.center.x - widget.size.width / 2,
                                y: widget.center.y - widget.size.height / 2,
                                width: widget.size.width, height: widget.size.height))
        }
        return rects
    }

    /// Nearest alignment for one axis, if any is within the threshold.
    private func bestAlignment(mine: [CGFloat], targets: [CGFloat]) -> (delta: CGFloat, line: CGFloat)? {
        var best: (delta: CGFloat, line: CGFloat)?
        for target in targets {
            for value in mine {
                let delta = target - value
                guard abs(delta) <= threshold else { continue }
                if best == nil || abs(delta) < abs(best!.delta) { best = (delta, target) }
            }
        }
        return best
    }

    /// Moving: snap any edge or the centre on either axis.
    func snap(center desired: CGPoint, size: CGSize, excluding id: UUID) -> CGPoint {
        let rects = otherRects(excluding: id)
        guard !rects.isEmpty else { clear(); return desired }
        var center = desired
        let halfW = size.width / 2, halfH = size.height / 2
        let x = bestAlignment(mine: [center.x - halfW, center.x, center.x + halfW],
                             targets: rects.flatMap { [$0.minX, $0.midX, $0.maxX] })
        let y = bestAlignment(mine: [center.y - halfH, center.y, center.y + halfH],
                              targets: rects.flatMap { [$0.minY, $0.midY, $0.maxY] })
        if let x { center.x += x.delta }
        if let y { center.y += y.delta }
        verticals = x.map { [$0.line] } ?? []
        horizontals = y.map { [$0.line] } ?? []
        return center
    }

    /// Resizing from the bottom-right: snap only the edges being dragged, so the
    /// anchored corner never jumps.
    func snap(size desired: CGSize, center: CGPoint, excluding id: UUID) -> CGSize {
        let rects = otherRects(excluding: id)
        guard !rects.isEmpty else { clear(); return desired }
        var size = desired
        let right = center.x + size.width / 2
        let bottom = center.y + size.height / 2
        let x = bestAlignment(mine: [right], targets: rects.flatMap { [$0.minX, $0.midX, $0.maxX] })
        let y = bestAlignment(mine: [bottom], targets: rects.flatMap { [$0.minY, $0.midY, $0.maxY] })
        if let x { size.width = max(40, size.width + x.delta) }
        if let y { size.height = max(40, size.height + y.delta) }
        verticals = x.map { [$0.line] } ?? []
        horizontals = y.map { [$0.line] } ?? []
        return size
    }
}

/// The cue lines themselves: hair-thin cyan, with a little bloom so they read
/// over photographs as well as dark pages.
private struct AlignmentGuideOverlay: View {
    @ObservedObject var guides = AlignmentGuides.shared

    private var color: Color { Color(red: 0.40, green: 0.86, blue: 1.0) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(guides.verticals.enumerated()), id: \.offset) { _, x in
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .frame(width: 1, height: geo.size.height)
                        .shadow(color: color.opacity(0.9), radius: 4)
                        .position(x: x, y: geo.size.height / 2)
                }
                ForEach(Array(guides.horizontals.enumerated()), id: \.offset) { _, y in
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .frame(width: geo.size.width, height: 1)
                        .shadow(color: color.opacity(0.9), radius: 4)
                        .position(x: geo.size.width / 2, y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Root overlay

@MainActor
private struct SeeOverlay: View {
    let onClose: () -> Void
    @ObservedObject var model: OverlayModel

    private let white = Color.white
    private let dim = Color.white.opacity(0.58)
    @StateObject private var menuSizes = MenuSizes()
    @StateObject private var anim = PeekAnimationState()
    @StateObject private var pointer = PointerWatch()
    private var appeared: Bool { anim.appeared }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                model.backgroundStyle.base.opacity(model.backgroundDim).ignoresSafeArea()
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.34), value: appeared)
                RadialGradient(colors: [model.backgroundStyle.tint, .clear],
                               center: UnitPoint(x: 0.5, y: 0.45),
                               startRadius: 40, endRadius: size.height * 0.95)
                    .ignoresSafeArea()
                    .opacity(model.backgroundGlow)
                    .scaleEffect(appeared ? 1 : 1.03)
                    .animation(.easeOut(duration: 0.3), value: appeared)
                RadialGradient(colors: [model.backgroundStyle.secondary, .clear],
                               center: UnitPoint(x: 0.78, y: 0.82),
                               startRadius: 30, endRadius: size.height * 0.75)
                    .ignoresSafeArea()
                    .opacity(model.backgroundGlow * 0.9)
                    .scaleEffect(appeared ? 1 : 1.03)
                    .animation(.easeOut(duration: 0.3), value: appeared)

                // Website surfaces
                ForEach(Array(model.websites.enumerated()), id: \.element.id) { index, site in
                    PlacedWebsiteView(site: site,
                                      isFocused: model.focusedID == site.id,
                                      onFocus: { model.focusedID = site.id },
                                      onClose: { model.remove(site) },
                                      onPick: { _ in })
                        .scaleEffect(appeared ? 1 : 0.97)
                        .opacity(surfaceOpacity(appeared ? 1 : 0, for: site))
                        .animation(.spring(response: 0.26, dampingFraction: 0.74)
                            .delay(Double(index) * 0.012), value: appeared)
                        .animation(.easeOut(duration: 0.18), value: model.configuring?.id)
                        .zIndex(site.z)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.92))))
                }

                // Native widget surfaces
                ForEach(Array(model.widgets.enumerated()), id: \.element.id) { index, widget in
                    PlacedWidgetView(widget: widget, onClose: { model.removeWidget(widget) })
                        .scaleEffect(appeared ? 1 : 0.95)
                        .opacity(model.configuring == nil ? (appeared ? 1 : 0) : 0)
                        .animation(.spring(response: 0.26, dampingFraction: 0.74)
                            .delay(Double(model.websites.count + index) * 0.012), value: appeared)
                        .zIndex(widget.z)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.92))))
                }

                AlignmentGuideOverlay()
                    .zIndex(58)

                // Transient message, e.g. when a tidy cannot fit locked sizes
                if let toast = model.toast {
                    ToastBanner(message: toast)
                        .zIndex(70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Undo a removal, right where the surface was
                if let offer = model.undoOffer {
                    UndoOfferPill(id: offer.id,
                                  center: offer.center,
                                  onUndo: { model.performUndo() },
                                  onExpire: { model.expireUndo(offer.id) })
                        .id(offer.id)
                        .zIndex(55)
                }

                // Drag-creating rubber band
                DragCreatingOverlay(rect: model.dragCreatingRect)

                VStack(spacing: 0) {
                    topBar(size: size)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).padding(.top, 46).padding(.bottom, 24)
                .offset(y: appeared ? 0 : -10)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.24, dampingFraction: 0.7).delay(0.01), value: appeared)
                .zIndex(60)   // chrome stays usable above live website surfaces

                ChromeOverlay(model: model, onCloseOverlay: onClose)
                    .zIndex(100)
            }
            .frame(width: size.width, height: size.height)
            .onAppear {
                AlignmentGuides.shared.model = model
                AdBlocker.shared.model = model
            }
            .onChange(of: model.websites.count) {
                AlignmentGuides.shared.model = model
                AdBlocker.shared.model = model
            }
            .background {
                WorkspaceInteractionMonitor(
                    onRightClick: { pt in
                        if model.website(at: pt) != nil || model.widget(at: pt) != nil {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                                model.contextMenuPoint = nil
                                model.workspacePanel = nil
                                model.openSurfaceMenu(at: pt)
                            }
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                model.surfaceMenu = nil
                                model.contextMenuPoint = pt; model.workspacePanel = nil
                            }
                        }
                    },
                    onDismiss: { point in
                        withAnimation(.easeOut(duration: 0.16)) {
                            model.contextMenuPoint = nil; model.surfaceMenu = nil
                        }
                        // Clicking away from a zapping surface ends the session,
                        // but the settings panel lives outside that surface and
                        // must stay usable.
                        let panelStrip = CGRect(x: size.width - 520, y: 0, width: 520, height: size.height)
                        if panelStrip.contains(point) { return }
                        for site in model.websites where site.isPickingElements {
                            let rect = CGRect(x: site.center.x - site.size.width / 2,
                                              y: site.center.y - site.size.height / 2,
                                              width: site.size.width, height: site.size.height)
                            if !rect.contains(point) { site.setPicking(false) }
                        }
                    },
                    isSurfaceAt: { pt in isPointOverSurface(pt, size: size) },
                    contextMenuFrame: { activeMenuFrame(in: size) },
                    onTouch: { point in model.raiseSurface(at: point) },
                    onZapAt: { point in
                        guard let site = model.websites.first(where: { $0.isPickingElements }) else { return false }
                        let rect = CGRect(x: site.center.x - site.size.width / 2,
                                          y: site.center.y - site.size.height / 2,
                                          width: site.size.width, height: site.size.height)
                        guard rect.contains(point) else { return false }
                        site.zap(at: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY))
                        return true
                    },
                    onDragCreating: { rect in model.dragCreatingRect = rect },
                    onDragCreated: { rect in
                        debugLog("drag created \(rect)")
                        model.dragCreatingRect = .null
                        if rect.width > 80 {
                            // Let this mouse-up finish dispatching first: a picker
                            // created inside the event would receive the same up and
                            // immediately close itself through its backdrop tap.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                model.pendingPickerForRect = rect
                                model.pickerCategory = .websites
                                model.pickerSearch = ""
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    model.showingWidgetPicker = true
                                }
                            }
                            debugLog("picker opened from drag")
                        }
                    }
                )
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            }
            .onChange(of: size) { _, new in model.workspaceSize = new }
            .onChange(of: model.chromeVisible) { _, visible in
                for site in model.websites {
                    // A surface being zapped must stay live: the snapshot would
                    // freeze the page the user is clicking on.
                    if visible && !site.isPickingElements && model.configuring !== site {
                        site.enterChromeMode()
                    } else {
                        site.exitChromeMode()
                    }
                }
            }
            .onAppear {
                pointer.start { globalPoint in routeHover(globalPoint) }
                model.workspaceSize = size
                debugLog("overlay appear active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.title))")
                setAppeared(true)
                guard !model.hasPlacedInitialSite else { return }
                model.hasPlacedInitialSite = true
            }
        }
        .onExitCommand { dismissTopmost() }
        .onReceive(NotificationCenter.default.publisher(for: .seeEscape)) { _ in dismissTopmost() }
        .onReceive(NotificationCenter.default.publisher(for: .seePeekOpened)) { _ in
            setAppeared(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { setAppeared(true) }
            for site in model.websites { site.refreshOnPeekIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seePeekClosed)) { _ in
            withAnimation(.easeIn(duration: 0.16)) { setAppeared(false) }
        }
        .preferredColorScheme(.dark)
    }

    private func setAppeared(_ value: Bool) { anim.appeared = value }

    private func routeHover(_ screenPoint: CGPoint) {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let p = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        MenuHover.shared.update(point: p)
        updateCursor(at: p)
        // Feed the pointer to the page under it, so `:hover` styles and
        // tooltips inside a website behave as they do in a browser.
        if let site = model.website(at: p) {
            if let previous = PointerPump.site, previous !== site { previous.clearHover() }
            PointerPump.site = site
        } else if let previous = PointerPump.site {
            PointerPump.site = nil
            previous.clearHover()
        }
        guard model.websites.contains(where: { $0.isPickingElements }) else { return }
        for site in model.websites where site.isPickingElements {
            let frame = CGRect(x: site.center.x - site.size.width / 2,
                               y: site.center.y - site.size.height / 2,
                               width: site.size.width, height: site.size.height)
            if frame.contains(p) {
                site.hoverAt(CGPoint(x: p.x - frame.minX, y: p.y - frame.minY))
            }
        }
    }

    // The handles' own tracking areas stay quiet while See's non-activating
    // panel is not the key window, so drive the cursor from the global pointer.
    private func updateCursor(at p: CGPoint) {
        let menuOpen = model.contextMenuPoint != nil || model.surfaceMenu != nil
            || model.configuring != nil || model.showingWidgetPicker
        guard !menuOpen, model.websites.allSatisfy({ !$0.isPickingElements }) else {
            setCursor(zone: nil, page: "default")
            return
        }

        var zone: SurfaceCursorZone?
        var siteUnderPointer: WebsiteSurface?
        var siteLocal = CGPoint.zero
        for site in model.websites {
            let rect = CGRect(x: site.center.x - site.size.width / 2,
                              y: site.center.y - site.size.height / 2,
                              width: site.size.width, height: site.size.height)
            if rect.contains(p) {
                zone = surfaceCursorZone(p, rect, close: true)
                siteUnderPointer = site
                siteLocal = CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
                break
            }
        }
        if zone == nil && siteUnderPointer == nil {
            for widget in model.widgets {
                let rect = CGRect(x: widget.center.x - widget.size.width / 2,
                                  y: widget.center.y - widget.size.height / 2,
                                  width: widget.size.width, height: widget.size.height)
                if rect.contains(p) { zone = surfaceCursorZone(p, rect, close: false); break }
            }
        }
        // A handle wins over the page; otherwise the page decides (links, text,
        // draggable elements), which is what makes browsing feel native.
        if let site = siteUnderPointer, zone == nil {
            site.probeCursor(at: siteLocal)
        }
        setCursor(zone: zone, page: zone == nil ? (siteUnderPointer?.pageCursor ?? "default") : "default")
    }

    private func setCursor(zone: SurfaceCursorZone?, page: String) {
        let key = "\(zone.map(String.init(describing:)) ?? "-")|\(page)"
        let cursor: NSCursor = {
            switch zone {
            case .close: return .pointingHand
            case .move: return .openHand
            case .resize: return seeResizeCursor()
            case nil: break
            }
            switch page {
            case "pointer", "hand": return .pointingHand
            case "text", "vertical-text": return .iBeam
            case "crosshair", "cell": return .crosshair
            case "grab": return .openHand
            case "grabbing", "move", "all-scroll": return .closedHand
            case "col-resize", "e-resize", "w-resize", "ew-resize": return .resizeLeftRight
            case "row-resize", "n-resize", "s-resize", "ns-resize": return .resizeUpDown
            case "not-allowed", "no-drop": return .operationNotAllowed
            case "help": return .contextualMenu
            default: return .arrow
            }
        }()
        if key != CursorZoneState.key {
            CursorZoneState.key = key
            CursorZoneState.applied = cursor
            debugLog("cursor \(key)")
        }
        cursor.set()
        // AppKit's cursor rects and WebKit's own hover handling run later in the
        // same event pass, which made the pointer flicker between two cursors.
        DispatchQueue.main.async { cursor.set() }
    }

    private func dismissTopmost() {
        debugLog("dismissTopmost picker=\(model.showingWidgetPicker) menu=\(model.contextMenuPoint != nil) surface=\(model.surfaceMenu != nil)")
        debugLog("dismissTopmost picking=\(model.websites.contains(where: { $0.isPickingElements })) configuring=\(model.configuring != nil)")
        if let picking = model.websites.first(where: { $0.isPickingElements }) {
            picking.setPicking(false)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { model.configuring = picking }
        } else if let site = model.configuring {
            if site.isPickingElements {
                site.setPicking(false)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { model.configuring = site }
            } else {
                withAnimation(.easeOut(duration: 0.18)) { model.configuring = nil }
            }
        } else if model.showingWidgetPicker {
            withAnimation(.easeOut(duration: 0.18)) {
                model.showingWidgetPicker = false
                model.pendingPickerForRect = nil
                model.dragCreatingRect = .null
            }
        } else if model.surfaceMenu != nil {
            withAnimation(.easeOut(duration: 0.16)) { model.surfaceMenu = nil }
        } else if model.contextMenuPoint != nil {
            withAnimation(.easeOut(duration: 0.16)) { model.contextMenuPoint = nil }
        } else if model.workspacePanel != nil {
            withAnimation(.easeOut(duration: 0.18)) { model.workspacePanel = nil }
        } else {
            onClose()
        }
    }

    // MARK: Helpers

    private func hideSeeWindow() {
        onClose()
    }

    private func siteCenter(_ site: WebsiteSurface, index: Int, size: CGSize) -> CGPoint {
        site.center == .zero
            ? CGPoint(x: size.width * 0.51 + CGFloat(index * 42), y: size.height * 0.52 - CGFloat(index * 28))
            : site.center
    }

    private func widgetCenter(_ widget: NativeWidgetSurface, index: Int, size: CGSize) -> CGPoint {
        widget.center == .zero
            ? CGPoint(x: size.width * 0.55 + CGFloat(index * 36), y: size.height * 0.54 - CGFloat(index * 28))
            : widget.center
    }

    private func activeMenuFrame(in size: CGSize) -> CGRect? {
        if let pt = model.contextMenuPoint {
            let o = menuOrigin(for: pt, size: size, menu: menuSizes.workspace)
            return CGRect(origin: o, size: MenuMetrics.workspace)
        }
        if let menu = model.surfaceMenu {
            let o = menuOrigin(for: menu.point, size: size, menu: menuSizes.surface)
            return CGRect(origin: o, size: menuSizes.surface)
        }
        return nil
    }

    /// While a settings panel is open only the surface it belongs to stays on
    /// screen; everything else steps aside so the page is easy to work with.
    private func surfaceOpacity(_ base: Double, for site: WebsiteSurface) -> Double {
        guard let target = model.configuring else { return base }
        return target === site ? base : 0
    }

    private func isPointOverSurface(_ pt: CGPoint, size: CGSize) -> Bool {
        for (i, site) in model.websites.enumerated() {
            let c = siteCenter(site, index: i, size: size)
            if CGRect(x: c.x - site.size.width/2, y: c.y - site.size.height/2,
                      width: site.size.width, height: site.size.height).contains(pt) { return true }
        }
        for (i, widget) in model.widgets.enumerated() {
            let c = widgetCenter(widget, index: i, size: size)
            if CGRect(x: c.x - widget.size.width/2, y: c.y - widget.size.height/2,
                      width: widget.size.width, height: widget.size.height).contains(pt) { return true }
        }
        return false
    }

    // MARK: Top / bottom bars

    private func pinToggle() {
        if model.pinned {
            if FnState.held {
                model.pinned = false
            } else {
                onClose()
            }
        } else {
            model.pinned = true
        }
    }

    private func topBar(size: CGSize) -> some View {
        HStack(spacing: 14) {
            Spacer()
            HStack(spacing: 8) {
                let count = model.websites.count + model.widgets.count
                if count > 0 {
                    Text("\(count) \(count == 1 ? "vision" : "visions")")
                        .font(.system(size: 11, weight: .regular)).foregroundStyle(.tertiary)
                }
                // Handled on mouse-down by the click monitor only: a SwiftUI
                // Button here would fire a second time on the release.
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.pinned ? Color.accentColor : Color.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
                    .contentShape(Circle())
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    MenuHover.shared.setAction("tb:pin", pinToggle)
                                    MenuHover.shared.register("tb:pin", proxy.frame(in: .global))
                                }
                                .onChange(of: proxy.frame(in: .global)) { _, new in
                                    MenuHover.shared.register("tb:pin", new)
                                }
                        }
                    }
                .help(model.pinned ? "Unpin — release Fn to close" : "Pin — keep open after Fn is released")

                Button {
                    debugLog("topBar add pressed")
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.pickerCategory = .websites; model.pickerSearch = ""; model.showingWidgetPicker = true
                    }
                } label: {
                    Label("Add", systemImage: "plus").background {
                        GeometryReader { px in
                            Color.clear
                                .onAppear { MenuHover.shared.register("tb:add", px.frame(in: .global)) }
                                .onChange(of: px.frame(in: .global)) { _, new in
                                    MenuHover.shared.register("tb:add", new)
                                }
                        }
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }.buttonStyle(.plain).help("Close Auge")
            }
        }.foregroundStyle(white)
    }

    private var bottomBar: some View {
        HStack {
            Label("Freeform workspace", systemImage: "square.grid.2x2")
            Spacer()
            Text("Drag empty space to create · Right-click for options")
            Spacer()
            Text("Esc  Close")
        }
        .font(.system(size: 11, weight: .regular)).foregroundStyle(.tertiary)
    }
}

// MARK: - Hover state helpers (ObservableObject avoids Swift 6 Sendable issues)

@MainActor
private final class PointerWatch: ObservableObject {
    private var global: Any?
    private var local: Any?

    func start(_ handler: @escaping (CGPoint) -> Void) {
        guard global == nil else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in handler(point) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in handler(point) }
            return event
        }
    }
}

@MainActor
private final class PeekAnimationState: ObservableObject {
    @Published var appeared = false
}

@MainActor
private final class HoverState: ObservableObject {
    @Published var showClose = false
    @Published var nearMove = false
    @Published var nearResize = false

    // A short grace period keeps the close button from flickering when the
    // pointer crosses the tracking-area edge or lands on the button itself.
    private var hideTask: Task<Void, Never>?

    func setHovering(_ inside: Bool) {
        hideTask?.cancel()
        guard !inside else { if !showClose { showClose = true }; return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            self?.showClose = false
        }
    }
}

// MARK: - Website surface card

@MainActor
private struct WebsiteSurfaceView: View {
    @ObservedObject var site: WebsiteSurface
    let isFocused: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    let onPick: (String) -> Void

    var body: some View {
        WebsiteView(site: site, onHoverChange: { _ in }, onClose: onClose, onPick: onPick)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: site.size.width, height: site.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if let shot = site.chromeSnapshot {
                    Image(nsImage: shot)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: site.size.width, height: site.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .overlay {
                if site.isPickingElements {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(isFocused ? 0.34 : 0.22), radius: isFocused ? 34 : 22, y: 14)
            .onTapGesture(perform: onFocus)
    }
}

/// Frosted glass that samples the screen *behind* See's window. A plain SwiftUI
/// material only blends with what is inside the window, so See's own dim layer
/// and gradient tinted every widget; this reads the real background instead.
private struct BehindWindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// Black tint over the blur: pitch black, still see-through.
    var scrim: Double = 0.38

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        let dark = NSView()
        dark.wantsLayer = true
        dark.layer?.backgroundColor = NSColor.black.withAlphaComponent(scrim).cgColor
        dark.autoresizingMask = [.width, .height]
        view.addSubview(dark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.subviews.first?.layer?.backgroundColor = NSColor.black.withAlphaComponent(scrim).cgColor
    }
}

// MARK: - Native widget card

/// AppKit drag handler that gives jitter-free move/resize for native widgets.
@MainActor
private struct WidgetDragHandler: NSViewRepresentable {
    @ObservedObject var widget: NativeWidgetSurface
    let onHoverChange: (Bool) -> Void
    let onMoveActive: (Bool) -> Void
    let onResizeActive: (Bool) -> Void

    func makeNSView(context: Context) -> WidgetDragView {
        let v = WidgetDragView()
        v.widget = widget; v.onHoverChange = onHoverChange
        v.onMoveActive = onMoveActive; v.onResizeActive = onResizeActive
        return v
    }
    func updateNSView(_ v: WidgetDragView, context: Context) {
        v.widget = widget; v.onHoverChange = onHoverChange
        v.onMoveActive = onMoveActive; v.onResizeActive = onResizeActive
    }
}

@MainActor
private final class WidgetDragView: NSView {
    var widget: NativeWidgetSurface?
    var onHoverChange: ((Bool) -> Void)?
    var onMoveActive: ((Bool) -> Void)?
    var onResizeActive: ((Bool) -> Void)?

    private var activeHandle: SurfaceHandleKind?
    private var dragStart = CGPoint.zero
    private var startCenter = CGPoint.zero
    private var startSize = CGSize.zero

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    init() {
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var hoverTracking: NSTrackingArea?
    private var trackedSize = NSSize.zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard bounds.size != trackedSize else { return }
        trackedSize = bounds.size
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(local) else { return }
        NSCursor.arrow.set()
        onHoverChange?(false)
        onMoveActive?(false); onResizeActive?(false)
    }

    // Move zone: bottom-center bar; Resize zone: bottom-right corner
    private var moveRect: CGRect {
        CGRect(x: bounds.midX - 52, y: bounds.height - 22, width: 104, height: 22)
    }
    private var resizeRect: CGRect {
        CGRect(x: bounds.width - 34, y: bounds.height - 34, width: 34, height: 34)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if moveRect.contains(local) { return self }
        if resizeRect.contains(local), widget?.sizeLocked != true { return self }
        return nil   // let SwiftUI content handle everything else
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let nearMove = moveRect.insetBy(dx: -16, dy: -8).contains(pt)
        let nearResize = resizeRect.insetBy(dx: -8, dy: -8).contains(pt)
        onMoveActive?(nearMove); onResizeActive?(nearResize)
        if moveRect.contains(pt) { NSCursor.openHand.set() }
        else if resizeRect.contains(pt) { seeResizeCursor().set() }
        else if nearResize { seeResizeCursor().set() }
        else if nearMove { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        activeHandle = moveRect.contains(pt) ? .move : (resizeRect.contains(pt) ? .resize : nil)
        guard let w = widget, activeHandle != nil else { return }
        w.isDragging = true
        dragStart = event.locationInWindow; startCenter = w.center; startSize = w.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = activeHandle, let w = widget else { return }
        let loc = event.locationInWindow
        let dx = loc.x - dragStart.x; let dy = dragStart.y - loc.y
        // Direct, unanimated model writes. Implicit springs were making the
        // widget trail the pointer and leave ghost frames behind.
        if h == .move {
            let desired = CGPoint(x: startCenter.x + dx, y: startCenter.y + dy)
            w.center = AlignmentGuides.shared.snap(center: desired, size: w.size, excluding: w.id)
        } else {
            let floor = w.kind.minSize
            let desired = CGSize(width: max(floor.width, startSize.width + dx),
                                 height: max(floor.height, startSize.height + dy))
            w.size = AlignmentGuides.shared.snap(size: desired, center: w.center, excluding: w.id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        widget?.isDragging = false
        AlignmentGuides.shared.clear()
        // If the drag carried the widget away from the pointer, the tracking
        // area never sent an exit; clear the hover chrome explicitly.
        let local = convert(event.locationInWindow, from: nil)
        if !bounds.contains(local) {
            onHoverChange?(false); onMoveActive?(false); onResizeActive?(false)
        }
    }
}

@MainActor
private struct NativeWidgetView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let onClose: () -> Void
    private let ink = Color.white.opacity(0.92)

    @StateObject private var hover = HoverState()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Widget content layer
            widgetContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .frame(width: widget.size.width, height: widget.size.height)
                .background {
                    BehindWindowGlass()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                .compositingGroup()
                .shadow(color: .black.opacity(widget.isDragging ? 0.22 : 0.28),
                        radius: widget.isDragging ? 18 : 32, y: widget.isDragging ? 8 : 16)
                // Move bar drawn in SwiftUI (visual only, hits handled by WidgetDragView)
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white.opacity(hover.nearMove ? 0.88 : 0))
                        .frame(width: 54, height: 5).padding(.bottom, 10)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.16), value: hover.nearMove)
                }
                // Resize arc visual only
                .overlay(alignment: .bottomTrailing) {
                    RoundedResizeCorner()
                        .stroke(.white.opacity(hover.nearResize ? 0.88 : 0),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: 30, height: 30).padding(6)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.16), value: hover.nearResize)
                }
                // AppKit drag/resize layer on top (handles hit-testing and dragging)
                .overlay {
                    WidgetDragHandler(widget: widget,
                                      onHoverChange: { hover.setHovering($0) },
                                      onMoveActive: { hover.nearMove = $0 },
                                      onResizeActive: { hover.nearResize = $0 })
                }
                // SwiftUI-driven proximity fallback: AppKit mouseMoved is not
                // always delivered through the hosting view, which left the
                // move bar invisible and the widget apparently undraggable.
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let w = widget.size.width, h = widget.size.height
                        let nearMove = p.y > h - 68 && abs(p.x - w / 2) < 84
                        let nearResize = p.x > w - 68 && p.y > h - 68
                        if nearMove != hover.nearMove { hover.nearMove = nearMove }
                        if nearResize != hover.nearResize { hover.nearResize = nearResize }
                    case .ended:
                        if hover.nearMove { hover.nearMove = false }
                        if hover.nearResize { hover.nearResize = false }
                    }
                }

            // Close button — always present, opacity controlled
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(.black.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain).padding(8)
            .opacity(hover.showClose ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: hover.showClose)
        }
        // During a drag, never interpolate position/size changes.
        .transaction { tx in if widget.isDragging { tx.animation = nil } }
    }

    @ViewBuilder private var widgetContent: some View {
        switch widget.kind {
        case .clock:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .center, spacing: 8) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 56, weight: .light, design: .default))
                        .tracking(-1.2)
                        .monospacedDigit().foregroundStyle(ink)
                    VStack(spacing: 3) {
                        Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(ink.opacity(0.62))
                        Text("LOCAL TIME").font(.system(size: 9.5, weight: .semibold)).tracking(1.8)
                            .foregroundStyle(ink.opacity(0.38))
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case .calendar:
            AgendaTimelineView(widget: widget, ink: ink)
        case .note:
            VStack(alignment: .leading, spacing: 12) {
                Label("Quick Note", systemImage: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.72))
                TextEditor(text: $widget.note)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14.5))
                    .lineSpacing(2)
                    .foregroundStyle(ink.opacity(0.94))
                    .background(.clear)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .timer:
            TimerView(widget: widget, ink: ink)
        case .battery:
            BatteryView(ink: ink)
        case .system:
            SystemStatsView(ink: ink)
        case .weather:
            WeatherView(widget: widget, ink: ink)
        case .worldClock:
            WorldClockView(widget: widget, ink: ink)
        case .todo:
            TodoView(widget: widget, ink: ink)
        case .countdown:
            CountdownView(widget: widget, ink: ink)
        case .cricket:
            CricketView(widget: widget, ink: ink)
        }
    }
}

// MARK: - Calendar timeline

/// Today's meetings, hour by hour, straight out of the user's calendars.
@MainActor
private final class AgendaStore: ObservableObject {
    static let shared = AgendaStore()

    enum Access { case pending, granted, denied }

    struct Meeting: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let tint: Color
        let source: String
    }

    @Published private(set) var access: Access = .pending
    @Published private(set) var meetings: [Meeting] = []

    private let store = EKEventStore()
    private var timer: Timer?
    private var started = false
    private var observer: NSObjectProtocol?

    func start() async {
        guard !started else { return }
        started = true
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            access = .granted
        case .denied, .restricted, .writeOnly:
            access = .denied
        default:
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            access = ok ? .granted : .denied
            debugLog("calendar access \(ok)")
        }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                                         object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard access == .granted else { return }
        let cal = Calendar.current
        let from = cal.date(byAdding: .hour, value: -2, to: Date()) ?? Date()
        let to = cal.date(byAdding: .day, value: 14, to: cal.startOfDay(for: Date())) ?? Date()
        let found = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        meetings = found
            .filter { !$0.isDetached && $0.status != .canceled }
            .map { event in
                Meeting(id: event.eventIdentifier ?? UUID().uuidString,
                        title: (event.title?.isEmpty == false ? event.title! : "Untitled"),
                        start: event.startDate, end: event.endDate,
                        allDay: event.isAllDay,
                        tint: Color(nsColor: event.calendar.color),
                        source: event.calendar.title)
            }
            .sorted { $0.start < $1.start }
        debugLog("calendar \(meetings.count) meetings " + meetings.prefix(3).map { "\($0.start) \($0.title)" }.joined(separator: " | "))
    }
}

private struct AgendaTimelineView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var store = AgendaStore.shared

    private var cal: Calendar { .current }
    private var rowHeight: CGFloat { 46 }

    /// First hour shown: the hour it is now, so the top of the list is "now".
    private var startHour: Date {
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: Date())
        return cal.date(from: comps) ?? Date()
    }

    private var hours: [Date] {
        (0..<14).compactMap { cal.date(byAdding: .hour, value: $0, to: startHour) }
    }

    /// Still running or yet to start.
    private var upcoming: [AgendaStore.Meeting] {
        store.meetings.filter { !$0.allDay && $0.end > Date().addingTimeInterval(-60) }
    }
    /// What fits the hour grid: the next fourteen hours from the current one.
    private var inTimeline: [AgendaStore.Meeting] {
        upcoming.filter { $0.start < startHour.addingTimeInterval(14 * 3600) }
    }
    private var allDay: [AgendaStore.Meeting] {
        store.meetings.filter { $0.allDay && cal.isDateInToday($0.start) }
    }
    /// Anything still to come before midnight.
    private var leftToday: [AgendaStore.Meeting] {
        upcoming.filter { cal.isDateInToday($0.start) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch store.access {
            case .pending:
                placeholder("Looking at your calendars…")
            case .denied:
                placeholder("Calendar access is off.\nSystem Settings › Privacy & Security › Calendars › Auge")
            default:
                if !inTimeline.isEmpty {
                    timeline
                } else if !upcoming.isEmpty {
                    nextUp
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        goodForToday
                        placeholder("Nothing scheduled in the next two weeks")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await store.start() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("TODAY")
                .font(.system(size: 10, weight: .semibold)).tracking(0.9)
                .foregroundStyle(ink.opacity(0.42))
            Text(Date.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink.opacity(0.9))
            Spacer(minLength: 0)
            if !upcoming.isEmpty {
                Text("\(upcoming.count)")
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ink.opacity(0.4))
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(ink.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !allDay.isEmpty {
                        allDayStrip
                    }
                    ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                        hourRow(hour)
                            .id(hour)
                    }
                }
                .padding(.trailing, 2)
            }
            .onAppear { proxy.scrollTo(startHour, anchor: .top) }
        }
    }

    /// Shown when the rest of today is clear.
    private var goodForToday: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(red: 0.40, green: 0.82, blue: 0.52))
            Text("You're good for today")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ink.opacity(0.82))
                .lineLimit(2).minimumScaleFactor(0.8)
        }
    }

    /// Nothing in the next fourteen hours: show what is actually next, with the
    /// day it falls on, instead of an empty grid.
    private var nextUp: some View {
        VStack(alignment: .leading, spacing: 6) {
            if leftToday.isEmpty { goodForToday }
            Text("NEXT UP")
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                .foregroundStyle(ink.opacity(0.35))
            ForEach(upcoming.prefix(5)) { meeting in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.9))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text(dayAndTime(meeting))
                            .font(.system(size: 10.5))
                            .foregroundStyle(ink.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 11).padding(.trailing, 5)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(meeting.tint.opacity(0.12)))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(meeting.tint)
                        .frame(width: 3).padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dayAndTime(_ meeting: AgendaStore.Meeting) -> String {
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate(cal.isDateInToday(meeting.start) ? "j:mm"
                                               : cal.isDateInTomorrow(meeting.start) ? "'Tomorrow' j:mm"
                                               : "EEE d MMM j:mm")
        return day.string(from: meeting.start)
    }

    private var allDayStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(allDay.prefix(3)) { meeting in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5).fill(meeting.tint).frame(width: 3, height: 12)
                    Text(meeting.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ink.opacity(0.8)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("all day").font(.system(size: 9.5)).foregroundStyle(ink.opacity(0.35))
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func hourRow(_ hour: Date) -> some View {
        let items = inTimeline.filter { $0.start >= hour && $0.start < hour.addingTimeInterval(3600) }
        let isNow = cal.isDate(Date(), equalTo: hour, toGranularity: .hour)
        let startsDay = cal.startOfDay(for: hour) != cal.startOfDay(for: hour.addingTimeInterval(-3600))
        return VStack(alignment: .leading, spacing: 0) {
            if startsDay {
                Text(hour, format: .dateTime.weekday(.wide))
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(ink.opacity(0.35))
                    .padding(.top, 2)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(hour, format: .dateTime.hour())
                    .font(.system(size: 10.5, weight: isNow ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isNow ? ink.opacity(0.85) : ink.opacity(0.34))
                    .frame(width: 40, alignment: .leading)
                    .padding(.top, 2)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(ink.opacity(0.07)).frame(height: 1).padding(.top, 8)
                    VStack(spacing: 3) {
                        ForEach(items) { meeting in
                            eventBlock(meeting)
                        }
                    }
                    if isNow {
                        nowLine.offset(y: nowOffset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: rowHeight, alignment: .top)
        }
    }

    private var nowOffset: CGFloat {
        let comps = cal.dateComponents([.minute], from: Date())
        let fraction = CGFloat(comps.minute ?? 0) / 60
        return 8 + fraction * (rowHeight - 12)
    }

    private var nowLine: some View {
        HStack(spacing: 3) {
            Circle().fill(Color(red: 1, green: 0.36, blue: 0.33)).frame(width: 5, height: 5)
            Rectangle().fill(Color(red: 1, green: 0.36, blue: 0.33).opacity(0.85)).frame(height: 1)
        }
    }

    private func eventBlock(_ meeting: AgendaStore.Meeting) -> some View {
        let running = meeting.start <= Date() && meeting.end > Date()
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(timeRange(meeting))
                        .font(.system(size: 10, weight: running ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(running ? meeting.tint : ink.opacity(0.45))
                    if running {
                        Text("now").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(meeting.tint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 11).padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(meeting.tint.opacity(running ? 0.20 : 0.12)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(meeting.tint)
                .frame(width: 3).padding(.vertical, 3)
        }
    }

    private func timeRange(_ meeting: AgendaStore.Meeting) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        let end = formatter.string(from: meeting.end)
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: meeting.start) + "–" + end
    }
}

// MARK: - Extra widget faces

/// Countdown that belongs to one widget. The remaining seconds live in a small
/// store so the timer keeps running while the peek is closed.
@MainActor
private final class TimerStore: ObservableObject {
    static let shared = TimerStore()
    struct Entry { var remaining: Double; var running: Bool; var last: Date }
    private var entries: [UUID: Entry] = [:]
    private var ticker: Timer?

    func entry(for id: UUID, minutes: Double = 5) -> Entry {
        if let e = entries[id] { return e }
        let e = Entry(remaining: minutes * 60, running: false, last: Date())
        entries[id] = e
        return e
    }

    func toggle(_ id: UUID, minutes: Double) {
        var e = entry(for: id, minutes: minutes)
        if e.running {
            e.remaining = max(0, e.remaining - Date().timeIntervalSince(e.last))
            e.running = false
        } else {
            e.running = e.remaining > 0
            e.last = Date()
        }
        entries[id] = e
        objectWillChange.send()
        startTickerIfNeeded()
    }

    func reset(_ id: UUID, minutes: Double) {
        entries[id] = Entry(remaining: minutes * 60, running: false, last: Date())
        objectWillChange.send()
    }

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        var anyRunning = false
        for (id, var e) in entries where e.running {
            let now = Date()
            e.remaining = max(0, e.remaining - now.timeIntervalSince(e.last))
            e.last = now
            if e.remaining <= 0 { e.running = false }
            entries[id] = e
            anyRunning = anyRunning || e.running
        }
        objectWillChange.send()
        if !anyRunning { ticker?.invalidate(); ticker = nil }
    }
}

@MainActor
private final class TimerUI: ObservableObject {
    @Published var showPresets = false
}

@MainActor
private struct TimerView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var store = TimerStore.shared
    @StateObject private var ui = TimerUI()
    private let presets = [1, 3, 5, 10, 15, 25, 45, 60]

    private var minutes: Double { Double(widget.note.trimmingCharacters(in: .whitespaces)) ?? 5 }

    var body: some View {
        let entry = store.entry(for: widget.id, minutes: minutes)
        let total = Int(entry.remaining.rounded())
        VStack(spacing: 12) {
            Text(String(format: "%02d:%02d", total / 60, total % 60))
                .font(.system(size: 52, weight: .light, design: .default))
                .tracking(-1.0)
                .monospacedDigit().foregroundStyle(ink)
            HStack(spacing: 10) {
                Button { store.toggle(widget.id, minutes: minutes) } label: {
                    Image(systemName: entry.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 38, height: 30)
                        .background(.white.opacity(0.16), in: Capsule())
                }.buttonStyle(.plain)
                Button { store.reset(widget.id, minutes: minutes) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 38, height: 30)
                        .background(.white.opacity(0.10), in: Capsule())
                }.buttonStyle(.plain)
                // A Menu cannot open inside See's non-activating panel, so the
                // presets are ordinary buttons in a popover-shaped card.
                Button {
                    ui.showPresets.toggle()
                } label: {
                    Text("\(Int(minutes)) min").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(.white.opacity(ui.showPresets ? 0.22 : 0.10), in: Capsule())
                }.buttonStyle(.plain)
            }
            .foregroundStyle(ink.opacity(0.9))
            if ui.showPresets {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(presets, id: \.self) { value in
                        Button {
                            widget.note = "\(value)"
                            store.reset(widget.id, minutes: Double(value))
                            ui.showPresets = false
                        } label: {
                            Text("\(value)")
                                .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                                .frame(maxWidth: .infinity).frame(height: 26)
                                .background(.white.opacity(Int(minutes) == value ? 0.24 : 0.10),
                                            in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }
                .foregroundStyle(ink.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct BatteryView: View {
    let ink: Color
    @StateObject private var power = PowerSource()

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(power.percent)").font(.system(size: 52, weight: .medium))
                    .monospacedDigit().foregroundStyle(ink)
                Text("%").font(.system(size: 19, weight: .regular)).foregroundStyle(ink.opacity(0.55))
            }
            Text(power.state).font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundStyle(ink.opacity(0.55))
            Capsule().fill(.white.opacity(0.16)).frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(power.onPower ? Color.green.opacity(0.85) : ink.opacity(0.8))
                            .frame(width: max(6, geo.size.width * CGFloat(power.percent) / 100))
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A one-line text draft. `@State` needs the SwiftUI macro plugin, which this
/// toolchain does not ship, so drafts live in a tiny object instead.
@MainActor
private final class TextDraft: ObservableObject {
    @Published var text = ""
}

// MARK: - Cricket

@MainActor
private struct CricketView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var store = CricketStore()

    private var matches: [CricketStore.Match] { store.matches }
    private var index: Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(0, Int(widget.note) ?? 0), matches.count - 1)
    }

    var body: some View {
        Group {
            if matches.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "figure.cricket").font(.system(size: 18, weight: .light))
                        .foregroundStyle(ink.opacity(0.4))
                    Text(store.status.isEmpty ? "Finding a match…" : store.status)
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await store.start() }
            } else {
                let match = matches[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(match.league.uppercased())
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(ink.opacity(0.38))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(match.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(row.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(ink.opacity(0.9))
                                    .frame(width: 46, alignment: .leading)
                                Text(row.score)
                                    .font(.system(size: 15, weight: row.leading ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(row.leading ? ink : ink.opacity(0.55))
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Text(match.status)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(match.live ? Color(red: 0.45, green: 0.85, blue: 0.5) : ink.opacity(0.45))
                            .lineLimit(2).minimumScaleFactor(0.65)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .leading) {
                    if matches.count > 1 {
                        Button { step(-1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(ink.opacity(0.5))
                                .frame(width: 20, height: 34)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .offset(x: -2)
                    }
                }
                .overlay(alignment: .trailing) {
                    if matches.count > 1 {
                        Button { step(1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(ink.opacity(0.5))
                                .frame(width: 20, height: 34)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .offset(x: 2)
                    }
                }
                .task { await store.start() }
            }
        }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        widget.note = String((index + delta + matches.count) % matches.count)
    }
}

/// Live cricket from Cricbuzz: their live-scores page ships the whole match list
/// as JSON inside the React payload, including per-innings scores. Only
/// internationals and the IPL are kept.
@MainActor
private final class CricketStore: ObservableObject {
    struct Row: Identifiable {
        let name: String
        let score: String
        let leading: Bool
        var id: String { name }
    }
    struct Match: Identifiable {
        let id: String
        let league: String
        let rows: [Row]
        let status: String
        let live: Bool
    }

    @Published var matches: [Match] = []
    @Published var status = ""
    private var timer: Timer?
    private var loading = false

    func start() async {
        guard timer == nil else { return }
        await refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let found = await CricketStore.fetch()
        matches = found
        status = found.isEmpty ? "No internationals on right now" : ""
    }

    private static let keptFormats: Set<String> = ["TEST", "ODI", "T20"]

    private static func fetch() async -> [Match] {
        guard let url = URL(string: "https://www.cricbuzz.com/cricket-match/live-scores") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let data = try? await URLSession.shared.data(for: request).0,
              let html = String(data: data, encoding: .utf8),
              let payload = reactPayload(from: html),
              let matchesJSON = array(named: "matches", in: payload),
              let list = try? JSONSerialization.jsonObject(with: Data(matchesJSON.utf8)) as? [[String: Any]] else {
            return []
        }

        var result: [Match] = []
        for entry in list {
            guard let match = entry["match"] as? [String: Any],
                  let info = match["matchInfo"] as? [String: Any] else { continue }
            let format = info["matchFormat"] as? String ?? ""
            let series = info["seriesName"] as? String ?? ""
            let isIPL = series.localizedCaseInsensitiveContains("Indian Premier League")
            guard keptFormats.contains(format) || isIPL else { continue }
            // Only senior internationals (and the IPL): no A tours, U19, unofficial.
            let lower = series.lowercased()
            if lower.contains(" a tour") || lower.contains("unofficial") || lower.contains("u19")
                || lower.contains("emerging") { continue }

            let state = info["state"] as? String ?? ""
            let live = ["In Progress", "Stumps", "Innings Break", "Rain Delay", "Delay", "Tea", "Lunch"]
                .contains { state.localizedCaseInsensitiveContains($0) }
            let done = state.localizedCaseInsensitiveContains("Complete")
            if done {
                let started = (info["startDate"] as? Double ?? 0) / 1000
                // Recently completed only.
                guard started > Date().timeIntervalSince1970 - 3 * 86_400 else { continue }
            }

            let score = (match["matchScore"] as? [String: Any]) ?? [:]
            let battingTeam = info["currBatTeamId"] as? Int
            let team1 = info["team1"] as? [String: Any] ?? [:]
            let team2 = info["team2"] as? [String: Any] ?? [:]

            func oversText(_ value: Double) -> String {
                let whole = floor(value)
                let balls = Int(((value - whole) * 10).rounded())
                // 19.6 is 19 overs and 6 balls: the over is complete, so the
                // scorecard says 20 overs.
                if balls >= 6 { return String(Int(whole) + 1) }
                return String(format: "%.1f", value)
            }

            func rows(_ team: [String: Any], _ key: String) -> Row? {
                let name = (team["teamSName"] as? String) ?? (team["teamName"] as? String) ?? "—"
                guard let dict = score[key] as? [String: Any] else {
                    return Row(name: name, score: "", leading: false)
                }
                let innings = dict.keys.filter { $0.hasPrefix("inngs") }.sorted()
                var parts: [String] = []
                for (position, key) in innings.enumerated() {
                    guard let inn = dict[key] as? [String: Any],
                          let runs = inn["runs"] as? Int else { continue }
                    let wickets = (inn["wickets"] as? Int) ?? 0
                    var text = wickets >= 10 ? "\(runs)" : "\(runs)/\(wickets)"
                    if innings.count == 1, let overs = inn["overs"] as? Double {
                        text += " (" + oversText(overs) + " ov)"
                    }
                    parts.append(text)
                }
                let isBatting = (team["teamId"] as? Int) == battingTeam && live
                return Row(name: name, score: parts.joined(separator: " & "), leading: isBatting)
            }

            let teamRows = [rows(team1, "team1Score"), rows(team2, "team2Score")].compactMap { $0 }
            guard !teamRows.isEmpty else { continue }
            result.append(Match(id: String(info["matchId"] as? Int ?? 0),
                                league: "\(series) · \(info["matchDesc"] as? String ?? "")",
                                rows: teamRows,
                                status: info["status"] as? String ?? "",
                                live: live))
        }

        // Live first, then upcoming, then what just finished.
        return result.sorted { a, b in
            func rank(_ m: Match) -> Int {
                if m.live { return 0 }
                return m.status.lowercased().contains("won") || m.status.lowercased().contains("draw") ? 2 : 1
            }
            return rank(a) < rank(b)
        }
    }

    /// The Cricbuzz page streams its React payload as `self.__next_f.push([1,"…"])`
    /// chunks; joining them yields the JSON the page renders from.
    private static func reactPayload(from html: String) -> String? {
        let pattern = #"self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var pieces: [String] = []
        for match in regex.matches(in: html, range: range) {
            guard let chunkRange = Range(match.range(at: 1), in: html) else { continue }
            let escaped = String(html[chunkRange])
            if let decoded = try? JSONDecoder().decode(String.self, from: Data(("\"" + escaped + "\"").utf8)) {
                pieces.append(decoded)
            }
        }
        return pieces.isEmpty ? nil : pieces.joined()
    }

    /// Pulls `"matches": [ … ]` out of the payload by matching brackets.
    private static func array(named key: String, in payload: String) -> String? {
        guard let keyRange = payload.range(of: "\"" + key + "\":[") else { return nil }
        let start = keyRange.upperBound
        var depth = 1
        var index = start
        while index < payload.endIndex {
            let char = payload[index]
            if char == "[" { depth += 1 }
            if char == "]" {
                depth -= 1
                if depth == 0 {
                    return "[\(payload[start..<index])]"
                }
            }
            index = payload.index(after: index)
        }
        return nil
    }
}

// MARK: - Weather

/// Current conditions from Open-Meteo (no API key). The city is stored in the
/// widget's note as "lat,lon,Name".
@MainActor
private struct WeatherView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var store = WeatherStore()
    @FocusState private var editing: Bool
    @StateObject private var draft = TextDraft()

    private var place: (lat: Double, lon: Double, name: String)? {
        let parts = widget.note.split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count == 3, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return (lat, lon, parts[2])
    }

    var body: some View {
        Group {
            if let place {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: store.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ink.opacity(0.75))
                        Text("\(store.temperature)°")
                            .font(.system(size: 44, weight: .light))
                            .monospacedDigit().foregroundStyle(ink)
                    }
                    Text(place.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ink.opacity(0.62))
                        .lineLimit(1)
                    Text(store.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ink.opacity(0.42))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: widget.note) { await store.load(lat: place.lat, lon: place.lon) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.sun").font(.system(size: 20, weight: .light))
                        .foregroundStyle(ink.opacity(0.5))
                    TextField("City", text: $draft.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .focused($editing)
                        .onSubmit { Task { await search() } }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    Text("Press Return").font(.system(size: 10)).foregroundStyle(ink.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            }
        }
    }

    private func search() async {
        guard let hit = await WeatherStore.geocode(draft.text) else { return }
        widget.note = "\(hit.lat),\(hit.lon),\(hit.name)"
    }
}

@MainActor
private final class WeatherStore: ObservableObject {
    @Published var temperature = 0
    @Published var code = 0
    @Published var wind = 0
    @Published var high = 0
    @Published var low = 0
    private var timer: Timer?
    private var lastKey = ""

    var symbol: String {
        switch code {
        case 0: "sun.max"
        case 1, 2: "cloud.sun"
        case 3: "cloud"
        case 45, 48: "cloud.fog"
        case 51...67, 80...82: "cloud.rain"
        case 71...77, 85, 86: "cloud.snow"
        case 95...99: "cloud.bolt.rain"
        default: "cloud"
        }
    }

    var summary: String {
        "\(condition) · H \(high)°  L \(low)° · \(wind) km/h"
    }

    private var condition: String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77: "Snow"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "—"
        }
    }

    func load(lat: Double, lon: Double) async {
        let key = "\(lat),\(lon)"
        if key == lastKey, timer != nil { return }
        lastKey = key
        await fetch(lat: lat, lon: lon)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetch(lat: lat, lon: lon) }
        }
    }

    private func fetch(lat: Double, lon: Double) async {
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,weather_code,wind_speed_10m"
            + "&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
        guard let data = await WeatherStore.get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let current = json["current"] as? [String: Any] {
            temperature = Int((current["temperature_2m"] as? Double) ?? 0)
            code = Int((current["weather_code"] as? Double) ?? 0)
            wind = Int((current["wind_speed_10m"] as? Double) ?? 0)
        }
        if let daily = json["daily"] as? [String: Any] {
            high = Int((daily["temperature_2m_max"] as? [Double])?.first ?? 0)
            low = Int((daily["temperature_2m_min"] as? [Double])?.first ?? 0)
        }
    }

    static func geocode(_ name: String) async -> (lat: Double, lon: Double, name: String)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let data = await get("https://geocoding-api.open-meteo.com/v1/search?name=\(escaped)&count=1&language=en&format=json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double,
              let label = first["name"] as? String else { return nil }
        let country = (first["country_code"] as? String) ?? ""
        return (lat, lon, country.isEmpty ? label : "\(label), \(country)")
    }

    private static func get(_ url: String) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        return try? await URLSession.shared.data(for: request).0
    }
}

// MARK: - World clock

@MainActor
private final class WorldClockUI: ObservableObject {
    @Published var showZones = false
}

@MainActor
private struct WorldClockView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    /// Inline city picker. An NSMenu cannot open here — See's panel never becomes
    /// the active app — so the list is drawn in the card with ordinary buttons.
    @StateObject private var ui = WorldClockUI()

    private let zones: [(String, String)] = [
        ("San Francisco", "America/Los_Angeles"), ("New York", "America/New_York"),
        ("London", "Europe/London"), ("Berlin", "Europe/Berlin"),
        ("Mumbai", "Asia/Kolkata"), ("Singapore", "Asia/Singapore"),
        ("Tokyo", "Asia/Tokyo"), ("Sydney", "Australia/Sydney")
    ]

    private var selected: (String, String) {
        let zone = widget.note.isEmpty ? "Europe/London" : widget.note
        return zones.first { $0.1 == zone } ?? ("London", "Europe/London")
    }

    var body: some View {
        Group {
            if ui.showZones { zoneList } else { clock }
        }
    }

    private var zoneList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(zones, id: \.1) { zone in
                    Button {
                        widget.note = zone.1
                        ui.showZones = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(zone.0)
                                .font(.system(size: 12, weight: zone.1 == selected.1 ? .semibold : .regular))
                                .foregroundStyle(ink.opacity(zone.1 == selected.1 ? 0.95 : 0.62))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if zone.1 == selected.1 {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(ink.opacity(0.55))
                            }
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(selected.0)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(timeString(context.date))
                    .font(.system(size: 40, weight: .light))
                    .monospacedDigit()
                    .tracking(-1)
                    .foregroundStyle(ink)
                HStack(spacing: 6) {
                    Text(dayString(context.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(ink.opacity(0.38))
                    // Inline with the day, on the leading side: both right-hand
                    // corners belong to the close badge and the resize grip.
                    Button { ui.showZones = true } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(ink.opacity(0.45))
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: selected.1)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: selected.1)
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - To-do

@MainActor
private struct TodoView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var draft = TextDraft()

    private var items: [(done: Bool, text: String)] {
        widget.note.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard !line.isEmpty else { return nil }
            let done = line.hasPrefix("[x] ")
            return (done, String(line.dropFirst(4)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 7) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(item.done ? Color.accentColor : ink.opacity(0.45))
                    Text(item.text)
                        .font(.system(size: 12))
                        .strikethrough(item.done)
                        .foregroundStyle(ink.opacity(item.done ? 0.4 : 0.9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle(index) }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ink.opacity(0.35))
                TextField("New item", text: $draft.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.85))
                    .onSubmit(add)
                }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func add() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var lines = widget.note.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append("[ ] " + text)
        widget.note = lines.joined(separator: "\n")
        draft.text = ""
    }

    private func toggle(_ index: Int) {
        var lines = widget.note.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard index < lines.count else { return }
        lines[index] = lines[index].hasPrefix("[x] ")
            ? "[ ] " + lines[index].dropFirst(4)
            : "[x] " + lines[index].dropFirst(4)
        widget.note = lines.joined(separator: "\n")
    }
}

// MARK: - Countdown

@MainActor
private struct CountdownView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var draft = TextDraft()

    /// Stored as "YYYY-MM-DD|Label".
    private var target: (date: Date, label: String)? {
        let parts = widget.note.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: parts[0]) else { return nil }
        return (date, parts[1])
    }

    var body: some View {
        Group {
            if let target {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let days = Calendar.current.dateComponents([.day], from: context.date, to: target.date).day ?? 0
                    VStack(spacing: 6) {
                        Text(days >= 0 ? "\(days)" : "—")
                            .font(.system(size: 44, weight: .light))
                            .monospacedDigit().foregroundStyle(ink)
                        Text(days >= 0 ? (days == 1 ? "day to go" : "days to go") : "passed")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(ink.opacity(0.4))
                        Text(target.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ink.opacity(0.72))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Target date")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                    TextField("YYYY-MM-DD", text: $draft.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onSubmit {
                            let value = draft.text.trimmingCharacters(in: .whitespaces)
                            if value.count >= 10 { widget.note = value + "|" + value }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Battery percentage straight from IOKit, refreshed every 20 seconds.
@MainActor
private final class PowerSource: ObservableObject {
    @Published var percent = 100
    @Published var onPower = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var state: String {
        if onPower { return percent >= 100 ? "CHARGED" : "CHARGING" }
        return percent <= 20 ? "LOW BATTERY" : "ON BATTERY"
    }

    private func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = info[kIOPSCurrentCapacityKey as String] as? Int,
               let max = info[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                percent = Int((Double(capacity) / Double(max) * 100).rounded())
            }
            if let charging = info[kIOPSPowerSourceStateKey as String] as? String {
                onPower = charging == (kIOPSACPowerValue as String)
            }
        }
    }
}

@MainActor
private struct SystemStatsView: View {
    let ink: Color
    @StateObject private var stats = SystemSampler()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("CPU", value: stats.cpu, detail: "\(Int(stats.cpu * 100))%")
            row("Memory", value: stats.memory, detail: "\(Int(stats.memory * 100))%")
            row("Disk", value: stats.disk, detail: "\(Int(stats.disk * 100))%")
            Spacer(minLength: 0)
            Text(stats.uptime).font(.system(size: 10.5, weight: .medium)).foregroundStyle(ink.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ title: String, value: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ink.opacity(0.60))
                Spacer()
                Text(detail).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ink.opacity(0.80))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(ink.opacity(0.82))
                        .frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 5)
        }
    }
}

@MainActor
private final class SystemSampler: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var disk: Double = 0
    @Published var uptime: String = ""

    private var timer: Timer?
    private var previousTicks: (user: Double, system: Double, idle: Double) = (0, 0, 0)

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let user = Double(load.cpu_ticks.0), system = Double(load.cpu_ticks.1), idle = Double(load.cpu_ticks.2)
            let total = (user - previousTicks.user) + (system - previousTicks.system) + (idle - previousTicks.idle)
            if total > 0 {
                cpu = ((user - previousTicks.user) + (system - previousTicks.system)) / total
            }
            previousTicks = (user, system, idle)
        }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS {
            let page = Double(sysconf(_SC_PAGESIZE))
            let used = (Double(vm.active_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
            memory = min(1, used / totalMemory)
        }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber, let size = attrs[.systemSize] as? NSNumber, size.doubleValue > 0 {
            disk = 1 - free.doubleValue / size.doubleValue
        }

        let seconds = ProcessInfo.processInfo.systemUptime
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        uptime = days > 0 ? "Up \(days)d \(hours)h" : "Up \(hours)h \(minutes)m"
    }
}

// MARK: - Context menu

@MainActor
private struct WorkspaceContextMenu: View {
    let onAdd: () -> Void; let onTidy: () -> Void
    let onBackground: () -> Void; let onSettings: () -> Void; let onRemoveAll: () -> Void
    @ObservedObject private var hover = MenuHover.shared

    var body: some View {
        VStack(spacing: 1) {
            menuRow("Add New Visions…", symbol: "rectangle.stack.badge.plus", action: onAdd)
            sep
            menuRow("Tidy Layout", symbol: "sparkles", action: onTidy)
            sep
            menuRow("Customize Background…", symbol: "circle.lefthalf.filled", action: onBackground)
            sep
            menuRow("Open Settings…", symbol: "gearshape", action: onSettings)
            sep
            menuRow("Remove All Visions…", symbol: "trash", action: onRemoveAll, destructive: true)
        }
        .padding(6).frame(width: 256)
        .background(GlassMenuBackground())
    }

    private var sep: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func menuRow(_ title: String, symbol: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        let key = "ws:" + title
        return Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red.opacity(0.92) : Color.white.opacity(0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).frame(height: 28).contentShape(Rectangle())
                .background(hover.row == key ? Color.white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            hover.setAction(key, action)
                            hover.register(key, proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, new in hover.register(key, new) }
                })
        }
        .buttonStyle(.plain)
    }
}

/// Hover tracking for the glass menus. SwiftUI hover does not fire while See's
/// non-activating panel is not key, so the app's global pointer watch drives it
/// from screen coordinates instead.
@MainActor
private final class MenuHover: ObservableObject {
    static let shared = MenuHover()
    @Published var row: String?

    private var frames: [String: CGRect] = [:]

    private var actions: [String: () -> Void] = [:]
    private var lastHitID: String?
    private var lastHitTime: CFAbsoluteTime = 0

    func frame(_ id: String) -> CGRect? { frames[id] }

    func register(_ id: String, _ frame: CGRect) {
        if frame.width < 2 || frame.height < 2 { return }
        if frames[id] != frame { frames[id] = frame }
    }

    func setAction(_ id: String, _ action: @escaping () -> Void) {
        actions[id] = action
    }

    /// Runs the row under a click on mouse-down. SwiftUI buttons only fire on
    /// mouse-up, and the first click of a session can be lost to a re-render,
    /// which is why a menu row used to need a second click.
    func invoke(at point: CGPoint) -> Bool {
        // Rows are 28pt tall; accept a click a couple of points outside one so a
        // slightly high or low click still lands on the row the user aimed at.
        var best: (id: String, distance: CGFloat)?
        for (id, frame) in frames {
            guard actions[id] != nil else { continue }
            let slack = frame.insetBy(dx: -4, dy: -4)
            guard slack.contains(point) else { continue }
            let d = hypot(point.x - frame.midX, point.y - frame.midY)
            if best == nil || d < best!.distance { best = (id, d) }
        }
        guard let hit = best, let action = actions[hit.id] else { return false }
        // One physical click can reach the app twice (the panel is re-delivered
        // as it becomes key), which made a toggle fire twice and cancel itself.
        let now = CFAbsoluteTimeGetCurrent()
        if hit.id == lastHitID, now - lastHitTime < 0.3 { return true }
        lastHitID = hit.id; lastHitTime = now
        row = nil
        action()
        return true
    }

    func clear(_ prefix: String) {
        for key in frames.keys where key.hasPrefix(prefix) {
            frames.removeValue(forKey: key); actions.removeValue(forKey: key)
        }
        if let row, row.hasPrefix(prefix) { self.row = nil }
    }

    func update(point: CGPoint) {
        var hit: String?
        for (id, frame) in frames where frame.contains(point) { hit = id }
        if hit != row { row = hit }
    }
}

/// macOS-style frosted panel: a real blur of what is behind the panel.
private struct GlassMenuBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
    }
}

// MARK: - Widget picker

@MainActor
private final class PickerSelection: ObservableObject {
    @Published var index = 0
}

@MainActor
private struct WidgetPickerOverlay: View {
    @Binding var category: WidgetPickerCategory
    @Binding var search: String
    let onClose: () -> Void
    let onAddWebsite: (String) -> Void
    let onAddWidget: (NativeWidgetKind) -> Void

    @FocusState private var searchFocused: Bool
    @StateObject private var selection = PickerSelection()

    var body: some View {
        ZStack {
            // The workspace behind the picker already carries See's own
            // dimming, so the picker adds no second layer — it matches the
            // workspace exactly and stays see-through.
            Color.clear.contentShape(Rectangle())
                .ignoresSafeArea().onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.62))
                    TextField("Enter the website, vision, or app you want to see…", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .medium)).onSubmit(submitSearch)
                        .focused($searchFocused)
                        .onChange(of: search) { _, _ in selection.index = 0 }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.return) { confirmSelection(); return .handled }
                        .onAppear {
                            searchFocused = true
                            // The panel can still be settling when the picker
                            // appears, which drops the first focus request.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { searchFocused = true }
                        }
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.48))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 18).frame(height: 62)

                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

                // Category tabs
                HStack(spacing: 8) {
                    ForEach(WidgetPickerCategory.allCases) { cat in
                        Button { withAnimation(.easeInOut(duration: 0.18)) { category = cat } } label: {
                            Text(cat.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(category == cat ? .white : Color.white.opacity(0.63))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(category == cat ? .white.opacity(0.16) : .white.opacity(0.07), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        switch category {
                        case .websites: websiteContent
                        case .widgets: widgetContent
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 22)
                }
            }
            .frame(width: 660, height: 438)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.black.opacity(0.16)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.34), radius: 40, y: 20)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark)
    }

    private var suggestions: [SiteSuggestion] { SiteCatalog.suggestions(for: search) }

    private func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = selection.index + delta
        selection.index = max(0, min(suggestions.count - 1, next))
    }

    private func confirmSelection() {
        guard !suggestions.isEmpty else {
            if category == .websites, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onAddWebsite(search)
            }
            return
        }
        let index = min(selection.index, suggestions.count - 1)
        onAddWebsite(suggestions[index].url)
    }

    private var websiteContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !suggestions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(suggestions) { suggestion in
                        Button { onAddWebsite(suggestion.url) } label: {
                            HStack(spacing: 11) {
                                Text(String(suggestion.name.prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(width: 26, height: 26)
                                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.94))
                                    Text(suggestion.host)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.42))
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "return")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.28))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(selection.index == (suggestions.firstIndex(of: suggestion) ?? 0)
                                        ? Color.white.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Spacer(minLength: 24)
                    Image(systemName: search.isEmpty ? "globe" : "magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.36))
                    Text(search.isEmpty ? "Add any website you want" : "No match for “\(search)”")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(search.isEmpty
                         ? "Start typing a name — YouTube, Notion, Pokémon Showdown…"
                         : "Press Return to search the web for it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.46))
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
            }

            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { onAddWebsite(search) } label: {
                    Label(suggestions.isEmpty ? "Search the web for “\(search)”" : "Open “\(search)”",
                          systemImage: "arrow.up.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.07), in: Capsule())
                }.buttonStyle(.plain).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var widgetContent: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(NativeWidgetKind.allCases) { kind in
                Button { onAddWidget(kind) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.symbol).font(.system(size: 17, weight: .regular))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.rawValue).font(.system(size: 13, weight: .semibold))
                            Text(kind.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(0.92)).padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                }.buttonStyle(.plain)
            }
        }
    }

    private func submitSearch() {
        guard category == .websites else { return }
        confirmSelection()
    }
}

// MARK: - Workspace options overlay

@MainActor
private struct WorkspaceOptionsOverlay: View {
    let panel: WorkspacePanel
    @Binding var backgroundStyle: WorkspaceBackgroundStyle
    @Binding var glow: Double
    @Binding var dim: Double
    let onClose: () -> Void

    private var title: String {
        switch panel { case .background: "Customize Background"; case .settings: "Auge Settings" }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    if let icon = AppBrand.icon {
                        Image(nsImage: icon)
                            .resizable().interpolation(.high)
                            .frame(width: 22, height: 22)
                    }
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.6)) }.buttonStyle(.plain)
                }
                switch panel {
                case .background:
                    Text("Palette").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.42))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(WorkspaceBackgroundStyle.allCases) { style in
                            Button { backgroundStyle = style } label: {
                                VStack(spacing: 7) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(style.base)
                                        RadialGradient(colors: [style.tint, .clear], center: .center,
                                                       startRadius: 2, endRadius: 40)
                                        if backgroundStyle == style {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(height: 46)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(.white.opacity(backgroundStyle == style ? 0.85 : 0.14), lineWidth: 1))
                                    Text(style.title).font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        settingLine("Glow", value: glow) { Slider(value: $glow, in: 0...1.6) }
                        settingLine("Dim", value: dim) { Slider(value: $dim, in: 0.25...0.95) }
                    }
                    .padding(.top, 4)
                case .settings:
                    Text("See Beyond.\nWebsites, files and widgets in a freeform workspace.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(20).frame(width: 380)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.34), radius: 26, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingLine<Content: View>(_ label: String, value: Double, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8)).frame(width: 46, alignment: .leading)
            content()
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Surface context menu (right-click on a widget)

@MainActor
private struct SurfaceContextMenu: View {
    let title: String
    let isWebsite: Bool
    let onConfigure: () -> Void
    let onReload: () -> Void
    let onOpenInBrowser: () -> Void
    let sizeLocked: Bool
    let onToggleLock: () -> Void
    let onRemove: () -> Void
    @ObservedObject private var hover = MenuHover.shared

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.top, 5).padding(.bottom, 4)

            if isWebsite {
                row("Configure Website…", "slider.horizontal.3", onConfigure)
                row("Reload", "arrow.clockwise", onReload)
                row("Open in Browser", "safari", onOpenInBrowser)
                row(sizeLocked ? "Unlock Size" : "Lock Size",
                    sizeLocked ? "lock.open" : "lock", onToggleLock)
                sep
                row("Remove Website", "trash", onRemove, destructive: true)
            } else {
                row(sizeLocked ? "Unlock Size" : "Lock Size",
                    sizeLocked ? "lock.open" : "lock", onToggleLock)
                sep
                row("Remove Vision", "trash", onRemove, destructive: true)
            }
        }
        .padding(6).frame(width: 232)
        .background(GlassMenuBackground())
    }

    private var sep: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func row(_ title: String, _ symbol: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        let key = "sf:" + title
        return Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red.opacity(0.92) : Color.white.opacity(0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).frame(height: 28).contentShape(Rectangle())
                .background(hover.row == key ? Color.white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            hover.setAction(key, action)
                            hover.register(key, proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, new in hover.register(key, new) }
                })
        }
        .buttonStyle(.plain)
    }
}

/// Runs a closure shortly after the last call, for live-editing a text field.
@MainActor
private final class DebouncedApply: ObservableObject {
    private var work: Task<Void, Never>?

    func apply(_ action: @escaping () -> Void) {
        work?.cancel()
        work = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

// MARK: - Configure widget

@MainActor
private struct ConfigureWidgetOverlay: View {
    @ObservedObject var site: WebsiteSurface
    let onSelectElements: () -> Void
    let onDone: () -> Void

    private let ink = Color.white.opacity(0.92)
    private let dim = Color.white.opacity(0.45)

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.10).ignoresSafeArea()
                .allowsHitTesting(!site.isPickingElements)
                .onTapGesture { if !site.isPickingElements { onDone() } }
            panel
                .frame(width: min(460, max(320, 1710 * 0.3)))
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.black.opacity(0.18)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.32), radius: 34, y: 18)
                .padding(.trailing, 44)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }

    @StateObject private var customWork = DebouncedApply()

    private func applyCustomCode(_ site: WebsiteSurface) {
        // Debounced: typing in the editor must not re-inject on every keystroke.
        customWork.apply { site.applyTuning(reload: false) }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(site.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                if let host = URL(string: site.address)?.host?.replacingOccurrences(of: "www.", with: ""), host != site.title {
                    Text("/").font(.system(size: 15, weight: .regular)).foregroundStyle(dim)
                    Text(host).font(.system(size: 15, weight: .regular)).foregroundStyle(dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onDone) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)

            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)

            VStack(spacing: 0) {
                    settingRow("Auto Refresh") {
                        Menu {
                            ForEach(AutoRefreshOption.allCases) { option in
                                Button(option.title) { site.config.autoRefresh = option.rawValue; site.applyTuning(reload: false) }
                            }
                        } label: { menuLabel(AutoRefreshOption(rawValue: site.config.autoRefresh)?.shortTitle ?? "Off") }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    divider

                    settingRow("Remember Scroll Position", info: "Restores where you were scrolled to when the widget reloads or Auge reopens.") {
                        Toggle("", isOn: Binding(
                            get: { site.config.rememberScroll },
                            set: { site.config.rememberScroll = $0 }
                        ))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    divider

                    settingRow("User Agent") {
                        Menu {
                            ForEach(WebsiteUserAgent.allCases) { agent in
                                Button(agent.title) {
                                    site.config.userAgent = agent
                                    site.applyTuning(reload: true)
                                }
                            }
                        } label: { menuLabel(site.config.userAgent.title) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    divider

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            Text("Zap Elements")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ink)
                            Button {
                            site.restoreAllZaps()
                        } label: {
                            Text("Restore all")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)

                        if !site.zapped.isEmpty {
                                Text("\(site.zapped.count)")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                            Spacer()
                            Button {
                                if site.isPickingElements { site.setPicking(false) } else { site.setPicking(true) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: site.isPickingElements ? "checkmark" : "bolt.slash.fill")
                                        .font(.system(size: 9, weight: .bold))
                                    Text(site.isPickingElements ? "Done" : "Zap")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .tracking(0.2)
                                }
                                .foregroundStyle(site.isPickingElements ? Color(red: 0.42, green: 0.72, blue: 1.0) : ink)
                                .padding(.horizontal, 11).padding(.vertical, 5.5)
                                .background(.white.opacity(0.12), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear
                                            .onAppear {
                                                MenuHover.shared.setAction("zp:" + site.id.uuidString) {
                                                    site.setPicking(!site.isPickingElements)
                                                }
                                                MenuHover.shared.register("zp:" + site.id.uuidString, proxy.frame(in: .global))
                                            }
                                            .onChange(of: proxy.frame(in: .global)) { _, new in
                                                MenuHover.shared.register("zp:" + site.id.uuidString, new)
                                            }
                                    }
                                }
                            }.buttonStyle(.plain)
                        }

                        Text(site.isPickingElements
                             ? "Click anything on the page to hide it."
                             : "Remove parts of the page you never use.")
                            .font(.system(size: 11))
                            .foregroundStyle(dim)

                        if !site.zapped.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(site.zapped.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 {
                                        Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                                    }
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color(red: 1.0, green: 0.36, blue: 0.45).opacity(0.8))
                                            .frame(width: 5, height: 5)
                                        Text(item.label)
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .tracking(-0.1)
                                            .foregroundStyle(ink.opacity(0.82))
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .frame(width: 18, height: 18)
                                            .contentShape(Rectangle())
                                            .background {
                                                GeometryReader { proxy in
                                                    Color.clear
                                                        .onAppear {
                                                            MenuHover.shared.setAction("uz:" + item.id) { site.restoreZapped(item.id) }
                                                            MenuHover.shared.register("uz:" + item.id, proxy.frame(in: .global))
                                                        }
                                                        .onChange(of: proxy.frame(in: .global)) { _, new in
                                                            MenuHover.shared.register("uz:" + item.id, new)
                                                        }
                                                }
                                            }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .onTapGesture { site.restoreZapped(item.id) }
                                }
                            }
                            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5))

                            HStack {
                                Spacer()
                                Button {
                                    site.clearZapped()
                                } label: {
                                    Text("Restore all")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .tracking(0.2)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 13)

                    divider

                    settingRow("Dark mode", info: "Experimental. Forces dark colours and controls on the page.") {
                        HStack(spacing: 6) {
                            Text("Experimental").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(dim)
                            Toggle("", isOn: Binding(
                                get: { site.config.darkMode },
                                set: { value in
                                    site.config.darkMode = value
                                    // Turning it on is a styling pass that can be
                                    // applied live; turning it off has to undo
                                    // styles the page painted itself, so the page
                                    // is reloaded once with dark mode gone.
                                    site.applyTuning(reload: !value)
                                }
                            ))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        }
                    }

                    divider

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Custom code").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                            Spacer()
                            if !site.config.customCode.isEmpty {
                                Button {
                                    site.config.customCode = ""
                                    site.applyTuning(reload: false)
                                } label: {
                                    Text("Clear").font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(dim)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                        TextEditor(text: Binding(
                            get: { site.config.customCode },
                            set: { site.config.customCode = $0 }
                        ))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.9))
                        .scrollContentBackground(.hidden)
                        .frame(height: 92)
                        .padding(8)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.08), lineWidth: 1))
                        .onChange(of: site.config.customCode) { _, _ in
                            applyCustomCode(site)
                        }
                        Text("CSS applied to this page on every load, e.g. .header { display: none }")
                            .font(.system(size: 10.5)).foregroundStyle(dim)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 13)
            }


            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)

            HStack {
                Spacer()
                Button(action: onDone) {
                    Text("Done").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(.white, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.44), radius: 30, y: 14)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 18)
    }

    private func settingRow<T: View>(_ title: String, info: String? = nil, @ViewBuilder control: () -> T) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
            if let info {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(dim).help(info)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Chrome layer (separate window so it renders above live web content)

@MainActor
private struct ChromeOverlay: View {
    @ObservedObject var model: OverlayModel
    let onCloseOverlay: () -> Void
    @StateObject private var menuSizes = MenuSizes()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
            ZStack {
                if model.showingWidgetPicker {
                    WidgetPickerOverlay(
                        category: $model.pickerCategory,
                        search: $model.pickerSearch,
                        onClose: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                model.showingWidgetPicker = false; model.pendingPickerForRect = nil; model.dragCreatingRect = .null
                            }
                        },
                        onAddWebsite: { model.addWebsiteFromPicker($0, in: size, rect: model.pendingPickerForRect) },
                        onAddWidget: { model.addNativeWidget($0, in: size, rect: model.pendingPickerForRect) }
                    )
                    .frame(width: size.width, height: size.height)
                }

                if let pt = model.contextMenuPoint {
                    WorkspaceContextMenu(
                        onAdd: { withAnimation { model.contextMenuPoint = nil; model.pickerCategory = .websites; model.showingWidgetPicker = true } },
                        onTidy: { withAnimation { model.contextMenuPoint = nil }; model.tidyLayout(in: size) },
                        onBackground: { withAnimation { model.contextMenuPoint = nil; model.workspacePanel = .background } },
                        onSettings: { withAnimation { model.contextMenuPoint = nil; model.workspacePanel = .settings } },
                        onRemoveAll: { withAnimation { model.contextMenuPoint = nil; model.confirmingRemoveAll = true } }
                    )
                    .modifier(MenuSizeReader { menuSizes.workspace = $0 })
                    .position(menuCenter(for: pt, size: size, menu: menuSizes.workspace))
                    .zIndex(10)
                }

                if let menu = model.surfaceMenu {
                    SurfaceContextMenu(
                        title: menu.site?.title ?? menu.widget.map { $0.kind.rawValue } ?? "Widget",
                        isWebsite: menu.site != nil,
                        onConfigure: {
                            if let site = menu.site {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                    model.surfaceMenu = nil; model.configuring = site
                                }
                            } else {
                                withAnimation { model.surfaceMenu = nil }
                            }
                        },
                        onReload: {
                            menu.site?.reload()
                            withAnimation { model.surfaceMenu = nil }
                        },
                        onOpenInBrowser: {
                            if let site = menu.site, let url = URL(string: site.address) {
                                NSWorkspace.shared.open(url)
                            }
                            withAnimation { model.surfaceMenu = nil }
                        },
                        sizeLocked: menu.site?.sizeLocked ?? menu.widget?.sizeLocked ?? false,
                        onToggleLock: {
                            if let site = menu.site { site.sizeLocked.toggle() }
                            if let widget = menu.widget { widget.sizeLocked.toggle() }
                            withAnimation { model.surfaceMenu = nil }
                        },
                        onRemove: {
                            if let site = menu.site { model.remove(site) }
                            if let widget = menu.widget { model.removeWidget(widget) }
                            withAnimation { model.surfaceMenu = nil }
                        }
                    )
                    .modifier(MenuSizeReader { menuSizes.surface = $0 })
                    .position(menuCenter(for: menu.point, size: size, menu: menuSizes.surface))
                    .zIndex(12)
                }

                if let site = model.configuring {
                    ConfigureWidgetOverlay(
                        site: site,
                        onSelectElements: {
                            // Keep the panel open, like Peek: it is the only
                            // anchor and the only obvious way out of the mode.
                            site.setPicking(true)
                        },
                        onDone: {
                            site.setPicking(false)
                            withAnimation(.easeOut(duration: 0.16)) { model.configuring = nil }
                        }
                    )
                    .zIndex(20)
                }

                if let panel = model.workspacePanel {
                    WorkspaceOptionsOverlay(
                        panel: panel,
                        backgroundStyle: $model.backgroundStyle,
                        glow: $model.backgroundGlow,
                        dim: $model.backgroundDim,
                        onClose: { withAnimation { model.workspacePanel = nil } }
                    )
                    .frame(width: size.width, height: size.height)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.showingWidgetPicker)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.contextMenuPoint != nil)
            .animation(.spring(response: 0.26, dampingFraction: 0.8), value: model.surfaceMenu?.id)
            .animation(.spring(response: 0.3, dampingFraction: 0.84), value: model.configuring?.id)
            .animation(.easeInOut(duration: 0.2), value: model.workspacePanel != nil)
            }
            .frame(width: size.width, height: size.height)
                .confirmationDialog("Remove all widgets?", isPresented: $model.confirmingRemoveAll, titleVisibility: .visible) {
                    Button("Remove All", role: .destructive) {
                        withAnimation { model.websites.removeAll(); model.widgets.removeAll() }
                    }
                    Button("Cancel", role: .cancel) { }
                }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Escape is handled once, by SeeOverlay.dismissTopmost — handling it here
        // as well closed the config panel and the whole peek from one key press.
    }

    private func dismissChrome() {
        if let site = model.configuring {
            if site.isPickingElements {
                site.setPicking(false)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) { model.configuring = site }
            } else {
                withAnimation(.easeOut(duration: 0.18)) { model.configuring = nil }
            }
        } else if model.showingWidgetPicker {
            withAnimation(.easeOut(duration: 0.18)) {
                model.showingWidgetPicker = false
                model.pendingPickerForRect = nil
                model.dragCreatingRect = .null
            }
        } else if model.surfaceMenu != nil {
            withAnimation(.easeOut(duration: 0.16)) { model.surfaceMenu = nil }
        } else if model.contextMenuPoint != nil {
            withAnimation(.easeOut(duration: 0.16)) { model.contextMenuPoint = nil }
        } else if model.workspacePanel != nil {
            withAnimation(.easeOut(duration: 0.18)) { model.workspacePanel = nil }
        } else {
            onCloseOverlay()
        }
    }

    private func menuCenter(for point: CGPoint, size: CGSize, menu: CGSize) -> CGPoint {
        let o = menuOrigin(for: point, size: size, menu: menu)
        return CGPoint(x: o.x + menu.width / 2, y: o.y + menu.height / 2)
    }
}


// MARK: - First-use coaching

/// A spotlight tour. Targets are looked up by identifier from the live frame
/// registry, so the cutout sits on the control itself rather than on a guess.
@MainActor
final class VisionTour: ObservableObject {
    static let shared = VisionTour()

    struct Beat {
        let target: String?           // nil for the closing card
        let title: String
        let body: String
    }

    let beats: [Beat] = [
        Beat(target: nil,
             title: "A little peek. Whenever you need.",
             body: "Hold Fn to bring up your workspace. Release it to let it go. Peek in whenever you need something, then get straight back to what you were doing."),
        Beat(target: "tb:pin",
             title: "Give your Fn key a rest.",
             body: "Want to stay longer? Hold Fn and click the pin. Release Fn and the workspace stays put. Esc or × when you're done."),
        Beat(target: "tb:add",
             title: "Bring anything into your workspace.",
             body: "Click Add, or draw an area anywhere on screen to create a vision exactly where you want it.")
    ]



    @Published var index = 0
    private let key = "auge.tour.done"

    var hasFinished: Bool { UserDefaults.standard.bool(forKey: key) }

    func startIfNeeded() {
        guard !hasFinished, index == 0 else { return }
        index = 1
    }

    func next() { index >= beats.count ? finish() : (index += 1) }
    func back() { index = max(1, index - 1) }

    func finish() {
        index = 0
        UserDefaults.standard.set(true, forKey: key)
    }
}

private struct VisionTourOverlay: View {
    @StateObject private var tour = VisionTour.shared
    @StateObject private var tick = FrameTick()
    @StateObject private var fit = CardFit()

    var body: some View {
        GeometryReader { geo in
            if tour.index > 0, tour.index <= tour.beats.count {
                let beat = tour.beats[tour.index - 1]
                let origin = geo.frame(in: .global).origin
                let stamp = tick.now               // re-reads the registry each tick
                let hole: CGRect? = beat.target
                    .flatMap { MenuHover.shared.frame($0) }
                    .map { CGRect(x: $0.minX - origin.x, y: $0.minY - origin.y,
                                  width: $0.width, height: $0.height).insetBy(dx: -8, dy: -8) }
                let centre = hole.map { CGPoint(x: $0.midX, y: $0.midY) }
                    ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                ZStack(alignment: .topLeading) {
                    Spotlight(hole: hole)
                        .id(stamp)                      // stateless: safe to rebuild
                        .allowsHitTesting(hole == nil)

                    Callout(beat: beat,
                            step: tour.index,
                            total: tour.beats.count,
                            onNext: { withAnimation(.easeInOut(duration: 0.28)) { tour.next() } },
                            onBack: { withAnimation(.easeInOut(duration: 0.28)) { tour.back() } },
                            onSkip: { tour.finish() },
                            onSize: { fit.size = $0 })
                        .position(Callout.position(below: hole, fallback: centre, in: geo.size, card: fit.size))
                        .animation(.easeInOut(duration: 0.28), value: tour.index)

                    if let hole, beat.target != nil {
                        // a quiet ring on the control itself, no cursor hijack
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                            .frame(width: hole.width, height: hole.height)
                            .position(centre)
                            .allowsHitTesting(false)
                            .animation(.easeInOut(duration: 0.28), value: tour.index)
                    }
                }
            }
        }
    }
}

/// Dims everything except the hole. destinationOut punches the hole in the dim
/// layer, so the control underneath stays at full brightness and stays clickable.
private struct Spotlight: View {
    let hole: CGRect?

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .overlay {
                if let hole {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .ignoresSafeArea()
    }
}

private final class CardFit: ObservableObject {
    @Published var size = CGSize(width: 292, height: 190)
}

private struct Callout: View {
    let beat: VisionTour.Beat
    let step: Int
    let total: Int
    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void
    let onSize: (CGSize) -> Void

    /// Always sits under the control it describes, never above it: a top-bar
    /// control has no room overhead.
    static func position(below hole: CGRect?, fallback: CGPoint, in size: CGSize,
                         card: CGSize) -> CGPoint {
        let w = max(card.width, 292), h = max(card.height, 120)
        guard let hole else {
            return CGPoint(x: size.width / 2, y: min(fallback.y, size.height - h / 2 - 16))
        }
        var x = hole.midX
        x = min(max(x, w / 2 + 16), size.width - w / 2 - 16)
        let y = hole.maxY + 12 + h / 2
        return CGPoint(x: x, y: min(y, size.height - h / 2 - 16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(beat.title)
                .font(AppBrand.uiFont(14, weight: .semibold))
                .foregroundStyle(.white)
            if step == 1 {
                FnPeekDemo()
            } else if step == 2 {
                PinDemo()
            } else if step == 3 {
                AreaSelectDemo()
                    .padding(.vertical, 4)
            }
            Text(beat.body)
                .font(AppBrand.uiFont(12.5))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Text("\(step) of \(total)")
                    .font(AppBrand.uiFont(10.5))
                    .foregroundStyle(.white.opacity(0.34))
                Spacer()
                if step > 1 {
                    Button("Back", action: onBack)
                        .buttonStyle(.plain)
                        .font(AppBrand.uiFont(11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .font(AppBrand.uiFont(11.5))
                    .foregroundStyle(.white.opacity(0.5))
                Button(step == total ? "Got it" : "Next", action: onNext)
                    .buttonStyle(.plain)
                    .font(AppBrand.uiFont(11.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 292, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { onSize(g.size) }
                .onChange(of: g.size) { _, new in onSize(new) }
        })
    }
}

/// Shown when there is nothing on the workspace yet: a hand dragging out a new
/// vision and letting go, so the gesture is obvious before it is tried.
private struct EmptyDragHint: View {
    @StateObject private var s = DragAnim()

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .frame(width: s.width, height: s.height)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(x: s.width - 4, y: s.height - 4)
            }
            .frame(width: 260, height: 170, alignment: .topLeading)

            Text("Drag out a space")
                .font(AppBrand.uiFont(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .allowsHitTesting(false)
        .onAppear { s.run() }
    }

    @MainActor
    private final class DragAnim: ObservableObject {
        @Published var width: CGFloat = 30
        @Published var height: CGFloat = 22

        func run() {
            step()
        }

        private func step() {
            width = 30; height = 22
            withAnimation(.easeInOut(duration: 1.0)) { width = 240; height = 150 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.6)) { self.width = 30; self.height = 22 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.step() }
            }
        }
    }
}


/// Illustrates the second way in: a page is picked up, carried on a dotted path
/// and dropped into empty workspace. Nothing is created.
@MainActor
private final class FrameTick: ObservableObject {
    @Published var now = Date()
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }
}

/// Step 1: Fn down, workspace appears, Fn up, workspace goes. Twice.
private struct FnPeekDemo: View {
    @StateObject private var s = FnState()

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(s.down ? 0.26 : 0.12))
                    .frame(width: 40, height: 30)
                Text("fn")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1))

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(s.shown ? 0.18 : 0.05))
                    .frame(width: 118, height: 66)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(s.shown ? 0.45 : 0.16), lineWidth: 1))
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(.white.opacity(s.shown ? 0.35 : 0.08))
                            .frame(width: 30, height: 40)
                            .animation(.easeOut(duration: 0.35).delay(Double(i) * 0.05), value: s.shown)
                    }
                }
            }
        }
        .frame(width: 210, height: 74)
        .onAppear { s.run() }
    }

    @MainActor
    private final class FnState: ObservableObject {
        @Published var down = false
        @Published var shown = false
        private var cycles = 0

        func run() { cycle() }

        private func cycle() {
            down = true
            withAnimation(.easeOut(duration: 0.35)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.down = false
                withAnimation(.easeIn(duration: 0.4)) { self.shown = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    self.cycles += 1
                    self.cycle()
                }
            }
        }
    }
}

/// Step 2: Fn held, pin clicked, Fn released, workspace stays. Then Esc and ×.
private struct PinDemo: View {
    @StateObject private var s = PinState()

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 118, height: 66)

                VStack(alignment: .trailing, spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(s.pinned ? 0.85 : 0.12))
                            .frame(width: 16, height: 16)
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(s.pinned ? Color.black.opacity(0.75) : Color.white.opacity(0.5))
                    }
                    .scaleEffect(s.highlightPin ? 1.15 : 1)
                    Spacer()
                    if s.showDismiss {
                        HStack(spacing: 4) {
                            badge("esc")
                            badge("×")
                        }
                    }
                }
                .padding(5)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(s.pinned ? 0.5 : 0.2), lineWidth: 1)
                    .frame(width: 118, height: 66)

                if s.cursorVisible {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .offset(x: s.cursorAtPin ? -14 : -54, y: s.cursorAtPin ? 16 : 44)
                }
            }
            .frame(width: 118, height: 66)

            Image(systemName: "arrow.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.3))

            Text("fn")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 40, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(s.holdingFn ? 0.26 : 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .frame(width: 210, height: 74)
        .onAppear { s.run() }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.14)))
    }

    @MainActor
    private final class PinState: ObservableObject {
        @Published var holdingFn = false
        @Published var highlightPin = false
        @Published var pinned = false
        @Published var cursorVisible = false
        @Published var cursorAtPin = false
        @Published var showDismiss = false

        func run() { step() }

        private func step() {
            holdingFn = true; cursorVisible = true; highlightPin = true
            pinned = false; cursorAtPin = false; showDismiss = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.cursorAtPin = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.pinned = true
                self?.highlightPin = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in
                self?.holdingFn = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { [weak self] in
                withAnimation(.easeOut(duration: 0.3)) { self?.showDismiss = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { [weak self] in
                self?.cursorVisible = false
                withAnimation(.easeOut(duration: 0.3)) { self?.showDismiss = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.step() }
            }
        }
    }
}

/// Step 3: the real gesture. Cursor to empty workspace, mouse down, draw a
/// rectangle diagonally, release, and a vision sits in those bounds.
private struct AreaSelectDemo: View {
    @StateObject private var s = AreaState()

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.white.opacity(0.04))
                .frame(width: 206, height: 86)

            if s.origin.x > 0 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(s.dropped ? 0.5 : 0.65),
                                  style: StrokeStyle(lineWidth: 1, dash: s.dropped ? [] : [4, 3]))
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.white.opacity(s.dropped ? 0.16 : 0.04)))
                    .frame(width: s.rect.width, height: s.rect.height)
                    .offset(x: s.rect.minX, y: s.rect.minY)
            }

            Image(systemName: "cursorarrow")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .offset(x: s.cursor.x + 2, y: s.cursor.y)
                .opacity(s.cursorVisible ? 1 : 0)
        }
        .frame(width: 206, height: 86)
        .onAppear { s.run() }
    }

    @MainActor
    private final class AreaState: ObservableObject {
        @Published var cursor = CGPoint(x: 100, y: 44)
        @Published var cursorVisible = false
        @Published var origin = CGPoint.zero
        @Published var rect = CGRect.zero
        @Published var dropped = false

        func run() { cycle() }

        private func cycle() {
            origin = .zero; rect = .zero; dropped = false
            cursor = CGPoint(x: 100, y: 44)
            cursorVisible = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.cursorVisible = true
                self?.cursor = CGPoint(x: 26, y: 20)      // move to empty space
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.origin = CGPoint(x: 30, y: 24)       // mouse down
                self.cursor = CGPoint(x: 44, y: 34)
                self.rect = CGRect(x: 30, y: 24, width: 14, height: 10)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.cursor = CGPoint(x: 168, y: 62)      // drag diagonally
                self.rect = CGRect(x: 30, y: 24, width: 138, height: 38)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                withAnimation(.easeOut(duration: 0.25)) { self?.dropped = true }   // release
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                self?.cursorVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.cycle()
            }
        }
    }
}
