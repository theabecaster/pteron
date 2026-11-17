import AVFoundation
import SwiftUI
import UIKit

/// Whether the scanner may use the camera. Asked for only when the scanner opens.
enum CameraAccess: Equatable {
    case asking, granted, denied
    /// No camera at all (a simulator).
    case unavailable

    static func resolve() async -> CameraAccess {
        #if DEBUG
        // `-simulateCamera denied` and `-simulateScan` (testing): the simulator has no camera.
        if UserDefaults.standard.string(forKey: "simulateCamera") == "denied" { return .denied }
        if UserDefaults.standard.string(forKey: "simulateScan") != nil { return .granted }
        #endif
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: return .denied
        }
    }

    static var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch == true }
}

/// The camera's picture, reporting each QR code it reads. The same code in view is reported once
/// until another code, or nothing, has been in view.
struct QRCameraView: UIViewRepresentable {
    var torch: Bool
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> QRCameraUIView { QRCameraUIView() }

    func updateUIView(_ view: QRCameraUIView, context: Context) {
        view.onCode = onCode
        view.setTorch(torch)
    }

    static func dismantleUIView(_ view: QRCameraUIView, coordinator: ()) { view.stop() }
}

final class QRCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    /// The capture session, handed to the camera queue. `@unchecked Sendable` because
    /// AVCaptureSession may be configured, started and stopped from any one thread at a time, and
    /// only `queue` touches it after `init`.
    private struct Camera: @unchecked Sendable {
        let session = AVCaptureSession()
    }

    private let camera = Camera()
    /// Starting a session blocks for a few hundred milliseconds, so it stays off the main thread.
    private let queue = DispatchQueue(label: "dev.abrahamgonzalez.rexduo.qr-camera")
    private let device = AVCaptureDevice.default(for: .video)
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var lastCode: String?
    private var lastSeen = Date.distantPast
    private var torchOn = false

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var preview: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` makes the backing layer this type.
        layer as! AVCaptureVideoPreviewLayer
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        preview.videoGravity = .resizeAspectFill
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = camera.session
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Keep the camera while the app shares the screen (half of the unfolded Duo).
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        session.commitConfiguration()
        preview.session = session
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        queue.async { [camera] in camera.session.startRunning() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func stop() {
        setTorch(false)
        queue.async { [camera] in camera.session.stopRunning() }
    }

    func setTorch(_ on: Bool) {
        guard on != torchOn, let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        torchOn = on
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A layout pass follows every rotation and fold, which is when the angle changes.
        if let angle = rotation?.videoRotationAngleForHorizonLevelPreview, let c = preview.connection,
           c.isVideoRotationAngleSupported(angle) {
            c.videoRotationAngle = angle
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let code = objects.lazy.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        // The delegate queue is the main queue (set in `init`).
        MainActor.assumeIsolated { saw(code) }
    }

    private func saw(_ code: String?) {
        guard let code else { return }
        let now = Date()
        // Frames with no code aren't delivered, so "left the view" is a gap between reads.
        defer { lastSeen = now }
        if code == lastCode, now.timeIntervalSince(lastSeen) < 1.5 { return }
        lastCode = code
        onCode?(code)
    }
}
