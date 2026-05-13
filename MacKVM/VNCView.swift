import SwiftUI

// Default PiKVM connection parameters
private let defaultHost     = "192.168.50.102"
private let defaultPort     = "5902"
private let defaultPassword = "berecik"

struct VNCView: View {

    @StateObject private var client = VNCClient()

    @State private var host     = defaultHost
    @State private var port     = defaultPort
    @State private var password = defaultPassword

    var body: some View {
        VStack(spacing: 0) {
            if !client.isConnected || client.errorMessage != nil {
                toolbar
                Divider()
            }
            content
        }
#if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
#endif
        .task {
            // Auto-connect on launch if defaults are configured
            guard let portNum = Int(port), !host.isEmpty, !port.isEmpty else { return }
            await client.connect(host: host, port: portNum, password: password)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundColor(.secondary)

            TextField("Host", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .disabled(client.isConnected)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(client.isConnected)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .disabled(client.isConnected)

            Spacer()

            if let err = client.errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 300)
            }

            connectButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var connectButton: some View {
        Button {
            if client.isConnected {
                client.disconnect()
            } else {
                guard let portNum = Int(port) else { return }
                Task {
                    await client.connect(host: host, port: portNum, password: password)
                }
            }
        } label: {
            Label(client.isConnected ? "Disconnect" : "Connect",
                  systemImage: client.isConnected ? "stop.circle" : "play.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(client.isConnected ? .red : .blue)
        .disabled(!client.isConnected && (host.isEmpty || port.isEmpty))
    }

    // MARK: - Main content area

    @ViewBuilder
    private var content: some View {
        if let image = client.image {
            FramebufferView(cgImage: image, client: client)
        } else if client.isConnected {
            ProgressView("Waiting for framebuffer…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
#if os(macOS)
                Color(NSColor.underPageBackgroundColor)
#else
                Color(UIColor.systemGroupedBackground)
#endif
                VStack(spacing: 16) {
                    Image(systemName: "display")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("PiKVM")
                        .font(.title)
                        .foregroundColor(.primary)
                    Text("\(host):\(port)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Framebuffer view (platform-specific)

#if os(macOS)

struct FramebufferView: NSViewRepresentable {
    let cgImage: CGImage
    let client: VNCClient

    func makeNSView(context: Context) -> VNCNSView {
        let v = VNCNSView()
        v.client = client
        return v
    }

    func updateNSView(_ nsView: VNCNSView, context: Context) {
        nsView.cgImage = cgImage
        nsView.client = client
        nsView.needsDisplay = true
    }
}

// MARK: - Custom NSView for drawing and input (macOS)

final class VNCNSView: NSView {

    var cgImage: CGImage?
    weak var client: VNCClient?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let img = cgImage else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        let imgW = CGFloat(img.width)
        let imgH = CGFloat(img.height)
        guard imgW > 0, imgH > 0 else { return }
        let scale = min(bounds.width / imgW, bounds.height / imgH)
        let dw = imgW * scale
        let dh = imgH * scale
        let ox = (bounds.width  - dw) / 2
        let oy = (bounds.height - dh) / 2
        ctx.draw(img, in: CGRect(x: ox, y: oy, width: dw, height: dh))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { sendKey(event: event, down: true) }
    override func keyUp(with event: NSEvent)   { sendKey(event: event, down: false) }

    private func sendKey(event: NSEvent, down: Bool) {
        guard let keysym = x11Keysym(for: event) else { return }
        Task { @MainActor in client?.sendKeyEvent(keysym: keysym, down: down) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { Task { @MainActor in client?.disconnect() }; return }
        sendPointer(event: event, mask: 1)
    }
    override func mouseUp(with event: NSEvent)        { if event.clickCount < 2 { sendPointer(event: event, mask: 0) } }
    override func mouseDragged(with event: NSEvent)   { sendPointer(event: event, mask: 1) }
    override func rightMouseDown(with event: NSEvent) { sendPointer(event: event, mask: 4) }
    override func rightMouseUp(with event: NSEvent)   { sendPointer(event: event, mask: 0) }
    override func mouseMoved(with event: NSEvent)     { sendPointer(event: event, mask: 0) }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        let dx = event.scrollingDeltaX
        guard dy != 0 || dx != 0 else { return }
        let stepsY = dy > 0 ? max(1, Int(dy / 3)) : dy < 0 ? -max(1, Int(-dy / 3)) : 0
        let stepsX = dx > 0 ? max(1, Int(dx / 3)) : dx < 0 ? -max(1, Int(-dx / 3)) : 0
        for _ in 0..<abs(stepsY) { let b = dy > 0 ? 8 : 16; sendPointer(event: event, mask: b); sendPointer(event: event, mask: 0) }
        for _ in 0..<abs(stepsX) { let b = dx > 0 ? 64 : 32; sendPointer(event: event, mask: b); sendPointer(event: event, mask: 0) }
    }

    private func sendPointer(event: NSEvent, mask: Int) {
        guard let img = cgImage, let client else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let imgW = CGFloat(img.width), imgH = CGFloat(img.height)
        let scale = min(bounds.width / imgW, bounds.height / imgH)
        let ox = (bounds.width  - imgW * scale) / 2
        let oy = (bounds.height - imgH * scale) / 2
        let nx = (loc.x - ox) / scale
        let ny = imgH - (loc.y - oy) / scale   // flip: NSView bottom-left, VNC top-left
        let x = max(0, min(Int(nx), img.width  - 1))
        let y = max(0, min(Int(ny), img.height - 1))
        Task { @MainActor in client.sendPointerEvent(x: x, y: y, buttonMask: mask) }
    }

    // MARK: Tracking area

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds,
                                      options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
}

#else // iOS / iPadOS

struct FramebufferView: UIViewRepresentable {
    let cgImage: CGImage
    let client: VNCClient

    func makeUIView(context: Context) -> VNCUIView {
        let v = VNCUIView()
        v.client = client
        return v
    }

    func updateUIView(_ uiView: VNCUIView, context: Context) {
        uiView.cgImage = cgImage
        uiView.client = client
        uiView.setNeedsDisplay()
    }
}

// MARK: - Custom UIView for drawing and touch input (iOS)

final class VNCUIView: UIView {

    var cgImage: CGImage?
    weak var client: VNCClient?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        // Pinch gesture for disconnect (double-tap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let img = cgImage else { return }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(bounds)
        let imgW = CGFloat(img.width)
        let imgH = CGFloat(img.height)
        guard imgW > 0, imgH > 0 else { return }
        let scale = min(bounds.width / imgW, bounds.height / imgH)
        let dw = imgW * scale
        let dh = imgH * scale
        let ox = (bounds.width  - dw) / 2
        let oy = (bounds.height - dh) / 2
        // UIKit coordinate system is top-left; flip vertically for correct rendering
        ctx.saveGState()
        ctx.translateBy(x: ox, y: oy + dh)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        ctx.restoreGState()
    }

    // MARK: Touch → RFB pointer events

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(touch: t, mask: 1)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(touch: t, mask: 1)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(touch: t, mask: 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(touch: t, mask: 0)
    }

    @objc private func handleDoubleTap() {
        Task { @MainActor in client?.disconnect() }
    }

    private func sendPointer(touch: UITouch, mask: Int) {
        guard let img = cgImage, let client else { return }
        let loc = touch.location(in: self)
        let imgW = CGFloat(img.width), imgH = CGFloat(img.height)
        let scale = min(bounds.width / imgW, bounds.height / imgH)
        let ox = (bounds.width  - imgW * scale) / 2
        let oy = (bounds.height - imgH * scale) / 2
        let nx = (loc.x - ox) / scale
        let ny = (loc.y - oy) / scale   // UIKit already top-left
        let x = max(0, min(Int(nx), img.width  - 1))
        let y = max(0, min(Int(ny), img.height - 1))
        Task { @MainActor in client.sendPointerEvent(x: x, y: y, buttonMask: mask) }
    }
}

#endif

// MARK: - X11 keysym mapping (macOS only — no hardware keyboard API on iOS)

#if os(macOS)
private func x11Keysym(for event: NSEvent) -> UInt32? {
    // Handle special keys first
    guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
        return specialKeysym(event.keyCode)
    }
    let scalar = chars.unicodeScalars.first!.value
    // Latin-1 passthrough (0x20..0xFF)
    if scalar >= 0x20 && scalar <= 0xFF { return scalar }
    // BMP characters map to Unicode keysyms (0x01000000 | codepoint)
    if scalar >= 0x100 { return 0x01000000 | scalar }
    return specialKeysym(event.keyCode) ?? scalar
}

private func specialKeysym(_ keyCode: UInt16) -> UInt32? {
    // macOS virtual key codes → X11 keysyms
    switch keyCode {
    case 36:  return 0xFF0D // Return
    case 48:  return 0xFF09 // Tab
    case 49:  return 0x0020 // Space
    case 51:  return 0xFF08 // BackSpace
    case 53:  return 0xFF1B // Escape
    case 55:  return 0xFFE3 // Left Cmd → Left Ctrl (KVM)
    case 56:  return 0xFFE1 // Left Shift
    case 57:  return 0xFFE5 // Caps Lock
    case 58:  return 0xFFE9 // Left Alt
    case 59:  return 0xFFE3 // Left Ctrl
    case 60:  return 0xFFE2 // Right Shift
    case 61:  return 0xFFEA // Right Alt
    case 62:  return 0xFFE4 // Right Ctrl
    case 63:  return 0xFFEB // Fn → Super
    case 123: return 0xFF51 // Left arrow
    case 124: return 0xFF53 // Right arrow
    case 125: return 0xFF54 // Down arrow
    case 126: return 0xFF52 // Up arrow
    case 115: return 0xFF50 // Home
    case 116: return 0xFF55 // Page Up
    case 117: return 0xFFFF // Delete
    case 119: return 0xFF57 // End
    case 121: return 0xFF56 // Page Down
    case 71:  return 0xFF7F // Clear / Num Lock
    case 76:  return 0xFF8D // Keypad Enter
    case 122: return 0xFFBE // F1
    case 120: return 0xFFBF // F2
    case 99:  return 0xFFC0 // F3
    case 118: return 0xFFC1 // F4
    case 96:  return 0xFFC2 // F5
    case 97:  return 0xFFC3 // F6
    case 98:  return 0xFFC4 // F7
    case 100: return 0xFFC5 // F8
    case 101: return 0xFFC6 // F9
    case 109: return 0xFFC7 // F10
    case 103: return 0xFFC8 // F11
    case 111: return 0xFFC9 // F12
    default:  return nil
    }
}
#endif // os(macOS)

#Preview {
    VNCView()
}
