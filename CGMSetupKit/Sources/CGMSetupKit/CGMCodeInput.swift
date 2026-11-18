#if os(iOS)
import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import Vision
import VisionKit

/// Captures one unambiguous normalized code. Photos and payloads stay local.
@MainActor
public struct CGMCodeInput: View {
    private let normalize: (String) -> String?
    private let onCode: (String) -> Void
    @State private var cameraOpen = false
    @State private var photo: PhotosPickerItem?
    @State private var showsFailure = false

    public init(normalize: @escaping (String) -> String?, onCode: @escaping (String) -> Void) {
        self.normalize = normalize
        self.onCode = onCode
    }

    public var body: some View {
        Button {
            Task { @MainActor in
                guard DataScannerViewController.isSupported,
                      Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil,
                      await AVCaptureDevice.requestAccess(for: .video),
                      DataScannerViewController.isAvailable
                else {
                    showsFailure = true
                    return
                }
                cameraOpen = true
            }
        } label: {
            Label(String(localized: "Scan Package Code", bundle: .module), systemImage: "qrcode.viewfinder")
        }

        PhotosPicker(selection: $photo, matching: .images) {
            Label(String(localized: "Read Code From Photo", bundle: .module), systemImage: "photo")
        }
        .task(id: photo) {
            guard let selected = photo else { return }
            let data = try? await selected.loadTransferable(type: Data.self)
            let payloads = await Task.detached(priority: .userInitiated) {
                data.flatMap(Self.readPhoto) ?? []
            }.value
            guard !Task.isCancelled, photo == selected else { return }
            photo = nil
            if let code = uniqueCode(payloads) {
                onCode(code)
            } else {
                showsFailure = true
            }
        }
        .sheet(isPresented: $cameraOpen) {
            NavigationStack {
                PackageCamera(normalize: normalize) { code in
                    cameraOpen = false
                    if let code { onCode(code) } else { showsFailure = true }
                }
                .navigationTitle(Text("Tap the Package Code", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", bundle: .module)) { cameraOpen = false }
                    }
                }
            }
        }
        .alert(String(localized: "Could Not Read Package Code", bundle: .module), isPresented: $showsFailure) {
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: {
            Text("Show one supported code clearly, check camera access, or enter the code by hand.", bundle: .module)
        }
    }

    private func uniqueCode(_ payloads: [String]) -> String? {
        let codes = Set(payloads.compactMap(normalize))
        return codes.count == 1 ? codes.first : nil
    }

    private nonisolated static func readPhoto(_ data: Data) -> [String]? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .dataMatrix]
        do {
            try VNImageRequestHandler(data: data).perform([request])
            return request.results?.compactMap(\.payloadStringValue)
        } catch {
            return nil
        }
    }
}

@MainActor
private struct PackageCamera: UIViewControllerRepresentable {
    let normalize: (String) -> String?
    let finish: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(normalize: normalize, finish: finish) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr, .dataMatrix])],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.finished else { return }
        do {
            try scanner.startScanning()
        } catch {
            let coordinator = context.coordinator
            Task { @MainActor in coordinator.complete(nil) }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        scanner.stopScanning()
        scanner.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let normalize: (String) -> String?
        private let finish: (String?) -> Void
        var finished = false

        init(normalize: @escaping (String) -> String?, finish: @escaping (String?) -> Void) {
            self.normalize = normalize
            self.finish = finish
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            guard case let .barcode(barcode) = item, let payload = barcode.payloadStringValue else { return }
            complete(normalize(payload))
            scanner.stopScanning()
        }

        func dataScanner(_: DataScannerViewController, becameUnavailableWithError _: DataScannerViewController.ScanningUnavailable) {
            complete(nil)
        }

        func complete(_ code: String?) {
            guard !finished else { return }
            finished = true
            finish(code)
        }
    }
}
#endif
