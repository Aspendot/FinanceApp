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

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.github.aspendot.financeapp.qrscanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var lastRejectedValue: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkPermissionAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isConfigured else { return }
        let captureSession = session
        sessionQueue.async {
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.onError?("Camera access is off. Allow Camera in Settings or paste the key instead.")
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
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        isConfigured = true

        let captureSession = session
        sessionQueue.async {
            captureSession.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              readable.type == .qr,
              let value = readable.stringValue,
              !value.isEmpty
        else { return }

        if (try? DriveSyncKey(pairingString: value)) != nil {
            let captureSession = session
            sessionQueue.async {
                captureSession.stopRunning()
            }
            onCode?(value)
        } else if lastRejectedValue != value {
            lastRejectedValue = value
            onCode?(value)
        }
    }
}
