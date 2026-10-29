import AppKit
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
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .seePeekOpened, object: nil)
        if let layer = panel.contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            let from = CATransform3DConcat(CATransform3DMakeScale(0.972, 0.972, 1),
                                           CATransform3DMakeTranslation(0, -14, 0))
            layer.transform = from
            layer.opacity = 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.52)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0))
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            panel.animator().alphaValue = 1
        }
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
        NotificationCenter.default.post(name: .seePeekClosed, object: nil)
        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.20)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            layer.transform = CATransform3DMakeScale(1.015, 1.015, 1)
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.contentView?.layer?.transform = CATransform3DIdentity
            }
        })
    }

    private func makePanel() -> SeeOverlayPanel {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = SeeOverlayPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
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
    let onDismiss: () -> Void
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
    var onDismiss: (() -> Void)?
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
            // Right-clicks can arrive without a window reference, so resolve the
            // point from the screen when the event window is not ours.
            let point: CGPoint = {
                if event.window === self.window { return self.convert(event.locationInWindow, from: nil) }
                guard let window = self.window else { return .zero }
                let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                return self.convert(inWindow, from: nil)
            }()
            switch event.type {
            case .rightMouseDown:
                debugLog("right down at \(point)")
                self.onRightClick?(point); return nil
            case .leftMouseDown:
                debugLog("left down at \(point) key=\(self.window?.isKeyWindow == true) active=\(NSApp.isActive)")
                if let menuFrame = self.contextMenuFrame?(), !menuFrame.contains(point) { self.onDismiss?() }
                else if self.contextMenuFrame?() == nil { self.onDismiss?() }
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

private enum MenuMetrics {
    static let workspace = CGSize(width: 256, height: 268)
    static let surface = CGSize(width: 232, height: 172)
}

private struct SurfaceMenuTarget: Identifiable {
    let id = UUID()
    let site: WebsiteSurface?
    let widget: NativeWidgetSurface?
    var app: AppMirrorSurface? = nil
    let point: CGPoint
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var websites: [WebsiteSurface] = []
    @Published var widgets: [NativeWidgetSurface] = []
    @Published var apps: [AppMirrorSurface] = []
    @Published var focusedID: UUID?
    @Published var hasPlacedInitialSite = false
    @Published var contextMenuPoint: CGPoint?
    @Published var showingWidgetPicker = false
    @Published var pendingPickerForRect: CGRect? = nil   // for drag-to-create
    @Published var pickerCategory: WidgetPickerCategory = .websites
    @Published var pickerSearch = ""
    @Published var workspacePanel: WorkspacePanel?
    @Published var backgroundStyle: WorkspaceBackgroundStyle = .midnight
    @Published var confirmingRemoveAll = false
    @Published var dragCreatingRect: CGRect = .null      // live drawing rect
    @Published var surfaceMenu: SurfaceMenuTarget?
    @Published var configuring: WebsiteSurface?

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
                          apps: apps.map { AppSnapshot(id: $0.id, bundleID: $0.bundleID, name: $0.appName,
                                                       x: $0.center.x, y: $0.center.y,
                                                       w: $0.size.width, h: $0.size.height) },
                          background: backgroundStyle.rawValue)
    }

    private func restore() {
        guard let saved = WorkspaceStore.load() else { return }
        backgroundStyle = WorkspaceBackgroundStyle(rawValue: saved.background) ?? .midnight
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
        apps = (saved.apps ?? []).map { item in
            let surface = AppMirrorSurface(bundleID: item.bundleID, appName: item.name,
                                           center: CGPoint(x: item.x, y: item.y), id: item.id,
                                           size: CGSize(width: item.w, height: item.h))
            return surface
        }
        for surface in apps { surface.start() }
        if !websites.isEmpty || !widgets.isEmpty || !apps.isEmpty { hasPlacedInitialSite = true }
        debugLog("restored \(websites.count) sites, \(widgets.count) widgets, \(apps.count) apps")
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
        if let app = app(at: point) {
            surfaceMenu = SurfaceMenuTarget(site: nil, widget: nil, app: app, point: point)
        } else if let site = website(at: point) {
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

    func addApp(_ bundleID: String, name: String, in size: CGSize, rect: CGRect? = nil) {
        if apps.contains(where: { $0.bundleID == bundleID }) {
            if let existing = apps.first(where: { $0.bundleID == bundleID }) { focusedID = existing.id }
            return
        }
        let surfaceSize = rect.map { CGSize(width: max(420, $0.width), height: max(300, $0.height)) }
            ?? CGSize(width: min(720, size.width * 0.5), height: min(520, size.height * 0.56))
        let center = rect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? emptyCenter(for: surfaceSize, in: size)
        let surface = AppMirrorSurface(bundleID: bundleID, appName: name, center: center, size: surfaceSize)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { apps.append(surface) }
        surface.start()
    }

    func removeApp(_ surface: AppMirrorSurface) {
        surface.stop()
        withAnimation(.easeInOut(duration: 0.22)) { apps.removeAll { $0.id == surface.id } }
    }

    func app(at point: CGPoint) -> AppMirrorSurface? {
        apps.last { surface in
            CGRect(x: surface.center.x - surface.size.width / 2, y: surface.center.y - surface.size.height / 2,
                   width: surface.size.width, height: surface.size.height).contains(point)
        }
    }

    func removeWidget(_ widget: NativeWidgetSurface) {
        withAnimation(.easeInOut(duration: 0.22)) { widgets.removeAll { $0.id == widget.id } }
    }

    func tidyLayout(in size: CGSize, style: LayoutStyle = .grid) {
        let count = websites.count + widgets.count
        guard count > 0 else { return }
        let columns = style == .grid ? max(1, Int(ceil(sqrt(Double(count))))) : 1
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = size.width / CGFloat(columns + 1)
        let cellHeight = size.height / CGFloat(rows + 1)
        // Animate each surface to its tidy position with a spring stagger
        for (index, surface) in websites.enumerated() {
            let pos = layoutPoint(index: index, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight, style: style)
            let delay = Double(index) * 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                    surface.center = pos
                    self?.objectWillChange.send()
                }
            }
        }
        for (index, widget) in widgets.enumerated() {
            let pos = layoutPoint(index: websites.count + index, columns: columns, cellWidth: cellWidth, cellHeight: cellHeight, style: style)
            let delay = Double(websites.count + index) * 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                    widget.center = pos
                    self?.objectWillChange.send()
                }
            }
        }
    }

    private func layoutPoint(index: Int, columns: Int, cellWidth: CGFloat, cellHeight: CGFloat, style: LayoutStyle) -> CGPoint {
        style == .cascade
            ? CGPoint(x: cellWidth + CGFloat(index * 42), y: cellHeight + CGFloat(index * 34))
            : CGPoint(x: cellWidth * CGFloat(index % columns + 1), y: cellHeight * CGFloat(index / columns + 1))
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
    var id: String { rawValue }
    var symbol: String { switch self { case .clock: "clock"; case .calendar: "calendar"; case .note: "note.text" } }
    var size: CGSize { switch self { case .clock: CGSize(width: 300, height: 220); case .calendar: CGSize(width: 340, height: 340); case .note: CGSize(width: 340, height: 280) } }
}

private enum WidgetPickerCategory: String, CaseIterable, Identifiable {
    case websites = "Websites", widgets = "Widgets", apps = "Apps"
    var id: String { rawValue }
}

private enum LayoutStyle { case grid, cascade }
private enum WorkspacePanel { case arrange, background, settings }
private enum WorkspaceBackgroundStyle: String, CaseIterable {
    case midnight, charcoal, plum
    var title: String { switch self { case .midnight: "Midnight"; case .charcoal: "Charcoal"; case .plum: "Plum" } }
    var tint: Color { switch self { case .midnight: Color.indigo.opacity(0.17); case .charcoal: Color.gray.opacity(0.16); case .plum: Color.purple.opacity(0.2) } }
}

private struct SelectableApp: Identifiable {
    let name: String; let symbol: String; let bundleID: String
    var id: String { bundleID }
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

private struct AppSnapshot: Codable {
    var id: UUID
    var bundleID: String
    var name: String
    var x: Double, y: Double, w: Double, h: Double
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
    var apps: [AppSnapshot]? = []
    var background: String = WorkspaceBackgroundStyle.midnight.rawValue
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

    static let darkMode = """
    (function(){
      var style = document.getElementById('__see_dark');
      if (!style) {
        style = document.createElement('style');
        style.id = '__see_dark';
        (document.head || document.documentElement).appendChild(style);
      }
      style.textContent = ':root{color-scheme:dark !important}html{background:#0b0b0d}body{background:transparent}'
        + '@media (prefers-color-scheme: light){html,body{background:#0b0b0d !important;color:#eee}}';
    })();
    """

    static func hideCSS(_ selectors: [String]) -> String {
        let encoded = (try? JSONEncoder().encode(selectors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function(){
          var selectors = \(encoded);
          var css = selectors.map(function(s){ return s + '{display:none !important}' }).join('\\n');
          function ensure(){
            var style = document.getElementById('__see_hide');
            if (!style) {
              style = document.createElement('style');
              style.id = '__see_hide';
              (document.head || document.documentElement).appendChild(style);
            }
            if (style.textContent !== css) { style.textContent = css; }
          }
          ensure();
          if (!window.__seeHideObserver) {
            window.__seeHideObserver = new MutationObserver(function(){ ensure(); });
            window.__seeHideObserver.observe(document.documentElement, { childList: true, subtree: true });
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

      function pathFor(el){
        if (!el || el.nodeType !== 1) { return null; }
        if (el.id) { return '#' + CSS.escape(el.id); }
        var parts = [], node = el, depth = 0;
        while (node && node.nodeType === 1 && depth < 5 && node !== document.body) {
          var part = node.tagName.toLowerCase();
          var parent = node.parentElement;
          if (parent) {
            var index = 1, sibling = node;
            while ((sibling = sibling.previousElementSibling)) {
              if (sibling.tagName === node.tagName) { index++; }
            }
            part += ':nth-of-type(' + index + ')';
          }
          parts.unshift(part);
          if (node.id) { parts[0] = '#' + CSS.escape(node.id); break; }
          node = parent; depth++;
        }
        return parts.join(' > ');
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
        dbg('paint ' + el.tagName + '.' + (el.className || '') + ' #' + (el.id || ''));
        paint(el);
      };
      window.__seePickerClick = function(e){
        e.preventDefault(); e.stopPropagation();
        var el = document.elementFromPoint(e.clientX, e.clientY) || e.target;
        if (el === box || el === label) { el = target; }
        el = deepest(el, e.clientX, e.clientY);
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

    static let stopPicker = """
    (function(){
      window.__seePickerActive = false;
      if (window.__seePickerMove) { document.removeEventListener('mouseover', window.__seePickerMove, true); }
      if (window.__seePickerClick) { document.removeEventListener('click', window.__seePickerClick, true); }
      if (window.__seePickerKey) { document.removeEventListener('keydown', window.__seePickerKey, true); }
      document.documentElement.style.cursor = '';
      var box = document.getElementById('__see_zap_box');
      if (box) { box.remove(); }
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


// MARK: - App mirrors
// A real app lives inside the workspace: its window content is streamed with
// ScreenCaptureKit and mouse input is forwarded back to the owning process, so
// the app is usable without ever leaving the peek.

@MainActor
private final class AppMirrorSurface: ObservableObject, Identifiable {
    let id: UUID
    let bundleID: String
    let appName: String
    @Published var center: CGPoint
    @Published var size: CGSize
    @Published var status: MirrorStatus = .starting
    @Published var isDragging = false
    @Published var windowFrame: CGRect = .zero      // screen points, top-left origin
    @Published var pid: pid_t = 0
    var icon: NSImage?

    let controller = AppMirrorController()

    init(bundleID: String, appName: String, center: CGPoint, id: UUID = UUID(), size: CGSize? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.center = center
        self.size = size ?? CGSize(width: 620, height: 420)
        icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        controller.surface = self
    }

    func start() {
        status = .starting
        Task { await controller.start(bundleID: bundleID, size: size) }
    }

    func stop() { controller.stop() }

    func updateWindowFrame() {
        guard let info = AppWindows.window(for: pid) else { return }
        windowFrame = info
    }

    func forward(_ event: NSEvent) {}
}

private enum MirrorStatus: Equatable {
    case starting
    case live
    case needsPermission
    case failed(String)

    var title: String {
        switch self {
        case .starting: "Connecting…"
        case .live: "Live"
        case .needsPermission: "Screen Recording needed"
        case .failed(let message): message
        }
    }
}

private enum AppWindows {
    /// The on-screen content window of a process, in screen points.
    static func window(for pid: pid_t) -> CGRect? {
        guard pid > 0 else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (CGRect, Int)?
        for item in list {
            guard let owner = item[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if rect.width < 120 || rect.height < 80 { continue }
            if let current = best {
                if rect.width * rect.height > current.0.width * current.0.height { best = (rect, layer) }
            } else {
                best = (rect, layer)
            }
        }
        return best?.0
    }
}

private final class AppMirrorContentView: NSView {
    let imageLayer = CALayer()
    var onInput: ((NSEvent, CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ image: CGImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        onInput?(event, localPoint(event))
    }
    override func rightMouseDown(with event: NSEvent) { onInput?(event, localPoint(event)) }
    override func otherMouseDown(with event: NSEvent) { onInput?(event, localPoint(event)) }
    override func scrollWheel(with event: NSEvent) { onInput?(event, localPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onInput?(event, localPoint(event)) }
    override func mouseUp(with event: NSEvent) { onInput?(event, localPoint(event)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AppMirrorContentViewRepresentable: NSViewRepresentable {
    let surface: AppMirrorSurface

    func makeNSView(context: Context) -> AppMirrorContentView {
        let view = AppMirrorContentView()
        surface.controller.view = view
        view.onInput = { event, point in surface.controller.forward(event, in: view, at: point) }
        view.onDoubleClick = { surface.controller.focusApp() }
        return view
    }

    func updateNSView(_ view: AppMirrorContentView, context: Context) {
        surface.controller.view = view
    }
}

@MainActor
private final class AppMirrorController: NSObject, @preconcurrency SCStreamOutput, @preconcurrency SCStreamDelegate {
    weak var surface: AppMirrorSurface?
    weak var view: AppMirrorContentView?

    private var stream: SCStream?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastFrameTime: CFAbsoluteTime = 0

    func start(bundleID: String, size: CGSize) async {
        stop()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            surface?.status = .failed("App not found")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        let launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let app = running ?? launched

        guard let app else {
            surface?.status = .failed("Could not launch app")
            return
        }
        surface?.pid = app.processIdentifier
        app.unhide()   // its window must exist on screen; See keeps the focus
        // Give the app a moment to put a window on screen.
        var frame: CGRect?
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            frame = AppWindows.window(for: app.processIdentifier)
            if frame != nil { break }
        }
        guard let frame else {
            surface?.status = .failed("No window to mirror")
            return
        }
        surface?.windowFrame = frame

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            surface?.status = .needsPermission
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows
                .filter({ $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else {
                surface?.status = .failed("No window to mirror")
                return
            }
            surface?.windowFrame = window.frame
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.width = Int(max(320, window.frame.width * scale))
            config.height = Int(max(240, window.frame.height * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            self.stream = stream
            surface?.status = .live
            debugLog("mirror live \(bundleID) \(window.frame)")
        } catch {
            debugLog("mirror failed \(error)")
            surface?.status = .failed("Mirror unavailable")
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func focusApp() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == surface?.bundleID }) else { return }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("mirror stopped \(error)")
    }

    private nonisolated static let frameContext = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = Self.frameContext.createCGImage(image, from: image.extent) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastFrameTime < 1.0 / 24.0 { return }
            self.lastFrameTime = now
            self.view?.display(cgImage)
        }
    }

    /// Re-target a mouse event onto the mirrored window and deliver it to the app.
    func forward(_ event: NSEvent, in view: AppMirrorContentView, at fraction: CGPoint) {
        guard let surface, surface.pid > 0 else { return }
        if surface.windowFrame == .zero { surface.updateWindowFrame() }
        let frame = surface.windowFrame
        guard frame.width > 1 else { return }
        // Letterboxed content: map through the aspect-fit rect.
        let videoAspect = frame.width / frame.height
        let bounds = view.bounds
        let fitWidth = min(bounds.width, bounds.height * videoAspect)
        let fitHeight = fitWidth / videoAspect
        let insetX = (bounds.width - fitWidth) / 2
        let insetY = (bounds.height - fitHeight) / 2
        let point = CGPoint(x: fraction.x * bounds.width - insetX, y: fraction.y * bounds.height - insetY)
        guard point.x >= -1, point.y >= -1, point.x <= fitWidth + 1, point.y <= fitHeight + 1 else { return }
        let screenPoint = CGPoint(x: frame.minX + point.x / fitWidth * frame.width,
                                  y: frame.minY + point.y / fitHeight * frame.height)

        let type: CGEventType
        switch event.type {
        case .leftMouseDown: type = .leftMouseDown
        case .leftMouseUp: type = .leftMouseUp
        case .leftMouseDragged: type = .leftMouseDragged
        case .rightMouseDown: type = .rightMouseDown
        case .rightMouseUp: type = .rightMouseUp
        case .otherMouseDown: type = .otherMouseDown
        case .otherMouseUp: type = .otherMouseUp
        case .scrollWheel: type = .scrollWheel
        default: return
        }

        if type == .scrollWheel {
            let dy = Int32(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 6))
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            cg.location = screenPoint
            cg.postToPid(surface.pid)
            return
        }
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right
            : ((type == .otherMouseDown || type == .otherMouseUp) ? .center : .left)
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: screenPoint, mouseButton: button) else { return }
        cg.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        cg.postToPid(surface.pid)
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
    /// Still image shown in place of the live page while a See panel is open.
    @Published var chromeSnapshot: NSImage?
    weak var webView: WKWebView?
    weak var webHost: NSView?
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
        webView.customUserAgent = config.userAgent.string
        webView.appearance = config.darkMode ? NSAppearance(named: .darkAqua) : nil
        installUserScripts(in: webView)
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
            controller.addUserScript(WKUserScript(source: PageScripts.hideCSS(config.hiddenSelectors),
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        if config.darkMode {
            controller.addUserScript(WKUserScript(source: PageScripts.darkMode,
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        controller.addUserScript(WKUserScript(source: PageScripts.scrollReporter,
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        if isPickingElements {
            controller.addUserScript(WKUserScript(source: PageScripts.picker,
                                                  injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
    }

    func applyHiddenSelectors() {
        guard let webView, !config.hiddenSelectors.isEmpty else { return }
        webView.evaluateJavaScript(PageScripts.hideCSS(config.hiddenSelectors), completionHandler: nil)
    }

    func setPicking(_ picking: Bool) {
        guard picking != isPickingElements else { return }
        isPickingElements = picking
        debugLog("setPicking \(picking) hidden=\(String(describing: webView?.isHidden))")
        guard let webView else { return }
        installUserScripts(in: webView)
        webView.evaluateJavaScript(picking ? PageScripts.picker : PageScripts.stopPicker,
                                   completionHandler: nil)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.enterChromeMode()
        }
    }

    func didFinishLoad(in webView: WKWebView) {
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
        host.webView.setValue(false, forKey: "drawsBackground")
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
        updateProximity(at: convert(event.locationInWindow, from: nil))
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

private enum SurfaceHandleKind: Equatable { case move, resize }

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


// MARK: - App mirror card

@MainActor
private struct PlacedAppView: View {
    @ObservedObject var surface: AppMirrorSurface
    let onClose: () -> Void

    var body: some View {
        AppMirrorCard(surface: surface, onClose: onClose)
            .position(x: surface.center.x, y: surface.center.y)
    }
}

@MainActor
private struct AppMirrorCard: View {
    @ObservedObject var surface: AppMirrorSurface
    let onClose: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        ZStack(alignment: .top) {
            AppMirrorContentViewRepresentable(surface: surface)
                .frame(width: surface.size.width, height: surface.size.height)
                .background(Color.black.opacity(0.55))

            if surface.status != .live {
                statusOverlay
                    .frame(width: surface.size.width, height: surface.size.height)
            }

            // Drag strip / title
            HStack(spacing: 9) {
                if let icon = surface.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(surface.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                        .frame(width: 20, height: 20).background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(hover.showClose ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: hover.showClose)
            }
            .padding(.horizontal, 10)
            .frame(width: surface.size.width, height: 34)
            .background(
                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .bottom) {
                Capsule().fill(.white.opacity(hover.nearMove ? 0.7 : 0))
                    .frame(width: 46, height: 4).padding(.bottom, 2)
                    .allowsHitTesting(false)
            }

            AppCardDragHandler(surface: surface,
                               onHoverChange: { hover.setHovering($0) },
                               onMoveActive: { hover.nearMove = $0 },
                               onResizeActive: { _ in })
        }
        .frame(width: surface.size.width, height: surface.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(hover.showClose ? 0.24 : 0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(surface.isDragging ? 0.3 : 0.42),
                radius: surface.isDragging ? 18 : 32, y: surface.isDragging ? 8 : 16)
        .transaction { tx in if surface.isDragging { tx.animation = nil } }
    }

    @ViewBuilder private var statusOverlay: some View {
        VStack(spacing: 10) {
            if let icon = surface.icon {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44).opacity(0.9)
            }
            Text(surface.status.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if surface.status == .needsPermission {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }
}

private struct AppCardDragHandler: NSViewRepresentable {
    @ObservedObject var surface: AppMirrorSurface
    let onHoverChange: (Bool) -> Void
    let onMoveActive: (Bool) -> Void
    let onResizeActive: (Bool) -> Void

    func makeNSView(context: Context) -> AppCardDragView {
        let v = AppCardDragView()
        v.surface = surface
        v.onHoverChange = onHoverChange
        v.onMoveActive = onMoveActive
        v.onResizeActive = onResizeActive
        return v
    }

    func updateNSView(_ v: AppCardDragView, context: Context) {
        v.surface = surface
        v.onHoverChange = onHoverChange
        v.onMoveActive = onMoveActive
        v.onResizeActive = onResizeActive
    }
}

@MainActor
private final class AppCardDragView: NSView {
    var surface: AppMirrorSurface?
    var onHoverChange: ((Bool) -> Void)?
    var onMoveActive: ((Bool) -> Void)?
    var onResizeActive: ((Bool) -> Void)?

    private var dragging = false
    private var resizing = false
    private var dragOffset = CGPoint.zero
    private var resizeStart = CGSize.zero
    private var startMouse = CGPoint.zero

    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true); onMoveActive?(true)
    }
    override func mouseExited(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(local) else { return }
        onHoverChange?(false); onMoveActive?(false)
    }

    private var moveRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: 46) }
    private var resizeRect: CGRect { CGRect(x: bounds.width - 34, y: bounds.height - 34, width: 34, height: 34) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if moveRect.contains(local) || resizeRect.contains(local) { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        if resizeRect.contains(local) {
            resizing = true
            resizeStart = surface.size
            startMouse = event.locationInWindow
        } else if moveRect.contains(local) {
            dragging = true
            dragOffset = CGPoint(x: surface.center.x - event.locationInWindow.x,
                                 y: surface.center.y - event.locationInWindow.y)
            surface.isDragging = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let p = event.locationInWindow
        if resizing {
            surface.size = CGSize(width: max(320, resizeStart.width + (p.x - startMouse.x)),
                                  height: max(220, resizeStart.height + (p.y - startMouse.y)))
        } else if dragging {
            surface.center = CGPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false; resizing = false
        surface?.isDragging = false
    }
}

// MARK: - Root overlay

@MainActor
private struct SeeOverlay: View {
    let onClose: () -> Void
    @ObservedObject var model: OverlayModel

    private let white = Color.white
    private let dim = Color.white.opacity(0.58)
    @StateObject private var anim = PeekAnimationState()
    @StateObject private var pointer = PointerWatch()
    private var appeared: Bool { anim.appeared }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black.opacity(0.70).ignoresSafeArea()
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.34), value: appeared)
                RadialGradient(colors: [model.backgroundStyle.tint, .clear],
                               center: .center, startRadius: 60, endRadius: size.height * 0.9)
                    .ignoresSafeArea()
                    .scaleEffect(appeared ? 1 : 1.08)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.55), value: appeared)

                // App mirrors
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, surface in
                    PlacedAppView(surface: surface, onClose: { model.removeApp(surface) })
                        .scaleEffect(appeared ? 1 : 0.95)
                        .opacity(appeared ? 1 : 0)
                        .blur(radius: appeared ? 0 : 10)
                        .animation(.spring(response: 0.55, dampingFraction: 0.86)
                            .delay(Double(index) * 0.045), value: appeared)
                        .zIndex(1 + Double(index))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.92))))
                }

                // Website surfaces
                ForEach(Array(model.websites.enumerated()), id: \.element.id) { index, site in
                    PlacedWebsiteView(site: site,
                                      isFocused: model.focusedID == site.id,
                                      onFocus: { model.focusedID = site.id },
                                      onClose: { model.remove(site) },
                                      onPick: { selector in
                                          site.addHiddenSelector(selector)
                                          site.setPicking(false)
                                          withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                                              model.configuring = site
                                          }
                                      })
                        .scaleEffect(appeared ? 1 : 0.955)
                        .opacity(appeared ? 1 : 0)
                        .blur(radius: appeared ? 0 : 12)
                        .animation(.spring(response: 0.55, dampingFraction: 0.86)
                            .delay(Double(index) * 0.045), value: appeared)
                        .zIndex(model.focusedID == site.id ? 2 : Double(index))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.92))))
                }

                // Native widget surfaces
                ForEach(Array(model.widgets.enumerated()), id: \.element.id) { index, widget in
                    PlacedWidgetView(widget: widget, onClose: { model.removeWidget(widget) })
                        .scaleEffect(appeared ? 1 : 0.94)
                        .opacity(appeared ? 1 : 0)
                        .blur(radius: appeared ? 0 : 12)
                        .animation(.spring(response: 0.55, dampingFraction: 0.86)
                            .delay(Double(model.websites.count + index) * 0.045), value: appeared)
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
                .offset(y: appeared ? 0 : -16)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.9).delay(0.06), value: appeared)
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
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            model.contextMenuPoint = nil; model.surfaceMenu = nil
                        }
                    },
                    isSurfaceAt: { pt in isPointOverSurface(pt, size: size) },
                    contextMenuFrame: { activeMenuFrame(in: size) },
                    onDragCreating: { rect in model.dragCreatingRect = rect },
                    onDragCreated: { rect in
                        model.dragCreatingRect = .null
                        if rect.width > 80 {
                            model.pendingPickerForRect = rect
                            model.pickerCategory = .websites
                            model.pickerSearch = ""
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                model.showingWidgetPicker = true
                            }
                        }
                    }
                )
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            }
            .onChange(of: model.chromeVisible) { _, visible in
                for site in model.websites {
                    if visible { site.enterChromeMode() } else { site.exitChromeMode() }
                }
            }
            .onAppear {
                pointer.start { globalPoint in routeHover(globalPoint) }
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
        guard model.websites.contains(where: { $0.isPickingElements }) else { return }
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let p = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        for site in model.websites where site.isPickingElements {
            let frame = CGRect(x: site.center.x - site.size.width / 2,
                               y: site.center.y - site.size.height / 2,
                               width: site.size.width, height: site.size.height)
            if frame.contains(p) {
                site.hoverAt(CGPoint(x: p.x - frame.minX, y: p.y - frame.minY))
            }
        }
    }

    private func dismissTopmost() {
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
            onClose()
        }
    }

    // MARK: Helpers

    private func openApplication(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? url.deletingPathExtension().lastPathComponent
        withAnimation(.easeOut(duration: 0.18)) { model.showingWidgetPicker = false }
        let workspaceSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        model.addApp(bundleID, name: name, in: workspaceSize, rect: model.pendingPickerForRect)
        model.pendingPickerForRect = nil
    }

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
            let o = menuOrigin(for: pt, size: size, menu: MenuMetrics.workspace)
            return CGRect(origin: o, size: MenuMetrics.workspace)
        }
        if let menu = model.surfaceMenu {
            let o = menuOrigin(for: menu.point, size: size, menu: MenuMetrics.surface)
            return CGRect(origin: o, size: MenuMetrics.surface)
        }
        return nil
    }

    private func isPointOverSurface(_ pt: CGPoint, size: CGSize) -> Bool {
        for (i, site) in model.websites.enumerated() {
            let c = siteCenter(site, index: i, size: size)
            if CGRect(x: c.x - site.size.width/2, y: c.y - site.size.height/2,
                      width: site.size.width, height: site.size.height).contains(pt) { return true }
        }
        for surface in model.apps {
            if CGRect(x: surface.center.x - surface.size.width/2, y: surface.center.y - surface.size.height/2,
                      width: surface.size.width, height: surface.size.height).contains(pt) { return true }
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
                .frame(width: 34, height: 34).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text("SEE").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2.6)
                Text("A little space for what matters").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(dim)
            }
            Spacer()
            HStack(spacing: 8) {
                let count = model.websites.count + model.widgets.count
                if count > 0 {
                    Text("\(count) \(count == 1 ? "surface" : "surfaces")")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(dim)
                }
                Button {
                    debugLog("topBar add pressed")
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.pickerCategory = .websites; model.pickerSearch = ""; model.showingWidgetPicker = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(.white.opacity(0.13), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 34).background(.white.opacity(0.13), in: Circle())
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
        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(dim)
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                if let shot = site.chromeSnapshot {
                    Image(nsImage: shot)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: site.size.width, height: site.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if site.isPickingElements {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(isFocused ? 0.38 : 0.22), radius: isFocused ? 30 : 18, y: 12)
            .onTapGesture(perform: onFocus)
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.18), lineWidth: 1))
                .compositingGroup()
                .shadow(color: .black.opacity(widget.isDragging ? 0.24 : 0.36),
                        radius: widget.isDragging ? 16 : 28, y: widget.isDragging ? 6 : 14)
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
                VStack(alignment: .center, spacing: 7) {
                    Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.62))
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(ink)
                    Text("LOCAL TIME").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(ink.opacity(0.42))
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case .calendar:
            VStack(alignment: .leading, spacing: 14) {
                Text(Date.now, format: .dateTime.month(.wide).year()).font(.system(size: 19, weight: .semibold)).foregroundStyle(ink)
                let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                    ForEach(Array(symbols.enumerated()), id: \.offset) { _, day in
                        Text(day).font(.system(size: 10, weight: .bold)).foregroundStyle(ink.opacity(0.45))
                    }
                    ForEach(Array(Calendar.current.range(of: .day, in: .month, for: .now) ?? 1..<29), id: \.self) { day in
                        let today = Calendar.current.component(.day, from: .now) == day
                        Text("\(day)").font(.system(size: 12, weight: today ? .bold : .regular))
                            .foregroundStyle(today ? Color.black : ink.opacity(0.82))
                            .frame(width: 28, height: 28)
                            .background(today ? Color.white : .clear, in: Circle())
                    }
                }
            }
        case .note:
            VStack(alignment: .leading, spacing: 10) {
                Label("Quick Note", systemImage: "note.text").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink.opacity(0.82))
                TextEditor(text: $widget.note).scrollContentBackground(.hidden).font(.system(size: 15)).foregroundStyle(ink).background(.clear)
            }
        }
    }
}

// MARK: - Context menu

@MainActor
private struct WorkspaceContextMenu: View {
    let onAdd: () -> Void; let onTidy: () -> Void; let onArrange: () -> Void
    let onBackground: () -> Void; let onSettings: () -> Void; let onRemoveAll: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            menuRow("Add New Widgets…", symbol: "rectangle.stack.badge.plus", action: onAdd)
            sep
            menuRow("Tidy Layout", symbol: "sparkles", action: onTidy)
            menuRow("Arrange Layout…", symbol: "square.grid.2x2", action: onArrange)
            sep
            menuRow("Customize Background…", symbol: "circle.lefthalf.filled", action: onBackground)
            sep
            menuRow("Open Settings…", symbol: "gearshape", action: onSettings)
            sep
            menuRow("Remove All Widgets…", symbol: "trash", action: onRemoveAll, destructive: true)
        }
        .padding(7).frame(width: 256)
        .background(Color(white: 0.14).opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 22, y: 10)
    }

    private var sep: some View {
        Rectangle().fill(.white.opacity(0.13)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func menuRow(_ title: String, symbol: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).frame(height: 31).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Widget picker

@MainActor
private struct WidgetPickerOverlay: View {
    @Binding var category: WidgetPickerCategory
    @Binding var search: String
    let onClose: () -> Void
    let onAddWebsite: (String) -> Void
    let onOpenApp: (String) -> Void
    let onAddWidget: (NativeWidgetKind) -> Void

    @FocusState private var searchFocused: Bool

    private let apps: [SelectableApp] = [
        SelectableApp(name: "Calendar", symbol: "calendar", bundleID: "com.apple.iCal"),
        SelectableApp(name: "Notes", symbol: "note.text", bundleID: "com.apple.Notes"),
        SelectableApp(name: "Music", symbol: "music.note", bundleID: "com.apple.Music"),
        SelectableApp(name: "Maps", symbol: "map", bundleID: "com.apple.Maps")
    ]

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
                        case .apps: appContent
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 18)
                }
            }
            .frame(width: 660, height: 438)
            .background(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: .black.opacity(0.44), radius: 34, y: 16)
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
                        Image(systemName: kind.symbol).font(.system(size: 18, weight: .medium))
                            .frame(width: 42, height: 42).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.rawValue).font(.system(size: 13, weight: .semibold))
                            Text("Add to your workspace").font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(0.9)).padding(10)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.09), lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    private var appContent: some View {
        VStack(spacing: 2) {
            ForEach(apps) { app in
                Button {
                    onOpenApp(app.bundleID)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: app.symbol).font(.system(size: 15)).foregroundStyle(.white.opacity(0.84)).frame(width: 24)
                        Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                        Spacer()
                        Text("Add").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("Apps appear live inside your workspace. You can click and scroll them right here.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.40))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
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
    let onClose: () -> Void
    let onArrange: (LayoutStyle) -> Void

    private var title: String {
        switch panel { case .arrange: "Arrange Layout"; case .background: "Customize Background"; case .settings: "See Settings" }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.6)) }.buttonStyle(.plain)
                }
                switch panel {
                case .arrange:
                    Button("Grid", systemImage: "square.grid.2x2") { onArrange(.grid) }.buttonStyle(.bordered)
                    Button("Cascade", systemImage: "square.on.square") { onArrange(.cascade) }.buttonStyle(.bordered)
                case .background:
                    ForEach(Array(WorkspaceBackgroundStyle.allCases.enumerated()), id: \.offset) { _, style in
                        Button { backgroundStyle = style } label: {
                            HStack {
                                Circle().fill(style.tint).frame(width: 20, height: 20)
                                Text(style.title); Spacer()
                                if backgroundStyle == style { Image(systemName: "checkmark") }
                            }.foregroundStyle(.white.opacity(0.9))
                        }.buttonStyle(.plain)
                    }
                case .settings:
                    Text("See keeps your websites and widgets in a freeform workspace.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(20).frame(width: 340)
            .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Surface context menu (right-click on a widget)

@MainActor
private struct SurfaceContextMenu: View {
    let title: String
    let isWebsite: Bool
    var isApp: Bool = false
    let onConfigure: () -> Void
    let onReload: () -> Void
    let onOpenInBrowser: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.top, 5).padding(.bottom, 4)

            if isWebsite {
                row("Configure Widget…", "slider.horizontal.3", onConfigure)
                row("Reload", "arrow.clockwise", onReload)
                row("Open in Browser", "safari", onOpenInBrowser)
                sep
            } else if isApp {
                row("Refresh Mirror", "arrow.clockwise", onReload)
                row("Open App", "arrow.up.forward.app", onOpenInBrowser)
                sep
            }
            row("Remove Widget", "trash", onRemove, destructive: true)
        }
        .padding(7).frame(width: 232)
        .background(Color(white: 0.14).opacity(0.97), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.38), radius: 20, y: 9)
    }

    private var sep: some View {
        Rectangle().fill(.white.opacity(0.13)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func row(_ title: String, _ symbol: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain)
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
        ZStack {
            Color.black.opacity(0.10).ignoresSafeArea().onTapGesture(perform: onDone)
            panel
                .frame(width: 460)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
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
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24).background(.white.opacity(0.1), in: Circle())
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
                            Button(action: onSelectElements) {
                                Text("Select on page…").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ink)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        if site.config.hiddenSelectors.isEmpty {
                            Text("Nothing hidden yet. Click any element on the page to hide it.")
                                .font(.system(size: 11)).foregroundStyle(dim)
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
                                        site.applyTuning(reload: false)
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.6))
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            }
                            HStack {
                                Spacer()
                                Button {
                                    site.config.hiddenSelectors.removeAll()
                                    site.applyTuning(reload: false)
                                } label: {
                                    Text("Clear all").font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(dim)
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
                        onOpenApp: { openApplication($0) },
                        onAddWidget: { model.addNativeWidget($0, in: size, rect: model.pendingPickerForRect) }
                    )
                    .frame(width: size.width, height: size.height)
                }

                if let pt = model.contextMenuPoint {
                    WorkspaceContextMenu(
                        onAdd: { withAnimation { model.contextMenuPoint = nil; model.pickerCategory = .websites; model.showingWidgetPicker = true } },
                        onTidy: { withAnimation { model.contextMenuPoint = nil }; model.tidyLayout(in: size) },
                        onArrange: { withAnimation { model.contextMenuPoint = nil; model.workspacePanel = .arrange } },
                        onBackground: { withAnimation { model.contextMenuPoint = nil; model.workspacePanel = .background } },
                        onSettings: { withAnimation { model.contextMenuPoint = nil; model.workspacePanel = .settings } },
                        onRemoveAll: { withAnimation { model.contextMenuPoint = nil; model.confirmingRemoveAll = true } }
                    )
                    .position(menuCenter(for: pt, size: size, menu: MenuMetrics.workspace))
                    .zIndex(10)
                }

                if let menu = model.surfaceMenu {
                    SurfaceContextMenu(
                        title: menu.site?.title ?? menu.app?.appName ?? menu.widget.map { $0.kind.rawValue } ?? "Widget",
                        isWebsite: menu.site != nil,
                        isApp: menu.app != nil,
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
                            if let app = menu.app { app.start() }
                            menu.site?.reload()
                            withAnimation { model.surfaceMenu = nil }
                        },
                        onOpenInBrowser: {
                            if let app = menu.app {
                                NSWorkspace.shared.runningApplications
                                    .first { $0.bundleIdentifier == app.bundleID }?
                                    .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                            } else if let site = menu.site, let url = URL(string: site.address) {
                                NSWorkspace.shared.open(url)
                            }
                            withAnimation { model.surfaceMenu = nil }
                        },
                        onRemove: {
                            if let site = menu.site { model.remove(site) }
                            if let widget = menu.widget { model.removeWidget(widget) }
                            if let app = menu.app { model.removeApp(app) }
                            withAnimation { model.surfaceMenu = nil }
                        }
                    )
                    .position(menuCenter(for: menu.point, size: size, menu: MenuMetrics.surface))
                    .zIndex(12)
                }

                if let site = model.configuring {
                    ConfigureWidgetOverlay(
                        site: site,
                        onSelectElements: {
                            withAnimation(.easeOut(duration: 0.16)) { model.configuring = nil }
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
                        onClose: { withAnimation { model.workspacePanel = nil } },
                        onArrange: { style in withAnimation { model.tidyLayout(in: size, style: style); model.workspacePanel = nil } }
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
        .onReceive(NotificationCenter.default.publisher(for: .seeEscape)) { _ in dismissChrome() }
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

    private func openApplication(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? url.deletingPathExtension().lastPathComponent
        withAnimation(.easeOut(duration: 0.18)) { model.showingWidgetPicker = false }
        let workspaceSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        model.addApp(bundleID, name: name, in: workspaceSize)
        model.pendingPickerForRect = nil
    }

    private func menuCenter(for point: CGPoint, size: CGSize, menu: CGSize) -> CGPoint {
        let o = menuOrigin(for: point, size: size, menu: menu)
        return CGPoint(x: o.x + menu.width / 2, y: o.y + menu.height / 2)
    }
}
