import AVFoundation
import SwiftUI
import UIKit

/// Whether the scanner may use the camera. Asked for only when the scanner opens.
enum CameraAccess: Equatable {
    case asking, granted
    /// The person said no; iOS Settings can change it.
    case denied
    /// A restriction (Screen Time, a managed device) forbids it; the person can't change that here.
    case restricted
    /// No camera (a simulator), or the camera failed to start.
    case unavailable

    @MainActor
    static func resolve() async -> CameraAccess {
        #if DEBUG
        // `-simulateCamera denied|restricted|unavailable` and `-simulateScan` (testing): the
        // simulator has no camera.
        switch UserDefaults.standard.string(forKey: "simulateCamera") {
        case "denied": return .denied
        case "restricted": return .restricted
        case "unavailable": return .unavailable
        default: break
        }
        if UserDefaults.standard.string(forKey: "simulateScan") != nil { return .granted }
        #endif
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        return await of(AVCaptureDevice.authorizationStatus(for: .video)) {
            await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    /// The access a status means, asking only when the person hasn't decided yet.
    @MainActor
    static func of(_ status: AVAuthorizationStatus, ask: @MainActor () async -> Bool) async -> CameraAccess {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return await ask() ? .granted : .denied
        case .restricted: return .restricted
        default: return .denied
        }
    }

    static var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch == true }
}

/// The camera's picture. It reports a QR code on every frame the code is in view (the pairing
/// model decides what is new), follows the torch both ways, and says when the camera can't run.
struct QRCameraView: UIViewRepresentable {
    @Binding var torch: Bool
    var onCode: (String) -> Void
    var onFailure: () -> Void

    func makeUIView(context: Context) -> QRCameraUIView { QRCameraUIView() }

    func updateUIView(_ view: QRCameraUIView, context: Context) {
        view.onCode = onCode
        view.onFailure = onFailure
        view.onTorch = { [binding = $torch] on in if binding.wrappedValue != on { binding.wrappedValue = on } }
        view.setTorch(torch)
    }

    static func dismantleUIView(_ view: QRCameraUIView, coordinator: ()) { view.stop() }
}

/// Reads the metadata output's codes on the main queue and hands them on.
@MainActor
private final class CodeReader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let code = objects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first
        else { return }
        // The delegate queue is the main queue (`CaptureBox.configure`).
        MainActor.assumeIsolated { onCode?(code) }
    }
}

/// The capture session and the one queue that configures, starts and stops it: those calls block
/// for tens to hundreds of milliseconds, so none runs on the main thread. `@unchecked Sendable`
/// because AVCaptureSession allows calls from any one thread at a time, and after `init` only
/// `queue` makes them (the preview layer attaches on main, which AVFoundation supports).
private final class CaptureBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "dev.abrahamgonzalez.rexduo.qr-camera")

    /// On `queue`. False when the camera can't be used for QR codes.
    func configure(reader: CodeReader) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(reader, queue: .main)
        // Keep the camera while the app shares the screen (half of the unfolded Duo).
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        return true
    }

    func start() { queue.async { [self] in if !session.isRunning { session.startRunning() } } }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}

final class QRCameraUIView: UIView {
    var onCode: ((String) -> Void)? { didSet { reader.onCode = onCode } }
    var onFailure: (() -> Void)?
    /// The torch changed, here or elsewhere (Control Center, the system turning it off).
    var onTorch: ((Bool) -> Void)?

    private let box = CaptureBox()
    private let reader = CodeReader()
    private var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var stopped = false
    private var wantsTorch = false

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var preview: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` makes the backing layer this type.
        layer as! AVCaptureVideoPreviewLayer
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        preview.videoGravity = .resizeAspectFill
        box.queue.async { [box, reader, weak self] in
            let ok = box.configure(reader: reader)
            DispatchQueue.main.async { self?.configured(ok) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// On main, once the session is set up: attach the picture, watch the device, start.
    private func configured(_ ok: Bool) {
        guard !stopped else { return }
        guard ok, let device = AVCaptureDevice.default(for: .video) else {
            #if DEBUG
            // `-simulateScan` (testing): no camera, a black picture.
            if UserDefaults.standard.string(forKey: "simulateScan") != nil { return }
            #endif
            onFailure?()
            return
        }
        self.device = device
        preview.session = box.session
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotation = coordinator
        // The angle also changes with no layout pass (a 180° turn), so it is observed.
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRotation() }
        })
        observations.append(device.observe(\.torchMode, options: [.new]) { [weak self] device, _ in
            let on = device.torchMode == .on
            DispatchQueue.main.async { self?.onTorch?(on) }
        })
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: box.session,
                                                queue: .main) { [weak self] note in
            let reset = (note.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code == .mediaServicesWereReset
            MainActor.assumeIsolated { self?.runtimeError(recoverable: reset) }
        })
        // Another app took the camera, or this one left the foreground: start again once it's back.
        notifications.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: box.session,
                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        box.start()
        setTorch(wantsTorch)
    }

    private func runtimeError(recoverable: Bool) {
        guard !stopped else { return }
        if recoverable { box.start() } else { onFailure?() }
    }

    private func resume() {
        guard !stopped else { return }
        box.start()
    }

    func stop() {
        stopped = true
        setTorch(false)
        observations.forEach { $0.invalidate() }
        observations = []
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []
        box.stop()
    }

    func setTorch(_ on: Bool) {
        wantsTorch = on
        guard let device, device.hasTorch, (device.torchMode == .on) != on,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    private func applyRotation() {
        guard let angle = rotation?.videoRotationAngleForHorizonLevelPreview, let c = preview.connection,
              c.isVideoRotationAngleSupported(angle) else { return }
        c.videoRotationAngle = angle
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }
}
