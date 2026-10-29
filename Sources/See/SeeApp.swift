import AppKit
import QuartzCore
import Combine
import SwiftUI
import WebKit

extension Notification.Name {
    static let seeEscape = Notification.Name("SeeEscapePressed")
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.48
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { Task { @MainActor in panel.orderOut(nil); panel.alphaValue = 1 } })
    }

    private func makePanel() -> SeeOverlayPanel {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = SeeOverlayPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: SeeOverlay(onClose: { [weak self] in self?.hidePanel() }))
        return panel
    }
}

private final class SeeOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .rightMouseDown:
                if self.isSurfaceAt?(point) == true { self.onDismiss?(); return event }
                self.onRightClick?(point); return nil
            case .leftMouseDown:
                debugLog("left down at \(point) key=\(self.window?.isKeyWindow == true) active=\(NSApp.isActive)")
                if let menuFrame = self.contextMenuFrame?(), !menuFrame.contains(point) { self.onDismiss?() }
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

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var websites: [WebsiteSurface] = []
    @Published var widgets: [NativeWidgetSurface] = []
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

    init() { } // No pre-seeded sites

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
private enum WorkspaceBackgroundStyle: CaseIterable {
    case midnight, charcoal, plum
    var title: String { switch self { case .midnight: "Midnight"; case .charcoal: "Charcoal"; case .plum: "Plum" } }
    var tint: Color { switch self { case .midnight: Color.indigo.opacity(0.17); case .charcoal: Color.gray.opacity(0.16); case .plum: Color.purple.opacity(0.2) } }
}

private struct SelectableApp: Identifiable {
    let name: String; let symbol: String; let bundleID: String
    var id: String { bundleID }
}

// MARK: - Surface models

@MainActor
private final class NativeWidgetSurface: ObservableObject, Identifiable {
    let id = UUID()
    let kind: NativeWidgetKind
    @Published var center: CGPoint
    @Published var size: CGSize
    @Published var note = ""
    @Published var isDragging = false
    init(kind: NativeWidgetKind, center: CGPoint) { self.kind = kind; self.center = center; self.size = kind.size }
}

@MainActor
private final class WebsiteSurface: ObservableObject, Identifiable {
    let id = UUID()
    @Published var address: String
    @Published var title: String
    @Published private(set) var requestedURL: URL
    @Published private(set) var requestID = 0
    @Published var center: CGPoint
    @Published var size: CGSize {
        didSet { debugLog("site size \(oldValue.width)x\(oldValue.height) -> \(size.width)x\(size.height)") }
    }
    weak var webView: WKWebView?

    init(address: String, title: String, center: CGPoint) {
        let safe = URL(string: address) ?? URL(string: "https://example.com")!
        self.address = safe.absoluteString; self.title = title
        self.requestedURL = safe; self.center = center
        self.size = CGSize(width: 1060, height: 790)
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
}

// MARK: - WebKit views

@MainActor
private struct WebsiteView: NSViewRepresentable {
    @ObservedObject var site: WebsiteSurface
    let onHoverChange: (Bool) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WebsiteHostView {
        let host = WebsiteHostView(site: site)
        host.onHoverChange = onHoverChange
        host.onClose = onClose
        host.webView.allowsBackForwardNavigationGestures = true
        host.webView.setValue(false, forKey: "drawsBackground")
        host.webView.customUserAgent = WebsiteView.modernUserAgent
        site.webView = host.webView
        context.coordinator.lastRequestID = site.requestID
        host.webView.load(URLRequest(url: site.requestedURL))
        return host
    }

    // WebKit's default UA makes some sites (Google included) serve their
    // simplified legacy markup, so present a current desktop Chrome identity.
    static let modernUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    func updateNSView(_ host: WebsiteHostView, context: Context) {
        host.onHoverChange = onHoverChange
        host.onClose = onClose
        site.webView = host.webView
        guard context.coordinator.lastRequestID != site.requestID else { return }
        context.coordinator.lastRequestID = site.requestID
        host.webView.load(URLRequest(url: site.requestedURL))
    }

    final class Coordinator { var lastRequestID = -1 }
}

@MainActor
private final class WebsiteHostView: NSView {
    private let site: WebsiteSurface
    let webView = WKWebView()
    private let handles: WebsiteHandleView
    var onHoverChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    init(site: WebsiteSurface) {
        self.site = site; handles = WebsiteHandleView(site: site)
        super.init(frame: .zero)
        addSubview(webView); addSubview(handles, positioned: .above, relativeTo: webView)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

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

    var body: some View {
        WebsiteSurfaceView(site: site, isFocused: isFocused, onFocus: onFocus, onClose: onClose)
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
    @StateObject private var model = OverlayModel()

    private let white = Color.white
    private let dim = Color.white.opacity(0.58)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black.opacity(0.70).ignoresSafeArea()
                RadialGradient(colors: [model.backgroundStyle.tint, .clear],
                               center: .center, startRadius: 60, endRadius: size.height * 0.9)
                    .ignoresSafeArea()

                // Website surfaces
                ForEach(Array(model.websites.enumerated()), id: \.element.id) { index, site in
                    PlacedWebsiteView(site: site,
                                      isFocused: model.focusedID == site.id,
                                      onFocus: { model.focusedID = site.id },
                                      onClose: { model.remove(site) })
                        .zIndex(model.focusedID == site.id ? 2 : Double(index))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94)),
                            removal: .opacity.combined(with: .scale(scale: 0.92))))
                }

                // Native widget surfaces
                ForEach(Array(model.widgets.enumerated()), id: \.element.id) { index, widget in
                    PlacedWidgetView(widget: widget, onClose: { model.removeWidget(widget) })
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
                .zIndex(60)   // chrome stays usable above live website surfaces
            }
            .frame(width: size.width, height: size.height)
            .background {
                WorkspaceInteractionMonitor(
                    onRightClick: { pt in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            model.contextMenuPoint = pt; model.workspacePanel = nil
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.16)) { model.contextMenuPoint = nil }
                    },
                    isSurfaceAt: { pt in isPointOverSurface(pt, size: size) },
                    contextMenuFrame: { model.contextMenuPoint.map { contextMenuFrame(at: $0, size: size) } },
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
            .overlay {
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
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
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
                        .position(contextMenuCenter(at: pt, size: size))
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(10)
                    }

                    if let panel = model.workspacePanel {
                        WorkspaceOptionsOverlay(
                            panel: panel,
                            backgroundStyle: $model.backgroundStyle,
                            onClose: { withAnimation { model.workspacePanel = nil } },
                            onArrange: { style in withAnimation { model.tidyLayout(in: size, style: style); model.workspacePanel = nil } }
                        )
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.showingWidgetPicker)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.contextMenuPoint != nil)
                .animation(.easeInOut(duration: 0.2), value: model.workspacePanel != nil)
            }
            .confirmationDialog("Remove all widgets?", isPresented: $model.confirmingRemoveAll, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) {
                    withAnimation { model.websites.removeAll(); model.widgets.removeAll() }
                }
                Button("Cancel", role: .cancel) { }
            }
            .onAppear {
                debugLog("overlay appear active=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.title))")
                guard !model.hasPlacedInitialSite else { return }
                model.hasPlacedInitialSite = true
            }
        }
        .onExitCommand { dismissTopmost() }
        .onReceive(NotificationCenter.default.publisher(for: .seeEscape)) { _ in dismissTopmost() }
        .preferredColorScheme(.dark)
    }

    private func dismissTopmost() {
        if model.showingWidgetPicker {
            withAnimation(.easeOut(duration: 0.18)) {
                model.showingWidgetPicker = false
                model.pendingPickerForRect = nil
                model.dragCreatingRect = .null
            }
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
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        withAnimation(.easeOut(duration: 0.18)) { model.showingWidgetPicker = false }
        // Give up See's key/active state first, otherwise the launched app is
        // opened behind the floating See panel.
        NSApp.deactivate()
        hideSeeWindow()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            guard let app else { debugLog("open app failed \(String(describing: error))"); return }
            Task { @MainActor in
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
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

    private func contextMenuCenter(at pt: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(pt.x + 128, 128), size.width - 128),
                y: min(max(pt.y + 132, 132), size.height - 132))
    }

    private func contextMenuFrame(at pt: CGPoint, size: CGSize) -> CGRect {
        let c = contextMenuCenter(at: pt, size: size)
        return CGRect(x: c.x - 128, y: c.y - 132, width: 256, height: 264)
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

    var body: some View {
        WebsiteView(site: site, onHoverChange: { _ in }, onClose: onClose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: site.size.width, height: site.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
                VStack(alignment: .leading, spacing: 7) {
                    Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.62))
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(ink)
                    Text("LOCAL TIME").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(ink.opacity(0.42))
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.55))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.88), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                        Text("Open app").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("Apps open in their own window. See steps aside so you can use them.")
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
