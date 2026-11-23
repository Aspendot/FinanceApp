import AVFoundation
import FinanceSync
import SwiftUI
import UIKit

/// Sheet presenting a live camera QR scanner for `"finance-key:v1:..."` pairing strings.
struct KeyPairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (DriveSyncKey) -> Void

    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRScannerRepresentable(
                    onCode: { payload in
                        do {
                            let key = try DriveSyncKey(pairingString: payload)
                            onScanned(key)
                        } catch {
                            statusMessage = "Not a Finance sync key QR code."
                        }
                    },
                    onError: { message in
                        statusMessage = message
                    }
                )
                .ignoresSafeArea()

                VStack(spacing: 6) {
                    Text(statusMessage ?? "Point the camera at the pairing QR code on your PC.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.bottom, 28)
                .padding(.horizontal, 20)
            }
            .navigationTitle("Scan pairing key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.onCode = onCode
        uiViewController.onError = onError
    }
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let capture = ScannerCapture()
    private var session: AVCaptureSession { capture.session }
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var isVisible = false
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
           let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        if isConfigured {
            if !didScan { capture.setRunning(true) }
        } else {
            checkPermissionAndStart()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if isConfigured { capture.setRunning(false) }
    }

    private func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.isVisible else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onError?("Camera access is off. Allow Camera in Settings or paste the key instead.")
                    }
                }
            }
        default:
            onError?("Camera access is off. Allow Camera in Settings or paste the key instead.")
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onError?("Camera is not available on this device. Paste the key instead.")
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("Could not start QR scanning. Paste the key instead.")
            return
        }

        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            session.commitConfiguration()
            onError?("QR scanning is unavailable. Paste the key instead.")
            return
        }
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        view.setNeedsLayout()
        isConfigured = true
        capture.setRunning(true)
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              readable.type == .qr, let value = readable.stringValue else { return }
        // AVCaptureMetadataOutput delivers on the main queue selected above.
        MainActor.assumeIsolated { receive(value) }
    }

    private func receive(_ value: String) {
        guard isVisible, !didScan else { return }
        guard (try? DriveSyncKey(pairingString: value)) != nil else {
            onError?("Not a Finance sync key QR code.")
            return
        }
        didScan = true
        capture.setRunning(false)
        onCode?(value)
    }
}

// The controller configures the session once before starting it. After that,
// all start and stop calls run on this queue in appearance order.
private final class ScannerCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.github.aspendot.financeapp.qrscanner")

    func setRunning(_ running: Bool) {
        queue.async { [self] in
            guard session.isRunning != running else { return }
            if running { session.startRunning() } else { session.stopRunning() }
        }
    }
}
