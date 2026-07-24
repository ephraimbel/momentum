import SwiftUI
import AVFoundation

/// The barcode lane of meal logging (FUEL-FLOW): point at a wrapper, read the LABEL. Deliberately
/// not photo-calorie guessing — a barcode resolves to printed label data (Open Food Facts), which
/// is the one estimate-free path in the whole pipeline. Monochrome chrome over the live camera;
/// no iridescence (scanning is utility, not progress).
///
/// Phases: scanning → looking (network) → found (confirm card with a servings stepper) or an
/// honest miss ("describe it instead" — the composer is the fallback, never a guess).
/// Sim/demo: `--barcode-demo` skips the camera and lands a canned product so the confirm card is
/// screenshot- and UI-testable without hardware.
struct BarcodeScanView: View {
    /// Called on Log: the product and how many servings. The host owns the actual meal insert.
    let onLog: (BarcodeFood.ScannedProduct, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.scanning
    @State private var servings = 1.0
    @State private var torchOn = false
    /// The capture session only mounts once permission is actually granted — mounting it while
    /// the ask is still undetermined attaches a dead input and the first-ever open stays black.
    @State private var cameraReady = false
    @State private var lookupService = OpenFoodFactsService()

    enum Phase: Equatable {
        case scanning
        case denied                                    // camera permission refused
        case looking                                   // network lookup in flight
        case found(BarcodeFood.ScannedProduct)
        case miss                                      // not in the database — describe instead
        case offline(String)                           // network trouble; the code rides for retry
    }

    private var demoMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--barcode-demo")
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraReady {
                CameraPreview(torchOn: torchOn) { handle(code: $0) }
                    .ignoresSafeArea()
            }
            reticle
            VStack {
                header
                Spacer()
                bottomCard
            }
        }
        .preferredColorScheme(.dark)   // chrome sits on live camera — always night
        .task {
            #if DEBUG
            if demoMode {   // the canned card exists only in DEBUG; release compiles it out
                try? await Task.sleep(nanoseconds: 600_000_000)
                phase = .found(Self.demoProduct)
                return
            }
            #endif
            // Ask up front so the denied state is a designed screen, not a black void.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                cameraReady = true
            case .notDetermined:
                if await AVCaptureDevice.requestAccess(for: .video) { cameraReady = true }
                else { phase = .denied }
            default:
                phase = .denied
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close scanner")
            Spacer()
            Text("Scan a barcode")
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Button {
                torchOn.toggle()
            } label: {
                Image(systemName: torchOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white.opacity(torchOn ? 0.3 : 0.14)))
            }
            .buttonStyle(.plain)
            .opacity(cameraReady ? 1 : 0)
            .disabled(!cameraReady)   // opacity alone can leave a ghost tap target
            .accessibilityLabel(torchOn ? "Turn torch off" : "Turn torch on")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.sm)
    }

    /// The viewfinder: everything but the scan window dims, the window keeps a clean hairline.
    private var reticle: some View {
        GeometryReader { geo in
            let w = min(geo.size.width - 2 * Theme.Space.xl, 340)
            let rect = CGRect(x: (geo.size.width - w) / 2,
                              y: geo.size.height * 0.30, width: w, height: w * 0.62)
            ZStack {
                Color.black.opacity(0.45)
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text("Line the barcode up inside the frame")
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: rect.midX, y: rect.maxY + 26)
                    .opacity(phase == .scanning && cameraReady ? 1 : 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: The bottom card, by phase

    @ViewBuilder
    private var bottomCard: some View {
        Group {
            switch phase {
            case .scanning:
                EmptyView()
            case .denied:
                card {
                    Text("Camera access is off")
                        .font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                    Text("Turn it on in Settings and the scanner reads any label in a second. Or just describe the meal — typing and voice work too.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    primaryButton("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    quietButton("Describe it instead") { dismiss() }
                }
            case .looking:
                card {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().controlSize(.regular)
                        Text("Reading the label…")
                            .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.Space.sm)
                }
            case .found(let product):
                confirmCard(product)
            case .miss:
                card {
                    Text("Not in the label database yet")
                        .font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                    Text("No guessing from here — describe the meal in your own words and it logs the honest way.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    primaryButton("Describe it instead") { dismiss() }
                    quietButton("Scan another") { resumeScanning() }
                }
            case .offline(let code):
                card {
                    Text("Couldn't reach the label database")
                        .font(.display(Theme.FontSize.headline, weight: .heavy)).foregroundStyle(Theme.ink)
                    Text("Check your connection and try again — or describe the meal instead.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    primaryButton("Try again") { lookup(code) }
                    quietButton("Describe it instead") { dismiss() }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.bottom, Theme.Space.lg)
        .animation(reduceMotion ? nil : Motion.standard, value: phase)
    }

    private func confirmCard(_ product: BarcodeFood.ScannedProduct) -> some View {
        let numbers = BarcodeFood.portion(of: product, servings: servings)
        return card {
            VStack(alignment: .leading, spacing: 3) {
                if let brand = product.brand {
                    Text(brand.uppercased())
                        .font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Theme.inkTertiary)
                }
                Text(product.name)
                    .font(.display(20, weight: .black)).foregroundStyle(Theme.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("Per serving · \(product.servingDescription)")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(numbers.kcal)")
                        .font(.display(30, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text("KCAL").font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                        .foregroundStyle(Theme.inkTertiary)
                }
                // Each macro wears its ring's ink (the Fuel-page doctrine exception: numbers in
                // data colors bind this card to the rings and journal rows it feeds). Energy
                // stays neutral — it's the headline number, not a ring.
                macro("\(numbers.carbsG)g", "CARBS", ink: Theme.Fuel.carbs)
                macro("\(numbers.proteinG)g", "PROTEIN", ink: Theme.Fuel.protein)
                macro("\(numbers.fatG)g", "FAT", ink: Theme.Fuel.fat)
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: servings)

            HStack {
                Text("Servings")
                    .font(.rounded(Theme.FontSize.body, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                stepButton("minus") { servings = max(0.5, servings - 0.5) }
                    .disabled(servings <= 0.5)
                    .accessibilityLabel("Fewer servings")
                Text(servingsLabel)
                    .font(.display(18, weight: .black)).monospacedDigit().foregroundStyle(Theme.ink)
                    .frame(minWidth: 52)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(servingsLabel) servings")
                stepButton("plus") { servings = min(10, servings + 0.5) }
                    .disabled(servings >= 10)
                    .accessibilityLabel("More servings")
            }

            primaryButton("Log it") {
                onLog(product, servings)
                dismiss()
            }
            quietButton("Scan another") { resumeScanning() }
        }
    }

    // MARK: Building blocks

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.lg)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface))
    }

    private func macro(_ value: String, _ label: String, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.display(18, weight: .heavy)).monospacedDigit().foregroundStyle(ink)
                .contentTransition(.numericText())
            Text(label).font(.rounded(Theme.FontSize.label, weight: .bold)).tracking(1)
                .foregroundStyle(Theme.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label.lowercased())")
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background { Circle().fill(Theme.background); Circle().stroke(Theme.hairline) }
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.rounded(Theme.FontSize.body, weight: .bold)).foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Capsule().fill(Theme.ink))
        }
        .buttonStyle(.plain)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.rounded(Theme.FontSize.body, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var servingsLabel: String {
        servings.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(servings)) : String(servings)
    }

    // MARK: Flow

    private func handle(code: String) {
        guard phase == .scanning, BarcodeFood.isLikelyFoodBarcode(code) else { return }
        Haptics.light()
        lookup(code)
    }

    private func lookup(_ code: String) {
        phase = .looking
        servings = 1
        Task {
            switch await lookupService.lookup(barcode: code) {
            case .found(let product): phase = .found(product)
            case .notFound:           phase = .miss
            case .unavailable:        phase = .offline(code)
            }
        }
    }

    private func resumeScanning() {
        servings = 1
        #if DEBUG
        if demoMode { phase = .found(Self.demoProduct); return }
        #endif
        phase = .scanning
    }

    #if DEBUG
    /// Canned product for `--barcode-demo` — real label numbers so the card reads true in shots.
    static let demoProduct = BarcodeFood.ScannedProduct(
        barcode: "0016000275270", name: "Crunchy Peanut Butter Granola Bars", brand: "Nature Valley",
        servingDescription: "2 bars (42 g)", kcal: 190, carbsG: 28, proteinG: 4, fatG: 7,
        sodiumMg: 160, potassiumMg: 95, calciumMg: 20, ironMg: 1.1)
    #endif
}

// MARK: - Camera

/// The AVFoundation half: session, preview layer, metadata (barcode) output, torch. Session work
/// runs on a utility queue — `startRunning` blocks, and the main thread owns a live run screen.
private struct CameraPreview: UIViewRepresentable {
    let torchOn: Bool
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.setTorch(torchOn)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "com.momentum.barcode.session", qos: .userInitiated)
        private var device: AVCaptureDevice?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func attach(to view: PreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            queue.async { [self] in
                guard session.inputs.isEmpty,
                      let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      session.canAddInput(input) else { return }
                device = camera
                // Barcodes live at arm's length: restricting focus hunting to the near range
                // cuts acquisition time on close, small codes.
                if camera.isAutoFocusRangeRestrictionSupported,
                   (try? camera.lockForConfiguration()) != nil {
                    camera.autoFocusRangeRestriction = .near
                    camera.unlockForConfiguration()
                }
                session.beginConfiguration()
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    session.commitConfiguration(); return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                // The retail food symbologies. Set AFTER addOutput — before it, the list is empty.
                output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128, .itf14]
                    .filter(output.availableMetadataObjectTypes.contains)
                session.commitConfiguration()
                session.startRunning()
            }
        }

        func setTorch(_ on: Bool) {
            queue.async { [self] in
                guard let device, device.hasTorch,
                      (try? device.lockForConfiguration()) != nil else { return }
                device.torchMode = on && device.isTorchAvailable ? .on : .off
                device.unlockForConfiguration()
            }
        }

        func teardown() {
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?
                .stringValue else { return }
            onCode(code)
        }
    }
}
