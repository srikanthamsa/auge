import AppKit
import IOKit.ps
import QuartzCore
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Combine
import SwiftUI
import WebKit

extension Notification.Name {
    static let seeEscape = Notification.Name("SeeEscapePressed")
    static let seePeekOpened = Notification.Name("SeePeekOpened")
    static let seePeekClosed = Notification.Name("SeePeekClosed")
}

func debugLog(_ message: String) {
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/see-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

// MARK: - Entry point

@MainActor
@main
struct SeeApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = SeeAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

// MARK: - App delegate (single status item)

@MainActor
private final class SeeAppDelegate: NSObject, NSApplicationDelegate {
    // Keep a single status item alive for the app lifetime.
    private var statusItem: NSStatusItem?
    private var panel: SeeOverlayPanel?
    private var escapeMonitor: Any?
    private let model = OverlayModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Destroy any ghost items left by previous launches in the same process.
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "See")
        statusItem?.button?.action = #selector(togglePanel)
        statusItem?.button?.target = self
        statusItem?.button?.toolTip = "See — live workspace"
        showPanel()
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
        panel.makeMain()
        NSApp.activate(ignoringOtherApps: true)
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
        panel.contentView = FirstMouseHostingView(rootView: SeeOverlay(onClose: { [weak self] in self?.hidePanel() }, model: model))
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
        v.onDragCreating = onDragCreating
        v.onDragCreated = onDragCreated
    }
}

@MainActor
final class WorkspaceInteractionView: NSView {
    var onRightClick: ((CGPoint) -> Void)?
    var onDismiss: ((CGPoint) -> Void)?
    var isSurfaceAt: ((CGPoint) -> Bool)?
    var contextMenuFrame: (() -> CGRect?)?
    var onDragCreating: ((CGRect) -> Void)?
    var onDragCreated: ((CGRect) -> Void)?

    private var eventMonitor: Any?
    private var dragStart: CGPoint?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installMonitorIfNeeded() }

    func installMonitorIfNeeded() {
        guard eventMonitor == nil, window != nil else { return }
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
                self.onRightClick?(point); return nil
            case .leftMouseDown:
                if MenuHover.shared.invoke(at: point) { return nil }
                debugLog("left down at \(point) key=\(self.window?.isKeyWindow == true) active=\(NSApp.isActive) menuFrame=\(String(describing: self.contextMenuFrame?())) inMenu=\(self.contextMenuFrame?().map { $0.contains(point) } ?? false)")
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
            return NativeWidgetSurface(kind: kind, center: CGPoint(x: item.x, y: item.y), id: item.id,
                                       size: CGSize(width: item.w, height: item.h), note: item.note)
        }
        if !websites.isEmpty || !widgets.isEmpty { hasPlacedInitialSite = true }
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
        websites.last { site in
            CGRect(x: site.center.x - site.size.width / 2, y: site.center.y - site.size.height / 2,
                   width: site.size.width, height: site.size.height).contains(point)
        }
    }

    func widget(at point: CGPoint) -> NativeWidgetSurface? {
        widgets.last { widget in
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
        withAnimation(.easeInOut(duration: 0.22)) { websites.removeAll { $0.id == site.id } }
        focusedID = websites.last?.id
    }

    func addWidget(_ kind: NativeWidgetKind, center: CGPoint) {
        let widget = NativeWidgetSurface(kind: kind, center: center)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { widgets.append(widget) }
    }

    func removeWidget(_ widget: NativeWidgetSurface) {
        withAnimation(.easeInOut(duration: 0.22)) { widgets.removeAll { $0.id == widget.id } }
    }

    /// Packs every surface into the free workspace without overlaps: large
    /// surfaces claim space first, each one takes the tightest free rectangle
    /// that still fits it, and the whole arrangement is centred afterwards.
    func tidyLayout(in size: CGSize, style: LayoutStyle = .grid) {
        struct Item {
            let isWidget: Bool
            let index: Int
            var size: CGSize
            var center: CGPoint
        }

        var items: [Item] = websites.enumerated().map {
            Item(isWidget: false, index: $0.offset, size: $0.element.size, center: .zero)
        }
        items += widgets.enumerated().map {
            Item(isWidget: true, index: $0.offset, size: $0.element.size, center: .zero)
        }
        guard !items.isEmpty else { return }

        let gap: CGFloat = 18
        let usable = CGRect(x: 34, y: 92,
                            width: max(240, size.width - 68),
                            height: max(240, size.height - 168))

        // Fit everything into the workspace before placing it: shrink uniformly
        // when the surfaces would not fit at their current sizes.
        let totalArea = items.reduce(CGFloat(0)) { $0 + $1.size.width * $1.size.height }
        var scale: CGFloat = 1
        if totalArea > usable.width * usable.height * 0.72 {
            scale = max(0.55, sqrt(usable.width * usable.height * 0.72 / totalArea))
        }
        for i in items.indices {
            items[i].size = CGSize(width: max(260, items[i].size.width * scale),
                                   height: max(200, items[i].size.height * scale))
        }

        var remaining = [usable]
        var placed: [Int] = []

        // Big surfaces first: they are the ones with the fewest options.
        let order = items.indices.sorted { a, b in
            let sa = items[a].size.width * items[a].size.height
            let sb = items[b].size.width * items[b].size.height
            return sa > sb
        }

        for i in order {
            var need = items[i].size
            // Prefer the free rectangle with the least wasted area.
            func score(_ r: CGRect) -> CGFloat {
                r.width * r.height - need.width * need.height
            }
            var slot = remaining
                .filter { $0.width >= need.width && $0.height >= need.height }
                .min { score($0) < score($1) }

            if slot == nil {
                // Nothing fits at full size: take the largest free rectangle and
                // shrink this surface into it, keeping its aspect ratio.
                guard let big = remaining.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
                let fit = min(big.width / need.width, big.height / need.height)
                need = CGSize(width: max(200, need.width * fit), height: max(150, need.height * fit))
                slot = big
            }
            guard let rect = slot else { continue }

            items[i].size = need
            items[i].center = CGPoint(x: rect.minX + need.width / 2, y: rect.minY + need.height / 2)
            placed.append(i)

            remaining.removeAll { $0 == rect }
            let right = CGRect(x: rect.minX + need.width + gap, y: rect.minY,
                               width: rect.width - need.width - gap, height: need.height)
            let below = CGRect(x: rect.minX, y: rect.minY + need.height + gap,
                               width: rect.width, height: rect.height - need.height - gap)
            if right.width > 180 && right.height > 140 { remaining.append(right) }
            if below.width > 180 && below.height > 140 { remaining.append(below) }
        }

        // Centre the packed block inside the usable area.
        if style == .grid, !placed.isEmpty {
            let boxes = placed.map { i -> CGRect in
                let it = items[i]
                return CGRect(x: it.center.x - it.size.width / 2, y: it.center.y - it.size.height / 2,
                              width: it.size.width, height: it.size.height)
            }
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            let dx = usable.midX - union.midX
            let dy = usable.midY - union.midY
            for i in placed { items[i].center = CGPoint(x: items[i].center.x + dx, y: items[i].center.y + dy) }
        }

        // Apply with a small stagger so the move reads as one gesture.
        for (step, i) in placed.enumerated() {
            let item = items[i]
            let delay = Double(step) * 0.04
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                    if item.isWidget {
                        guard item.index < self.widgets.count else { return }
                        let widget = self.widgets[item.index]
                        widget.size = item.size
                        widget.center = item.center
                    } else {
                        guard item.index < self.websites.count else { return }
                        let site = self.websites[item.index]
                        site.size = item.size
                        site.center = item.center
                    }
                    self.objectWillChange.send()
                }
            }
        }
        debugLog("tidy packed \(placed.count)/\(items.count) into \(usable.size), scale \(scale)")
    }

    func addWebsiteFromPicker(_ address: String, in size: CGSize, rect: CGRect? = nil) {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
        let center: CGPoint
        let surfaceSize: CGSize
        if let r = rect, r.width > 80 {
            center = CGPoint(x: r.midX, y: r.midY)
            surfaceSize = CGSize(width: max(480, r.width), height: max(360, r.height))
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
        if let r = rect, r.width > 80 { center = CGPoint(x: r.midX, y: r.midY) }
        else { center = emptyCenter(for: kind.size, in: size) }
        addWidget(kind, center: center)
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

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .calendar: "calendar"
        case .note: "note.text"
        case .timer: "timer"
        case .battery: "battery.75percent"
        case .system: "cpu"
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
        }
    }
}

private enum WidgetPickerCategory: String, CaseIterable, Identifiable {
    case websites = "Websites", widgets = "Widgets"
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
    var userAgent: WebsiteUserAgent = .chromeMac
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
        userAgent = try c.decodeIfPresent(WebsiteUserAgent.self, forKey: .userAgent) ?? .chromeMac
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
}

private struct WidgetSnapshot: Codable {
    var id: UUID
    var kind: String
    var x: Double, y: Double, w: Double, h: Double
    var note: String
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
        return base.appendingPathComponent("See", isDirectory: true)
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

private enum PageScripts {
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
            if (!style) {
              style = document.createElement('style');
              style.id = '__see_hide';
              style.setAttribute('data-see-managed', 'true');
              (document.head || document.documentElement).appendChild(style);
            }
            if (style.textContent !== window.__seeHideCSS) { style.textContent = window.__seeHideCSS; }
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

    init(kind: NativeWidgetKind, center: CGPoint, id: UUID = UUID(), size: CGSize? = nil, note: String = "") {
        self.id = id; self.kind = kind; self.center = center
        self.size = size ?? kind.size; self.note = note
    }

    var snapshot: WidgetSnapshot {
        WidgetSnapshot(id: id, kind: kind.rawValue,
                       x: center.x, y: center.y, w: size.width, h: size.height, note: note)
    }
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
    @Published var config: WebsiteConfig
    @Published var scrollY: Double = 0
    @Published var isPickingElements = false
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
                        config: config, scrollY: scrollY)
    }

    func navigate() {
        var candidate = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return }
        address = url.absoluteString; requestedURL = url
        title = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website"
        requestID += 1
    }

    func reload() { webView?.reload() }

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
    func applyTuning(reload: Bool) {
        guard let webView else { return }
        if config.darkMode {
            webView.evaluateJavaScript(PageScripts.darkMode, completionHandler: nil)
        } else {
            webView.evaluateJavaScript(PageScripts.darkModeOff, completionHandler: nil)
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
        if !config.hiddenSelectors.isEmpty {
            // Document start: the elements are hidden before the first paint, so a
            // zapped item never flashes when the peek opens.
            controller.addUserScript(WKUserScript(source: PageScripts.hideCSS(config.hiddenSelectors),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: false))
            controller.addUserScript(WKUserScript(source: PageScripts.hideCSS(config.hiddenSelectors),
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
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
        guard picking != isPickingElements else {
            if !picking { webView?.evaluateJavaScript(PageScripts.stopPicker, completionHandler: nil) }
            return
        }
        isPickingElements = picking
        if picking { exitChromeMode() }
        webHost?.refreshHandles()
        debugLog("setPicking \(picking) hidden=\(String(describing: webView?.isHidden))")
        guard let webView else { return }
        installUserScripts(in: webView)
        if !picking { webView.evaluateJavaScript(PageScripts.clearPicker, completionHandler: nil) }
        webView.evaluateJavaScript(picking ? PageScripts.picker : PageScripts.stopPicker) { [weak webView] _, _ in
            guard !picking else { return }
            webView?.evaluateJavaScript("(document.getElementById('__see_zap_box') ? 'box ' : '') + (document.getElementById('__see_zap_label') ? 'label ' : '') + '|' + document.documentElement.style.cursor") { value, _ in
                debugLog("picker cleanup left=\(String(describing: value))")
            }
        }
        if picking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
                webView?.evaluateJavaScript("window.__seeHoverAt && window.__seeHoverAt(300,200); JSON.stringify({a: !!window.__seePickerActive, m: typeof window.__seeHoverAt, tag: (document.elementFromPoint(300,200)||{}).tagName, cls: (document.elementFromPoint(300,200)||{}).className, boxLeft: (document.getElementById('__see_zap_box')||{}).style ? document.getElementById('__see_zap_box').style.left : 'none', boxW: document.getElementById('__see_zap_box') ? document.getElementById('__see_zap_box').style.width : 'none'})") { value, error in
                    debugLog("picker state: \(String(describing: value)) err=\(String(describing: error))")
                }
            }
        }
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
        webView.evaluateJavaScript("window.__seeHoverAt && window.__seeHoverAt(\(x), \(y));", completionHandler: nil)
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

    func addHiddenSelector(_ selector: String) {
        if !config.hiddenSelectors.contains(selector) {
            config.hiddenSelectors.append(selector)
        }
        applyHiddenSelectors()
        // The page already hid the element in JS; refresh the frozen snapshot so
        // the panel shows the result without waiting for a reload.
        refreshChromeSnapshot()
        debugLog("hide selector \(selector)")
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
        if config.rememberScroll, scrollY > 0 {
            webView.evaluateJavaScript("window.scrollTo(0, \(Int(scrollY)));", completionHandler: nil)
        }
        applyHiddenSelectors()
        if isPickingElements {
            webView.evaluateJavaScript(PageScripts.picker, completionHandler: nil)
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
        host.webView.load(URLRequest(url: site.requestedURL))
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
        guard context.coordinator.lastRequestID != site.requestID else { return }
        context.coordinator.lastRequestID = site.requestID
        host.webView.load(URLRequest(url: site.requestedURL))
    }

    final class Coordinator { var lastRequestID = -1 }
}

@MainActor
private final class WebsiteHostView: NSView, WKNavigationDelegate {
    private let site: WebsiteSurface
    let webView: WKWebView
    private let handles: WebsiteHandleView
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
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        bridge.site = site
        bridge.onPick = onPick
        webView.navigationDelegate = self
        addSubview(webView); addSubview(handles, positioned: .above, relativeTo: webView)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        site.didFinishLoad(in: webView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Without this AppKit never delivers mouseMoved, so the proximity
        // handles would never appear.
        window?.acceptsMouseMovedEvents = true
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
        let near = moveRect.insetBy(dx: -30, dy: -16).contains(local)
            || resizeRect.insetBy(dx: -20, dy: -20).contains(local)
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
        if moveRect.contains(local) || resizeRect.contains(local) || closeRect.contains(local) { return self }
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
            if h == .move { site.center = CGPoint(x: startCenter.x + dx, y: startCenter.y + dy) }
            else { site.size = CGSize(width: max(480, startSize.width + dx), height: max(360, startSize.height + dy)) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if activeClose { activeClose = false; onClose?(); return }
        activeHandle = nil; handles.needsDisplay = true
    }

    private var activeClose = false

    // Proximity zones: draw targets are small; grab zone is generous
    func refreshHandles() { handles.needsDisplay = true }

    private var moveRect: CGRect { CGRect(x: bounds.midX - 90, y: bounds.height - 72, width: 180, height: 72) }
    private var resizeRect: CGRect { CGRect(x: bounds.width - 58, y: bounds.height - 58, width: 58, height: 58) }
    private var closeRect: CGRect { CGRect(x: bounds.width - 58, y: 0, width: 58, height: 58) }

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
    let resize = CGRect(x: rect.maxX - 58, y: rect.maxY - 58, width: 58, height: 58)
    let move = CGRect(x: rect.midX - 90, y: rect.maxY - 72, width: 180, height: 72)
    let closeRect = CGRect(x: rect.maxX - 58, y: rect.minY, width: 58, height: 58)
    if close && closeRect.contains(p) { return .close }
    if resize.contains(p) { return .resize }
    if move.contains(p) { return .move }
    return nil
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
            .position(x: site.center.x, y: site.center.y)
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
                                      onPick: { selector in
                                          // Stay in picking mode so several elements can be
                                          // zapped in a row without reopening the panel.
                                          site.addHiddenSelector(selector)
                                      })
                        .scaleEffect(appeared ? 1 : 0.97)
                        .opacity(surfaceOpacity(appeared ? 1 : 0, for: site))
                        .animation(.spring(response: 0.26, dampingFraction: 0.74)
                            .delay(Double(index) * 0.012), value: appeared)
                        .animation(.easeOut(duration: 0.18), value: model.configuring?.id)
                        .zIndex(model.focusedID == site.id ? 2 : Double(index))
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
                        .zIndex(3 + Double(index))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.92))))
                }

                // Drag-creating rubber band
                DragCreatingOverlay(rect: model.dragCreatingRect)

                VStack(spacing: 0) {
                    topBar(size: size)
                    Spacer(minLength: 20)
                    bottomBar
                }
                .padding(.horizontal, 28).padding(.top, 46).padding(.bottom, 24)
                .offset(y: appeared ? 0 : -10)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.24, dampingFraction: 0.7).delay(0.01), value: appeared)
                .zIndex(60)   // chrome stays usable above live website surfaces

                ChromeOverlay(model: model, onCloseOverlay: onClose)
                    .zIndex(100)
            }
            .frame(width: size.width, height: size.height)
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
                        if FnState.held { model.pinned = true }
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

    private func topBar(size: CGSize) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("SEE").font(.system(size: 12, weight: .semibold)).tracking(2.4)
                Text("A little space for what matters")
                    .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                let count = model.websites.count + model.widgets.count
                if count > 0 {
                    Text("\(count) \(count == 1 ? "surface" : "surfaces")")
                        .font(.system(size: 11, weight: .regular)).foregroundStyle(.tertiary)
                }
                Button {
                    model.pinned.toggle()
                } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.pinned ? Color.accentColor : Color.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.pinned ? "Unpin — release Fn to close" : "Pin — keep open after Fn is released")

                Button {
                    debugLog("topBar add pressed")
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.pickerCategory = .websites; model.pickerSearch = ""; model.showingWidgetPicker = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }.buttonStyle(.plain).help("Close See")
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
        CGRect(x: bounds.midX - 60, y: bounds.height - 56, width: 120, height: 56)
    }
    private var resizeRect: CGRect {
        CGRect(x: bounds.width - 52, y: bounds.height - 52, width: 52, height: 52)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if moveRect.contains(local) || resizeRect.contains(local) { return self }
        return nil   // let SwiftUI content handle everything else
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let nearMove = moveRect.insetBy(dx: -24, dy: -12).contains(pt)
        let nearResize = resizeRect.insetBy(dx: -16, dy: -16).contains(pt)
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
        if h == .move { w.center = CGPoint(x: startCenter.x + dx, y: startCenter.y + dy) }
        else { w.size = CGSize(width: max(190, startSize.width + dx), height: max(150, startSize.height + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        widget?.isDragging = false
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
                        .font(.system(size: 54, weight: .semibold, design: .default))
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
            VStack(alignment: .leading, spacing: 12) {
                Text(Date.now, format: .dateTime.month(.wide).year())
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(ink)
                let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 6) {
                    ForEach(Array(symbols.enumerated()), id: \.offset) { _, day in
                        Text(day).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.40))
                            .frame(height: 16)
                    }
                    ForEach(Array(Calendar.current.range(of: .day, in: .month, for: .now) ?? 1..<29), id: \.self) { day in
                        let today = Calendar.current.component(.day, from: .now) == day
                        Text("\(day)")
                            .font(.system(size: 12, weight: today ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(today ? Color.white : ink.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .background {
                                if today {
                                    Circle().fill(Color.accentColor)
                                }
                            }
                            .frame(height: 26)
                    }
                }
            }
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
        }
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
private struct TimerView: View {
    @ObservedObject var widget: NativeWidgetSurface
    let ink: Color
    @StateObject private var store = TimerStore.shared

    private var minutes: Double { Double(widget.note.trimmingCharacters(in: .whitespaces)) ?? 5 }

    var body: some View {
        let entry = store.entry(for: widget.id, minutes: minutes)
        let total = Int(entry.remaining.rounded())
        VStack(spacing: 12) {
            Text(String(format: "%02d:%02d", total / 60, total % 60))
                .font(.system(size: 52, weight: .semibold, design: .default))
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
                Menu {
                    ForEach([1, 3, 5, 10, 15, 25, 45, 60], id: \.self) { value in
                        Button("\(value) minutes") {
                            widget.note = "\(value)"
                            store.reset(widget.id, minutes: Double(value))
                        }
                    }
                } label: {
                    Text("\(Int(minutes)) min").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(.white.opacity(0.10), in: Capsule())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
            .foregroundStyle(ink.opacity(0.9))
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
                Text("\(power.percent)").font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit().foregroundStyle(ink)
                Text("%").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink.opacity(0.6))
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
            menuRow("Add New Widgets…", symbol: "rectangle.stack.badge.plus", action: onAdd)
            sep
            menuRow("Tidy Layout", symbol: "sparkles", action: onTidy)
            sep
            menuRow("Customize Background…", symbol: "circle.lefthalf.filled", action: onBackground)
            sep
            menuRow("Open Settings…", symbol: "gearshape", action: onSettings)
            sep
            menuRow("Remove All Widgets…", symbol: "trash", action: onRemoveAll, destructive: true)
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
private struct WidgetPickerOverlay: View {
    @Binding var category: WidgetPickerCategory
    @Binding var search: String
    let onClose: () -> Void
    let onAddWebsite: (String) -> Void
    let onAddWidget: (NativeWidgetKind) -> Void

    @FocusState private var searchFocused: Bool

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
                    TextField("Enter the website, widget, or app you want to see…", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .medium)).onSubmit(submitSearch)
                        .focused($searchFocused)
                        .onAppear { searchFocused = true }
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

    private var websiteContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 46)
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.38))
            Text("Add any website you want")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
            Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Type a link above and press Return."
                 : "Press Return to open \(search)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.46))

            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { onAddWebsite(search) } label: {
                    Label("Open website", systemImage: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(0.13), in: Capsule())
                }.buttonStyle(.plain).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 232)
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
        guard category == .websites, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onAddWebsite(search)
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
        switch panel { case .background: "Customize Background"; case .settings: "See Settings" }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
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
                    Text("See keeps your websites and widgets in a freeform workspace.")
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
                sep
                row("Remove Website", "trash", onRemove, destructive: true)
            } else {
                row("Remove Widget", "trash", onRemove, destructive: true)
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

                    settingRow("Remember Scroll Position", info: "Restores where you were scrolled to when the widget reloads or See reopens.") {
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
                        HStack {
                            Text("Hide page elements").font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
                            Spacer()
                            Button {
                                if site.isPickingElements { site.setPicking(false) } else { onSelectElements() }
                            } label: {
                                Text(site.isPickingElements ? "Cancel" : "Select on page…")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(site.isPickingElements ? Color(red: 0.42, green: 0.72, blue: 1.0) : ink)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        if site.isPickingElements {
                            Text("Click elements on the page to hide them. Press Esc to exit.")
                                .font(.system(size: 11)).foregroundStyle(Color(red: 0.42, green: 0.72, blue: 1.0).opacity(0.9))
                        }
                        if site.config.hiddenSelectors.isEmpty {
                            if !site.isPickingElements {
                                Text("Nothing hidden yet. Click any element on the page to hide it.")
                                    .font(.system(size: 11)).foregroundStyle(dim)
                            }
                        } else {
                            ForEach(site.config.hiddenSelectors, id: \.self) { selector in
                                HStack(spacing: 8) {
                                    Text(selector)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(ink.opacity(0.85))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Button {
                                        site.config.hiddenSelectors.removeAll { $0 == selector }
                                        debugLog("unhide \(selector)")
                                        site.applyTuning(reload: false)
                                        let quoted = "\(selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))"
                                        site.verifyUnhidden(selector)
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.6))
                                            .frame(width: 18, height: 18)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                // Clicking anywhere on the row restores the element.
                                .onTapGesture {
                                    site.config.hiddenSelectors.removeAll { $0 == selector }
                                    debugLog("unhide row \(selector)")
                                    site.applyTuning(reload: false)
                                }
                            }
                            HStack {
                                Spacer()
                                Button {
                                    let previous = site.config.hiddenSelectors
                                    site.config.hiddenSelectors.removeAll()
                                    debugLog("unhide all")
                                    site.applyTuning(reload: false)
                                    if let first = previous.first {
                                        site.verifyUnhidden(first)
                                    }
                                } label: {
                                    Text("Clear all").font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(dim)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
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
                                set: { site.config.darkMode = $0; site.applyTuning(reload: false) }
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
