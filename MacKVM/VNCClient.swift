import Foundation
import SwiftUI
import Combine

/// Wraps the native RFB 3.8 C client and exposes an async Swift interface.
@MainActor
final class VNCClient: ObservableObject {

    @Published var image: CGImage?
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    /// Latest text received from the remote via ServerCutText (RFB clipboard).
    @Published var remoteClipboard: String = ""

    private var handle: OpaquePointer? // VNCClientHandle *

    // MARK: - Connect

    /// Connects to a VNC server and starts receiving framebuffer updates.
    func connect(host: String, port: Int, password: String) async {
        errorMessage = nil

        guard handle == nil else { return }

        let h = vncclient_create()
        guard let h else {
            errorMessage = "Failed to allocate VNC client"
            return
        }
        handle = h

        vncclient_set_password(h, password)

        // Framebuffer callback — called on the C receive thread.
        vncclient_set_framebuffer_callback(h, { pixelsPtr, width, height, ctx in
            guard
                let pixelsPtr,
                let ctx,
                width > 0, height > 0
            else { return }

            let bytesPerRow = Int(width) * 4
            let totalBytes = bytesPerRow * Int(height)
            let data = Data(bytes: pixelsPtr, count: totalBytes)

            // Marshal to main thread for UI update.
            Task { @MainActor in
                VNCClient.updateImage(context: ctx, data: data,
                                      width: Int(width), height: Int(height))
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Error callback — called on the C receive thread.
        vncclient_set_error_callback(h, { messagePtr, ctx in
            let msg = messagePtr.map { String(cString: $0) } ?? "Unknown error"
            guard let ctx else { return }
            Task { @MainActor in
                VNCClient.handleError(context: ctx, message: msg)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // ServerCutText callback — remote clipboard text arriving from the server.
        vncclient_set_cut_text_callback(h, { textPtr, _, ctx in
            guard let textPtr, let ctx else { return }
            let text = String(cString: textPtr)
            Task { @MainActor in
                VNCClient.handleCutText(context: ctx, text: text)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Connect (performs blocking handshake on calling thread — wrap in task).
        let result = await Task.detached(priority: .userInitiated) {
            vncclient_connect(h, host, Int32(port))
        }.value

        if result != 0 {
            let err = String(cString: vncclient_last_error(h))
            errorMessage = err.isEmpty ? "Connection failed" : err
            vncclient_disconnect(h)
            handle = nil
            return
        }

        isConnected = true
    }

    // MARK: - Disconnect

    func disconnect() {
        if let h = handle {
            vncclient_disconnect(h)
            handle = nil
        }
        isConnected = false
        image = nil
    }

    // MARK: - Input forwarding

    func sendKeyEvent(keysym: UInt32, down: Bool) {
        guard let h = handle else { return }
        vncclient_send_key_event(h, keysym, down ? 1 : 0)
    }

    func sendPointerEvent(x: Int, y: Int, buttonMask: Int) {
        guard let h = handle else { return }
        vncclient_send_pointer_event(h, Int32(x), Int32(y), Int32(buttonMask))
    }

    // MARK: - Static helpers (called from C callbacks via Unmanaged)

    private static func updateImage(context: UnsafeMutableRawPointer,
                                    data: Data, width: Int, height: Int) {
        let client = Unmanaged<VNCClient>.fromOpaque(context).takeUnretainedValue()
        guard let cgImage = makeCGImage(data: data, width: width, height: height) else { return }
        client.image = cgImage
    }

    private static func handleError(context: UnsafeMutableRawPointer, message: String) {
        let client = Unmanaged<VNCClient>.fromOpaque(context).takeUnretainedValue()
        client.errorMessage = message
        client.isConnected = false
        // Don't call vncclient_disconnect here — C side already closed the socket.
        client.handle = nil
    }

    private static func handleCutText(context: UnsafeMutableRawPointer, text: String) {
        let client = Unmanaged<VNCClient>.fromOpaque(context).takeUnretainedValue()
        client.remoteClipboard = text
    }

    // MARK: - CGImage construction from BGRA data

    private static func makeCGImage(data: Data, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // bitmapInfo: BGRA → kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    deinit {
        // Must call from a non-isolated context; handle is C memory.
        if let h = handle {
            vncclient_disconnect(h)
        }
    }
}
