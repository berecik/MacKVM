import SwiftUI

// MARK: - Profile edit sheet

struct ProfileEditView: View {
    @Binding var profile: VNCProfile
    var isNew: Bool
    var onSave: (VNCProfile) -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)? = nil   // nil when creating a new profile

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label (optional)", text: $profile.name)
                }
                Section("Connection") {
                    TextField("Host / IP", text: $profile.host)
#if os(iOS)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
#endif
                    TextField("Port", text: $profile.port)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                    SecureField("Password", text: $profile.password)
                }

                // Delete button — only shown for existing profiles
                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Profile")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Profile" : "Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(profile) }
                        .disabled(profile.host.isEmpty || profile.port.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
#if os(macOS)
        .frame(width: 340, height: isNew ? 280 : 320)
#endif
    }
}

// MARK: - Profile chip

/// A single pill button representing one saved profile.
struct ProfileChip: View {
    let profile: VNCProfile
    let isConnected: Bool
    let isActive: Bool        // last-used / currently connecting
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                // Connection state icon
                Image(systemName: isConnected ? "stop.circle.fill" : "play.circle")
                    .font(.system(size: 18, weight: isActive ? .bold : .regular))
                    .foregroundColor(isConnected ? .red : (isActive ? .accentColor : .secondary))

                Text(profile.chipLabel)
                    .font(.system(size: 10, weight: isActive ? .bold : .regular))
                    .lineLimit(1)
                    .foregroundColor(isActive ? .primary : .secondary)

                Text(profile.port)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(width: 64)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isConnected ? Color.red.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
#if os(iOS)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() })
#endif
        .help("\(profile.host):\(profile.port)")
    }
}

// MARK: - VNCView

struct VNCView: View {

    @StateObject private var client = VNCClient()
    @StateObject private var store  = ProfileStore()

    /// When true the toolbar stays visible even while connected.
    @State private var toolbarPinned: Bool = true

    // Profile editing
    @State private var editingProfile: VNCProfile? = nil
    @State private var isNewProfile: Bool = false

    private var showToolbar: Bool {
        toolbarPinned || !client.isConnected || client.errorMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if showToolbar {
                toolbar
                Divider()
            }
            content
        }
#if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
#endif
        .sheet(item: $editingProfile) { profile in
            // Binding into the sheet — changes are committed only on Save
            ProfileEditSheet(
                initial: profile,
                isNew: isNewProfile,
                onSave: { saved in
                    if isNewProfile { store.add(saved) } else { store.update(saved) }
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil },
                onDelete: isNewProfile ? nil : {
                    store.delete(profile)
                    editingProfile = nil
                }
            )
        }
        .task {
            // Auto-connect to the last-used / first profile on launch
            if let p = store.profiles.first {
                store.activeProfileID = p.id
                guard let portNum = Int(p.port), !p.host.isEmpty else { return }
                await client.connect(host: p.host, port: portNum, password: p.password)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            // Profiles row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.profiles) { profile in
                        let isConn = client.isConnected && store.activeProfileID == profile.id
                        let isActive = store.activeProfileID == profile.id

                        ProfileChip(
                            profile: profile,
                            isConnected: isConn,
                            isActive: isActive,
                            onTap: { handleTap(profile) },
                            onLongPress: {
                                isNewProfile = false
                                editingProfile = profile
                            }
                        )
#if os(macOS)
                        .contextMenu {
                            Button("Settings…") {
                                isNewProfile = false
                                editingProfile = profile
                            }
                        }
#endif
                    }

                    // "Add profile" button
                    Button {
                        isNewProfile = true
                        editingProfile = VNCProfile(name: "", host: "", port: "5902", password: "")
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .help("Add profile")
                }
                .padding(.horizontal, 8)
            }

            // Error message
            if let err = client.errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240)
            }

            Spacer(minLength: 0)

            // Pin button
            Button { toolbarPinned.toggle() } label: {
                Image(systemName: toolbarPinned ? "pin.fill" : "pin.slash")
                    .foregroundColor(toolbarPinned ? .accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(toolbarPinned ? "Unpin toolbar" : "Pin toolbar")
            .padding(.trailing, 10)
        }
        .padding(.vertical, 4)
    }

    private func handleTap(_ profile: VNCProfile) {
        let isConn = client.isConnected && store.activeProfileID == profile.id
        if isConn {
            client.disconnect()
        } else {
            if client.isConnected { client.disconnect() }
            store.activeProfileID = profile.id
            guard let portNum = Int(profile.port), !profile.host.isEmpty else { return }
            Task {
                await client.connect(host: profile.host, port: portNum, password: profile.password)
                // Mark last connected timestamp
                store.touch(host: profile.host, port: profile.port,
                            password: profile.password, name: profile.name)
            }
        }
    }

    // MARK: - Main content area

    @ViewBuilder
    private var content: some View {
        if let image = client.image {
            FramebufferView(cgImage: image, client: client, onDoubleTap: {
                client.disconnect()
                toolbarPinned = true
            })
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
                    if let p = store.profiles.first(where: { $0.id == store.activeProfileID }) {
                        Text(p.chipLabel)
                            .font(.title)
                            .foregroundColor(.primary)
                        Text("\(p.host):\(p.port)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Wrapper so the sheet gets its own copy to edit

private struct ProfileEditSheet: View {
    let initial: VNCProfile
    let isNew: Bool
    let onSave: (VNCProfile) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    @State private var draft: VNCProfile

    init(initial: VNCProfile, isNew: Bool,
         onSave: @escaping (VNCProfile) -> Void,
         onCancel: @escaping () -> Void,
         onDelete: (() -> Void)? = nil) {
        self.initial   = initial
        self.isNew     = isNew
        self.onSave    = onSave
        self.onCancel  = onCancel
        self.onDelete  = onDelete
        _draft = State(initialValue: initial)
    }

    var body: some View {
        ProfileEditView(profile: $draft, isNew: isNew, onSave: onSave, onCancel: onCancel, onDelete: onDelete)
    }
}

// MARK: - Framebuffer view (platform-specific)

#if os(macOS)

struct FramebufferView: NSViewRepresentable {
    let cgImage: CGImage
    let client: VNCClient
    var onDoubleTap: () -> Void = {}

    func makeNSView(context: Context) -> VNCNSView {
        let v = VNCNSView()
        v.client = client
        v.onDoubleTap = onDoubleTap
        return v
    }

    func updateNSView(_ nsView: VNCNSView, context: Context) {
        nsView.cgImage = cgImage
        nsView.client = client
        nsView.onDoubleTap = onDoubleTap
        nsView.needsDisplay = true
    }
}

// MARK: - Custom NSView for drawing and input (macOS)

final class VNCNSView: NSView {

    var cgImage: CGImage?
    weak var client: VNCClient?
    var onDoubleTap: () -> Void = {}

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

    // MARK: Modifier keys (Ctrl, Shift, Alt, Cmd, Fn)
    // On macOS, modifier keys do not generate keyDown/keyUp events — they
    // arrive only via flagsChanged. We track the previous flags so we can
    // distinguish press (bit newly set) from release (bit newly cleared).

    private var lastModifierFlags: NSEvent.ModifierFlags = []

    override func flagsChanged(with event: NSEvent) {
        let current  = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let previous = lastModifierFlags
        lastModifierFlags = current

        // Each modifier maps to one keysym. Cmd is mapped to Ctrl (KVM convention).
        // Cmd is intentionally excluded here so Cmd+C / Cmd+V can be intercepted
        // in keyDown without also sending a spurious Ctrl-down to the remote.
        let modifierMap: [(NSEvent.ModifierFlags, UInt32)] = [
            (.shift,   0xFFE1), // Left Shift
            (.control, 0xFFE3), // Left Ctrl
            (.option,  0xFFE9), // Left Alt
            (.capsLock,0xFFE5), // Caps Lock
            (.function,0xFFEB), // Fn → Super
        ]

        for (flag, keysym) in modifierMap {
            let wasDown = previous.contains(flag)
            let isDown  = current.contains(flag)
            if isDown && !wasDown {
                Task { @MainActor in self.client?.sendKeyEvent(keysym: keysym, down: true) }
            } else if !isDown && wasDown {
                Task { @MainActor in self.client?.sendKeyEvent(keysym: keysym, down: false) }
            }
        }
    }

    // MARK: Host clipboard integration & Cmd shortcuts
    //
    // Cmd+C  → copy the remote's clipboard (ServerCutText) to the host pasteboard.
    //          X11 apps send ServerCutText when text is selected; pressing Cmd+C
    //          here captures whatever the remote last sent and puts it on macOS.
    // Cmd+V  → middle-click at the current pointer position.
    //          On X11, selecting text populates the primary selection buffer, and
    //          middle-click pastes from it. Pressing Cmd+V middle-clicks the remote
    //          so you can paste from the primary selection without a physical wheel.
    // Cmd+T  → type the macOS clipboard into the remote as keystrokes.
    //          Lets you compose text on the Mac and send it to the remote terminal.
    // Other Cmd+key → forward as Ctrl+key (standard KVM convention).

    // Last known pointer position in VNC framebuffer coordinates (for middle-click).
    private var lastPointerVNCPos: (x: Int, y: Int) = (0, 0)

    private func handleCmdShortcut(event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers else { return false }

        switch chars.lowercased() {
        case "c":
            // Copy remote clipboard → host pasteboard
            if let text = client?.remoteClipboard, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        case "v":
            // Middle-click at the current remote pointer position (X11 primary selection paste)
            let (px, py) = lastPointerVNCPos
            Task { @MainActor in
                self.client?.sendPointerEvent(x: px, y: py, buttonMask: 2)
                self.client?.sendPointerEvent(x: px, y: py, buttonMask: 0)
            }
            return true
        case "t":
            // Type host clipboard text as keystrokes into the remote
            Task { @MainActor in self.typeHostClipboard() }
            return true
        default:
            // Forward other Cmd+key as Ctrl+key
            Task { @MainActor in
                self.client?.sendKeyEvent(keysym: 0xFFE3, down: true)   // Ctrl down
                if let keysym = x11Keysym(for: event) {
                    self.client?.sendKeyEvent(keysym: keysym, down: true)
                    self.client?.sendKeyEvent(keysym: keysym, down: false)
                }
                self.client?.sendKeyEvent(keysym: 0xFFE3, down: false)  // Ctrl up
            }
            return true
        }
    }

    private func typeHostClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        // Send each Unicode scalar as a keysym.
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let keysym: UInt32
            if v == 0x0A || v == 0x0D {
                keysym = 0xFF0D // Return
            } else if v >= 0x20 && v <= 0xFF {
                keysym = v
            } else if v > 0xFF {
                keysym = 0x01000000 | v
            } else {
                continue
            }
            client?.sendKeyEvent(keysym: keysym, down: true)
            client?.sendKeyEvent(keysym: keysym, down: false)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if handleCmdShortcut(event: event) { return }
        sendKey(event: event, down: true)
    }
    override func keyUp(with event: NSEvent) {
        // Don't forward Cmd+key releases — handled in handleCmdShortcut
        if event.modifierFlags.contains(.command) { return }
        sendKey(event: event, down: false)
    }

    private func sendKey(event: NSEvent, down: Bool) {
        guard let keysym = x11Keysym(for: event) else { return }
        Task { @MainActor in client?.sendKeyEvent(keysym: keysym, down: down) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { Task { @MainActor in onDoubleTap() }; return }
        sendPointer(event: event, mask: 1)
    }
    override func mouseUp(with event: NSEvent)        { if event.clickCount < 2 { sendPointer(event: event, mask: 0) } }
    override func mouseDragged(with event: NSEvent)   { sendPointer(event: event, mask: 1) }
    override func rightMouseDown(with event: NSEvent) { sendPointer(event: event, mask: 4) }
    override func rightMouseUp(with event: NSEvent)   { sendPointer(event: event, mask: 0) }
    override func mouseMoved(with event: NSEvent)     { sendPointer(event: event, mask: 0) }

    // Middle mouse button (wheel-click) = RFB button mask bit 1 (value 2)
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { sendPointer(event: event, mask: 2) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { sendPointer(event: event, mask: 0) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2 { sendPointer(event: event, mask: 2) }
    }

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
        lastPointerVNCPos = (x, y)
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
    var onDoubleTap: () -> Void = {}

    func makeUIView(context: Context) -> VNCUIView {
        let v = VNCUIView()
        v.client = client
        v.onDoubleTap = onDoubleTap
        wireHover(v)
        return v
    }

    func updateUIView(_ uiView: VNCUIView, context: Context) {
        uiView.cgImage = cgImage
        uiView.client = client
        uiView.onDoubleTap = onDoubleTap
        uiView.setNeedsDisplay()
    }
}

// MARK: - Custom UIView for drawing, touch, keyboard, and pointer input (iOS)

final class VNCUIView: UIView {

    var cgImage: CGImage?
    weak var client: VNCClient?
    var onDoubleTap: () -> Void = {}

    // Last known pointer position (for scroll events that don't carry location)
    private var lastPointerX: Int = 0
    private var lastPointerY: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false

        // Double-tap to disconnect and reveal toolbar
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        // Scroll wheel via pan gesture (two-finger pan on trackpad arrives as scroll)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        addGestureRecognizer(scroll)

        // Pointer interaction for trackpad/mouse hover and button events
        addInteraction(UIPointerInteraction(delegate: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    // Become first responder so we receive hardware keyboard events
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    // MARK: Drawing

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
        // CGImage is bottom-left origin; flip vertically for UIKit (top-left)
        ctx.saveGState()
        ctx.translateBy(x: ox, y: oy + dh)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        ctx.restoreGState()
    }

    // MARK: Hardware keyboard (iPad with Smart Keyboard / Magic Keyboard)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if handleCmdShortcut(key: key) { continue }
            if let keysym = uiKeyToKeysym(key) {
                Task { @MainActor in self.client?.sendKeyEvent(keysym: keysym, down: true) }
            } else {
                super.pressesBegan([press], with: event)
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            // Suppress Cmd+key releases that we already intercepted
            if key.modifierFlags.contains(.command) { continue }
            if let keysym = uiKeyToKeysym(key) {
                Task { @MainActor in self.client?.sendKeyEvent(keysym: keysym, down: false) }
            } else {
                super.pressesEnded([press], with: event)
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    // MARK: Cmd shortcut interception (iPad hardware keyboard)
    //
    // Matches the macOS semantics in VNCNSView.handleCmdShortcut:
    //   Cmd+C → copy remote clipboard (ServerCutText) to iOS pasteboard
    //   Cmd+V → middle-click at current pointer (X11 primary selection paste)
    //   Cmd+T → type iOS pasteboard text as keystrokes into remote
    //   Other Cmd+key → forward as Ctrl+key

    @discardableResult
    private func handleCmdShortcut(key: UIKey) -> Bool {
        guard key.modifierFlags.contains(.command) else { return false }
        let chars = key.charactersIgnoringModifiers.lowercased()
        switch chars {
        case "c":
            // Copy remote clipboard → iOS pasteboard
            if let text = client?.remoteClipboard, !text.isEmpty {
                UIPasteboard.general.string = text
            }
            return true
        case "v":
            // Middle-click at current remote pointer (X11 primary selection paste)
            let (px, py) = (lastPointerX, lastPointerY)
            Task { @MainActor in
                self.client?.sendPointerEvent(x: px, y: py, buttonMask: 2)
                self.client?.sendPointerEvent(x: px, y: py, buttonMask: 0)
            }
            return true
        case "t":
            // Type iOS pasteboard text as keystrokes into remote
            Task { @MainActor in self.typeHostClipboard() }
            return true
        default:
            // Forward other Cmd+key as Ctrl+key
            if let keysym = uiKeyToKeysym(key) {
                Task { @MainActor in
                    self.client?.sendKeyEvent(keysym: 0xFFE3, down: true)   // Ctrl down
                    self.client?.sendKeyEvent(keysym: keysym, down: true)
                    self.client?.sendKeyEvent(keysym: keysym, down: false)
                    self.client?.sendKeyEvent(keysym: 0xFFE3, down: false)  // Ctrl up
                }
            }
            return true
        }
    }

    private func typeHostClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let keysym: UInt32
            if v == 0x0A || v == 0x0D {
                keysym = 0xFF0D // Return
            } else if v >= 0x20 && v <= 0xFF {
                keysym = v
            } else if v > 0xFF {
                keysym = 0x01000000 | v
            } else {
                continue
            }
            client?.sendKeyEvent(keysym: keysym, down: true)
            client?.sendKeyEvent(keysym: keysym, down: false)
        }
    }

    // MARK: Touch → RFB pointer (finger touch on screen)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        guard let t = touches.first else { return }
        // Ignore if this came from the double-tap recogniser
        sendPointer(at: t.location(in: self), mask: 1)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(at: t.location(in: self), mask: 1)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(at: t.location(in: self), mask: 0)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        sendPointer(at: t.location(in: self), mask: 0)
    }

    @objc private func handleDoubleTap() {
        Task { @MainActor in onDoubleTap() }
    }

    // MARK: Scroll (two-finger trackpad scroll or mouse wheel)

    @objc private func handleScroll(_ gr: UIPanGestureRecognizer) {
        guard gr.state == .changed || gr.state == .began else { return }
        let vel = gr.velocity(in: self)
        // Fire one scroll tick per ~60 pt/s of velocity
        let stepsY = Int(vel.y / 60)
        let stepsX = Int(vel.x / 60)
        for _ in 0..<abs(stepsY) {
            let btn = stepsY > 0 ? 16 : 8   // down : up
            Task { @MainActor in
                self.client?.sendPointerEvent(x: self.lastPointerX, y: self.lastPointerY, buttonMask: btn)
                self.client?.sendPointerEvent(x: self.lastPointerX, y: self.lastPointerY, buttonMask: 0)
            }
        }
        for _ in 0..<abs(stepsX) {
            let btn = stepsX > 0 ? 32 : 64  // left : right
            Task { @MainActor in
                self.client?.sendPointerEvent(x: self.lastPointerX, y: self.lastPointerY, buttonMask: btn)
                self.client?.sendPointerEvent(x: self.lastPointerX, y: self.lastPointerY, buttonMask: 0)
            }
        }
    }

    // MARK: Indirect pointer events (trackpad / mouse via UIHoverGestureRecognizer)
    // UIPointerInteraction alone doesn't deliver movement; we use a hover recogniser.

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
    }

    // Called by FramebufferView after the view is set up
    func installHoverRecognizer() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        let loc = gr.location(in: self)
        sendPointer(at: loc, mask: 0)   // move without button
    }

    // MARK: Helpers

    private func viewToVNCCoords(_ loc: CGPoint) -> (Int, Int)? {
        guard let img = cgImage else { return nil }
        let imgW = CGFloat(img.width), imgH = CGFloat(img.height)
        guard imgW > 0, imgH > 0 else { return nil }
        let scale = min(bounds.width / imgW, bounds.height / imgH)
        let ox = (bounds.width  - imgW * scale) / 2
        let oy = (bounds.height - imgH * scale) / 2
        let nx = (loc.x - ox) / scale
        let ny = (loc.y - oy) / scale
        return (max(0, min(Int(nx), img.width - 1)),
                max(0, min(Int(ny), img.height - 1)))
    }

    private func sendPointer(at loc: CGPoint, mask: Int) {
        guard let (x, y) = viewToVNCCoords(loc), let client else { return }
        lastPointerX = x; lastPointerY = y
        Task { @MainActor in client.sendPointerEvent(x: x, y: y, buttonMask: mask) }
    }
}

// MARK: - FramebufferView wires hover recogniser after the view is ready

// (This extension is inside #else so it only exists on iOS)
private extension FramebufferView {
    func wireHover(_ uiView: VNCUIView) {
        uiView.installHoverRecognizer()
    }
}

// MARK: - UIKey → X11 keysym mapping (iOS hardware keyboard)

private func uiKeyToKeysym(_ key: UIKey) -> UInt32? {
    // Modifier flags → individual keysyms
    // (UIKey.charactersIgnoringModifiers gives the base character)

    // Special keys via keyCode
    switch key.keyCode {
    case .keyboardReturnOrEnter:    return 0xFF0D
    case .keyboardTab:              return 0xFF09
    case .keyboardSpacebar:         return 0x0020
    case .keyboardDeleteOrBackspace:return 0xFF08
    case .keyboardEscape:           return 0xFF1B
    case .keyboardDeleteForward:    return 0xFFFF
    case .keyboardLeftArrow:        return 0xFF51
    case .keyboardRightArrow:       return 0xFF53
    case .keyboardDownArrow:        return 0xFF54
    case .keyboardUpArrow:          return 0xFF52
    case .keyboardHome:             return 0xFF50
    case .keyboardEnd:              return 0xFF57
    case .keyboardPageUp:           return 0xFF55
    case .keyboardPageDown:         return 0xFF56
    case .keyboardF1:               return 0xFFBE
    case .keyboardF2:               return 0xFFBF
    case .keyboardF3:               return 0xFFC0
    case .keyboardF4:               return 0xFFC1
    case .keyboardF5:               return 0xFFC2
    case .keyboardF6:               return 0xFFC3
    case .keyboardF7:               return 0xFFC4
    case .keyboardF8:               return 0xFFC5
    case .keyboardF9:               return 0xFFC6
    case .keyboardF10:              return 0xFFC7
    case .keyboardF11:              return 0xFFC8
    case .keyboardF12:              return 0xFFC9
    case .keyboardCapsLock:         return 0xFFE5
    case .keyboardLeftShift:        return 0xFFE1
    case .keyboardRightShift:       return 0xFFE2
    case .keyboardLeftControl:      return 0xFFE3
    case .keyboardRightControl:     return 0xFFE4
    case .keyboardLeftAlt:          return 0xFFE9
    case .keyboardRightAlt:         return 0xFFEA
    case .keyboardLeftGUI:          return 0xFFEB  // Super/Win
    case .keyboardRightGUI:         return 0xFFEC
    default: break
    }

    // Printable characters: use the character value directly
    let chars = key.charactersIgnoringModifiers
    guard !chars.isEmpty, let scalar = chars.unicodeScalars.first?.value else { return nil }
    if scalar >= 0x20 && scalar <= 0xFF { return scalar }
    if scalar >= 0x100 { return 0x01000000 | scalar }
    return nil
}

#endif

// MARK: - X11 keysym mapping (macOS only — no hardware keyboard API on iOS)

#if os(macOS)
private func x11Keysym(for event: NSEvent) -> UInt32? {
    // Always try keyCode-based lookup first.
    // macOS function/special keys return private-use Unicode chars (0xF700+) in
    // charactersIgnoringModifiers which are non-empty, so checking characters first
    // would produce wrong Unicode keysyms (0x01000000 | 0xF7xx) for those keys.
    if let sym = specialKeysym(event.keyCode) { return sym }

    // Printable character fallback
    guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
    let scalar = chars.unicodeScalars.first!.value
    // Latin-1 passthrough (0x20..0xFF)
    if scalar >= 0x20 && scalar <= 0xFF { return scalar }
    // BMP characters above Latin-1, excluding macOS private-use range (0xF700–0xF8FF)
    if scalar >= 0x100 && scalar < 0xF700 { return 0x01000000 | scalar }
    return nil
}

private func specialKeysym(_ keyCode: UInt16) -> UInt32? {
    // macOS virtual key codes → X11 keysyms
    switch keyCode {
    // Control keys
    case 36:  return 0xFF0D // Return
    case 48:  return 0xFF09 // Tab
    case 49:  return 0x0020 // Space
    case 51:  return 0xFF08 // BackSpace
    case 53:  return 0xFF1B // Escape
    // Modifier keys
    case 55:  return 0xFFE3 // Left Cmd → Left Ctrl (KVM)
    case 56:  return 0xFFE1 // Left Shift
    case 57:  return 0xFFE5 // Caps Lock
    case 58:  return 0xFFE9 // Left Alt
    case 59:  return 0xFFE3 // Left Ctrl
    case 60:  return 0xFFE2 // Right Shift
    case 61:  return 0xFFEA // Right Alt
    case 62:  return 0xFFE4 // Right Ctrl
    case 63:  return 0xFFEB // Fn → Super
    // Navigation
    case 123: return 0xFF51 // Left arrow
    case 124: return 0xFF53 // Right arrow
    case 125: return 0xFF54 // Down arrow
    case 126: return 0xFF52 // Up arrow
    case 115: return 0xFF50 // Home
    case 116: return 0xFF55 // Page Up
    case 117: return 0xFFFF // Delete (forward)
    case 119: return 0xFF57 // End
    case 121: return 0xFF56 // Page Down
    // Keypad
    case 71:  return 0xFF7F // Clear / Num Lock
    case 76:  return 0xFF8D // Keypad Enter
    case 65:  return 0xFFAE // Keypad Decimal (.)
    case 67:  return 0xFFAA // Keypad *
    case 69:  return 0xFFAB // Keypad +
    case 75:  return 0xFFAF // Keypad /
    case 78:  return 0xFFAD // Keypad -
    case 81:  return 0xFFBD // Keypad =
    case 82:  return 0xFFB0 // Keypad 0
    case 83:  return 0xFFB1 // Keypad 1
    case 84:  return 0xFFB2 // Keypad 2
    case 85:  return 0xFFB3 // Keypad 3
    case 86:  return 0xFFB4 // Keypad 4
    case 87:  return 0xFFB5 // Keypad 5
    case 88:  return 0xFFB6 // Keypad 6
    case 89:  return 0xFFB7 // Keypad 7
    case 91:  return 0xFFB8 // Keypad 8
    case 92:  return 0xFFB9 // Keypad 9
    // Function keys F1–F12
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
    // Function keys F13–F20 (extended keyboard)
    case 105: return 0xFFCA // F13
    case 107: return 0xFFCB // F14
    case 113: return 0xFFCC // F15
    case 106: return 0xFFCD // F16
    case 64:  return 0xFFCE // F17
    case 79:  return 0xFFCF // F18
    case 80:  return 0xFFD0 // F19
    case 90:  return 0xFFD1 // F20
    default:  return nil
    }
}
#endif // os(macOS)

#Preview {
    VNCView()
}
