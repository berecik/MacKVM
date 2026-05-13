import Testing
import Foundation
import Network
import CoreGraphics
@testable import MacKVM

// ============================================================================
// MARK: - Mock RFB 3.8 Server
// ============================================================================
//
// Listens on 127.0.0.1 on an OS-assigned port, speaks the full RFB 3.8
// handshake (VNC auth type 2 with DES verification), sends a ServerInit
// of configurable size, then streams raw BGRA FramebufferUpdate messages
// whenever the client requests one.
//
// Usage:
//   let srv = MockVNCServer(password: "secret", width: 320, height: 240)
//   try srv.start()
//   defer { srv.stop() }
//   // connect to "127.0.0.1" : srv.port
//
// ============================================================================

final class MockVNCServer {
    let password: String
    let width: Int
    let height: Int

    // Set to false to simulate a bad-password rejection
    var acceptAuth: Bool = true

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "MockVNCServer")

    init(password: String = "test", width: Int = 320, height: Int = 240) {
        self.password = password
        self.width = width
        self.height = height
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener

        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { started.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        started.wait()
        self.port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    // -------------------------------------------------------------------------
    // Accept + serve one connection
    // -------------------------------------------------------------------------

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        serveVersion(conn)
    }

    // Step 1: send server version
    private func serveVersion(_ conn: NWConnection) {
        let ver = Data("RFB 003.008\n".utf8)
        conn.send(content: ver, completion: .contentProcessed { [weak self] _ in
            self?.readClientVersion(conn)
        })
    }

    // Step 2: read client version (12 bytes)
    private func readClientVersion(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 12, maximumLength: 12) { [weak self] data, _, _, _ in
            guard data != nil else { conn.cancel(); return }
            self?.sendSecurityTypes(conn)
        }
    }

    // Step 3: send security types (just type 2 = VNC auth)
    private func sendSecurityTypes(_ conn: NWConnection) {
        let msg = Data([1, 2]) // 1 type, type=2
        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
            self?.readSecurityChoice(conn)
        })
    }

    // Step 4: read client security choice (1 byte)
    private func readSecurityChoice(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, _ in
            guard let data, data.first == 2 else { conn.cancel(); return }
            self?.sendChallenge(conn)
        }
    }

    // Step 5: send 16-byte challenge
    private func sendChallenge(_ conn: NWConnection) {
        // Use a fixed all-zero challenge for test predictability
        let challenge = Data(repeating: 0, count: 16)
        conn.send(content: challenge, completion: .contentProcessed { [weak self] _ in
            self?.readResponse(conn, challenge: challenge)
        })
    }

    // Step 6: read 16-byte DES response
    private func readResponse(_ conn: NWConnection, challenge: Data) {
        conn.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            // Verify response if acceptAuth is true
            let ok = !self.acceptAuth ? false : self.verifyAuth(challenge: challenge, response: data)
            self.sendSecurityResult(conn, ok: ok)
        }
    }

    // DES verification: encrypt challenge with bit-reversed password bytes
    private func verifyAuth(challenge: Data, response: Data) -> Bool {
        // Build expected response using same bit-reversal as the client
        var pw = [UInt8](repeating: 0, count: 8)
        let bytes = [UInt8](password.utf8)
        let len = min(bytes.count, 8)
        for i in 0..<len {
            var b = bytes[i]
            b = ((b & 0xF0) >> 4) | ((b & 0x0F) << 4)
            b = ((b & 0xCC) >> 2) | ((b & 0x33) << 2)
            b = ((b & 0xAA) >> 1) | ((b & 0x55) << 1)
            pw[i] = b
        }
        var expected = [UInt8](repeating: 0, count: 16)
        var bytesOut = 0
        let challengeBytes = [UInt8](challenge)
        CCCrypt(CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmDES),
                CCOptions(kCCOptionECBMode),
                pw, kCCKeySizeDES,
                nil,
                challengeBytes, 16,
                &expected, 16,
                &bytesOut)
        return Data(expected) == response
    }

    // Step 7: send SecurityResult (0=OK, 1=fail)
    private func sendSecurityResult(_ conn: NWConnection, ok: Bool) {
        var result = UInt32(ok ? 0 : 1).bigEndian
        let data = Data(bytes: &result, count: 4)
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            if ok {
                self?.readClientInit(conn)
            } else {
                // Send reason string length + "Authentication failed"
                let reason = Data("Authentication failed".utf8)
                var len = UInt32(reason.count).bigEndian
                var msg = Data(bytes: &len, count: 4)
                msg.append(reason)
                conn.send(content: msg, completion: .contentProcessed { _ in conn.cancel() })
            }
        })
    }

    // Step 8: read ClientInit (1 byte)
    private func readClientInit(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            self?.sendServerInit(conn)
        }
    }

    // Step 9: send ServerInit
    private func sendServerInit(_ conn: NWConnection) {
        var msg = Data()
        // width, height
        var w = UInt16(width).bigEndian
        var h = UInt16(height).bigEndian
        msg.append(Data(bytes: &w, count: 2))
        msg.append(Data(bytes: &h, count: 2))
        // PixelFormat (16 bytes): 32bpp, depth 24, little-endian, true-colour
        // matches what the client requests
        let pf: [UInt8] = [
            32, 24, 0, 1,       // bpp, depth, big-endian=0, true-colour=1
            0, 255, 0, 255, 0, 255, // r-max, g-max, b-max (big-endian 16-bit)
            16, 8, 0,           // r-shift, g-shift, b-shift
            0, 0, 0             // padding
        ]
        msg.append(contentsOf: pf)
        // name
        let name = Data("MockVNC".utf8)
        var nameLen = UInt32(name.count).bigEndian
        msg.append(Data(bytes: &nameLen, count: 4))
        msg.append(name)

        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
            self?.readClientMessages(conn)
        })
    }

    // Step 10: read client messages and respond
    private func readClientMessages(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            switch data[0] {
            case 0: // SetPixelFormat (20 bytes total, we already read 1)
                conn.receive(minimumIncompleteLength: 19, maximumLength: 19) { [weak self] _, _, _, _ in
                    self?.readClientMessages(conn)
                }
            case 2: // SetEncodings: 1 pad + 2 count + N*4
                conn.receive(minimumIncompleteLength: 3, maximumLength: 3) { [weak self] data, _, _, _ in
                    guard let data else { return }
                    let count = Int(UInt16(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: 1, as: UInt16.self) }))
                    let toSkip = count * 4
                    if toSkip > 0 {
                        conn.receive(minimumIncompleteLength: toSkip, maximumLength: toSkip) { [weak self] _, _, _, _ in
                            self?.readClientMessages(conn)
                        }
                    } else {
                        self?.readClientMessages(conn)
                    }
                }
            case 3: // FramebufferUpdateRequest (9 more bytes)
                conn.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] _, _, _, _ in
                    self?.sendFramebufferUpdate(conn)
                }
            case 4: // KeyEvent (7 more bytes)
                conn.receive(minimumIncompleteLength: 7, maximumLength: 7) { [weak self] _, _, _, _ in
                    self?.readClientMessages(conn)
                }
            case 5: // PointerEvent (5 more bytes)
                conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] _, _, _, _ in
                    self?.readClientMessages(conn)
                }
            default:
                conn.cancel()
            }
        }
    }

    // Send one FramebufferUpdate with a single Raw rectangle of unique colour
    private var frameCounter: UInt8 = 0
    private func sendFramebufferUpdate(_ conn: NWConnection) {
        frameCounter = frameCounter &+ 1
        let colour = frameCounter  // distinct frame value
        let pixelCount = width * height
        let pixels = Data(repeating: colour, count: pixelCount * 4) // BGRA

        var msg = Data()
        msg.append(0)   // message type: FramebufferUpdate
        msg.append(0)   // padding
        var nrects: UInt16 = UInt16(1).bigEndian
        msg.append(Data(bytes: &nrects, count: 2))

        // Rectangle header
        var rx: UInt16 = 0
        var ry: UInt16 = 0
        var rw = UInt16(width).bigEndian
        var rh = UInt16(height).bigEndian
        var enc: Int32 = Int32(0).bigEndian // Raw
        msg.append(Data(bytes: &rx, count: 2))
        msg.append(Data(bytes: &ry, count: 2))
        msg.append(Data(bytes: &rw, count: 2))
        msg.append(Data(bytes: &rh, count: 2))
        msg.append(Data(bytes: &enc, count: 4))
        msg.append(pixels)

        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
            self?.readClientMessages(conn)
        })
    }
}

// Needed for DES in MockVNCServer
import CommonCrypto

// ============================================================================
// MARK: - C Layer Tests (lifecycle — no network)
// ============================================================================

@Suite("C Layer — VNCClientHandle lifecycle")
struct CLayerLifecycleTests {

    @Test("vncclient_create returns non-nil handle")
    func testCreate() {
        let h = vncclient_create()
        #expect(h != nil)
        vncclient_disconnect(h)
    }

    @Test("vncclient_create/disconnect can be called multiple times independently")
    func testCreateMultiple() {
        let h1 = vncclient_create()
        let h2 = vncclient_create()
        #expect(h1 != nil)
        #expect(h2 != nil)
        #expect(h1 != h2)
        vncclient_disconnect(h1)
        vncclient_disconnect(h2)
    }

    @Test("vncclient_disconnect with nil is safe (no crash)")
    func testDisconnectNil() {
        vncclient_disconnect(nil)
    }

    @Test("vncclient_set_password accepts valid password")
    func testSetPassword() {
        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        vncclient_set_password(h, "password")
    }

    @Test("vncclient_set_password accepts password longer than 8 chars")
    func testSetLongPassword() {
        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        vncclient_set_password(h, "this-is-definitely-longer-than-eight-characters")
    }

    @Test("framebuffer dimensions are zero before connect")
    func testDimensionsBeforeConnect() {
        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        #expect(vncclient_framebuffer_width(h)  == 0)
        #expect(vncclient_framebuffer_height(h) == 0)
    }

    @Test("vncclient_last_error returns a valid C string before connect")
    func testLastErrorBeforeConnect() {
        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        // _Nonnull guarantees a valid pointer; converting to String should not crash
        let _ = String(cString: vncclient_last_error(h))
    }

}

// ============================================================================
// MARK: - C Layer Tests (RFB handshake via mock server)
// ============================================================================

@Suite("C Layer — RFB 3.8 Handshake")
struct CLayerHandshakeTests {

    private func makeServer(password: String = "test",
                            width: Int = 320, height: Int = 240) throws -> MockVNCServer {
        let srv = MockVNCServer(password: password, width: width, height: height)
        try srv.start()
        return srv
    }

    @Test("successful connect returns 0 and populates framebuffer dimensions")
    func testSuccessfulConnect() throws {
        let srv = try makeServer(width: 800, height: 600)
        defer { srv.stop() }

        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        vncclient_set_password(h, "test")

        let result = vncclient_connect(h, "127.0.0.1", Int32(srv.port))
        #expect(result == 0, "connect failed: \(String(cString: vncclient_last_error(h)))")
        #expect(vncclient_framebuffer_width(h)  == 800)
        #expect(vncclient_framebuffer_height(h) == 600)
    }

    @Test("connect with wrong password returns nonzero")
    func testWrongPassword() throws {
        let srv = try makeServer(password: "correct")
        defer { srv.stop() }

        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        vncclient_set_password(h, "wrong")

        let result = vncclient_connect(h, "127.0.0.1", Int32(srv.port))
        #expect(result != 0)
        let err = String(cString: vncclient_last_error(h))
        #expect(err.lowercased().contains("auth") || err.lowercased().contains("fail"),
                "expected auth error, got: \(err)")
    }

    @Test("framebuffer dimensions match ServerInit")
    func testExpectedResolution() throws {
        let srv = try makeServer(width: 1920, height: 1080)
        defer { srv.stop() }

        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        vncclient_set_password(h, "test")
        guard vncclient_connect(h, "127.0.0.1", Int32(srv.port)) == 0 else { return }

        #expect(vncclient_framebuffer_width(h)  == 1920)
        #expect(vncclient_framebuffer_height(h) == 1080)
    }

    @Test("framebuffer callback is invoked after connect")
    func testFramebufferCallback() async throws {
        let srv = try makeServer(width: 320, height: 240)
        defer { srv.stop() }

        let h = vncclient_create()!
        defer { vncclient_disconnect(h) }
        vncclient_set_password(h, "test")

        actor Capture {
            var width: Int = 0
            var height: Int = 0
            var called = false
            func record(w: Int, h: Int) { width = w; height = h; called = true }
        }
        let capture = Capture()
        let capturePtr = Unmanaged.passRetained(capture).toOpaque()
        defer { Unmanaged<Capture>.fromOpaque(capturePtr).release() }

        vncclient_set_framebuffer_callback(h, { _, w, ht, ud in
            guard let ud else { return }
            let cap = Unmanaged<Capture>.fromOpaque(ud).takeUnretainedValue()
            Task { await cap.record(w: Int(w), h: Int(ht)) }
        }, capturePtr)

        guard vncclient_connect(h, "127.0.0.1", Int32(srv.port)) == 0 else {
            Issue.record("connect failed: \(String(cString: vncclient_last_error(h)))")
            return
        }

        let deadline = Date().addingTimeInterval(3)
        while await !capture.called && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(await capture.called, "framebuffer callback should fire within 3 s")
        if await capture.called {
            #expect(await capture.width  == 320)
            #expect(await capture.height == 240)
        }
    }
}

// ============================================================================
// MARK: - C Layer Tests (Input Events via mock server)
// ============================================================================

@Suite("C Layer — Input Events")
struct CLayerInputTests {

    private func connectedHandle() throws -> (OpaquePointer, MockVNCServer)? {
        let srv = MockVNCServer(password: "test")
        try srv.start()
        let h = vncclient_create()!
        vncclient_set_password(h, "test")
        guard vncclient_connect(h, "127.0.0.1", Int32(srv.port)) == 0 else {
            vncclient_disconnect(h)
            srv.stop()
            return nil
        }
        return (h, srv)
    }

    @Test("send_key_event does not crash when connected")
    func testKeyEventConnected() throws {
        guard let (h, srv) = try connectedHandle() else { return }
        defer { vncclient_disconnect(h); srv.stop() }
        vncclient_send_key_event(h, 0xFFE1, 1)
        vncclient_send_key_event(h, 0xFFE1, 0)
    }

    @Test("send_pointer_event does not crash when connected")
    func testPointerEventConnected() throws {
        guard let (h, srv) = try connectedHandle() else { return }
        defer { vncclient_disconnect(h); srv.stop() }
        vncclient_send_pointer_event(h, 160, 120, 0)
    }

    @Test("scroll wheel button masks are sent without crash")
    func testScrollMasks() throws {
        guard let (h, srv) = try connectedHandle() else { return }
        defer { vncclient_disconnect(h); srv.stop() }
        for mask: Int32 in [8, 0, 16, 0, 32, 0, 64, 0] {
            vncclient_send_pointer_event(h, 160, 120, mask)
        }
    }
}

// ============================================================================
// MARK: - Swift VNCClient Tests (state management via mock server)
// ============================================================================

@Suite("Swift VNCClient — state management")
struct SwiftClientStateTests {

    @Test("isConnected starts false, errorMessage starts nil, image starts nil")
    func testInitialState() async {
        let client = await VNCClient()
        let connected = await client.isConnected
        let err      = await client.errorMessage
        let img      = await client.image
        #expect(!connected)
        #expect(err == nil)
        #expect(img == nil)
    }

    @Test("connect to non-listening port sets errorMessage")
    func testConnectUnreachable() async {
        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: 1, password: "test")
        let err = await client.errorMessage
        #expect(err != nil)
    }

    @Test("connect with wrong password sets errorMessage, isConnected stays false")
    func testConnectWrongPassword() async throws {
        let srv = MockVNCServer(password: "correct")
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "wrong")
        let connected = await client.isConnected
        let err       = await client.errorMessage
        #expect(!connected)
        #expect(err != nil)
    }

    @Test("connect succeeds: isConnected becomes true")
    func testConnectSuccess() async throws {
        let srv = MockVNCServer(password: "test")
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        let connected = await client.isConnected
        let err       = await client.errorMessage
        #expect(connected, "should be connected; error: \(err ?? "none")")
        await client.disconnect()
    }

    @Test("disconnect resets isConnected and image to nil")
    func testDisconnect() async throws {
        let srv = MockVNCServer(password: "test")
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        await client.disconnect()
        let connected = await client.isConnected
        let img       = await client.image
        #expect(!connected)
        #expect(img == nil)
    }

    @Test("second connect while already connected is a no-op")
    func testDoubleConnect() async throws {
        let srv = MockVNCServer(password: "test")
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        let connected = await client.isConnected
        #expect(connected)
        await client.disconnect()
    }

    @Test("disconnect when not connected is safe")
    func testDisconnectWhenNotConnected() async {
        let client = await VNCClient()
        await client.disconnect()
        let connected = await client.isConnected
        #expect(!connected)
    }
}

// ============================================================================
// MARK: - Swift VNCClient — Framebuffer / Screen Tests
// ============================================================================

@Suite("Swift VNCClient — screen / framebuffer")
struct SwiftClientScreenTests {

    @MainActor
    private func waitForImage(client: VNCClient, timeout: TimeInterval) async throws -> CGImage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let img = client.image { return img }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return client.image
    }

    @Test("receives a CGImage after connecting")
    func testReceivesImage() async throws {
        let srv = MockVNCServer(password: "test", width: 320, height: 240)
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        guard await client.isConnected else {
            Issue.record("not connected: \(await client.errorMessage ?? "?")")
            return
        }

        let image = try await waitForImage(client: client, timeout: 3)
        await client.disconnect()
        #expect(image != nil, "should receive a CGImage within 3 s")
    }

    @Test("received CGImage matches ServerInit dimensions")
    func testImageDimensions() async throws {
        let srv = MockVNCServer(password: "test", width: 640, height: 480)
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        guard await client.isConnected else { return }

        let img = try await waitForImage(client: client, timeout: 3)
        await client.disconnect()
        guard let img else {
            Issue.record("no image received")
            return
        }
        #expect(img.width  == 640)
        #expect(img.height == 480)
    }

    @Test("received CGImage has correct pixel format (32bpp, 8 bitsPerComponent)")
    func testImagePixelFormat() async throws {
        let srv = MockVNCServer(password: "test", width: 160, height: 120)
        try srv.start()
        defer { srv.stop() }

        let client = await VNCClient()
        await client.connect(host: "127.0.0.1", port: Int(srv.port), password: "test")
        guard await client.isConnected else { return }

        let img = try await waitForImage(client: client, timeout: 3)
        await client.disconnect()
        guard let img else { return }
        #expect(img.bitsPerPixel     == 32)
        #expect(img.bitsPerComponent == 8)
        #expect(img.bytesPerRow      == 160 * 4)
    }

}
