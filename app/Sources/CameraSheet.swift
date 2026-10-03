import AppKit
import AVFoundation

/// Takes a photo with the Mac's camera, or an iPhone through Continuity Camera:
/// live preview and a shutter, then Retake or Use Photo, like WhatsApp's camera.
/// The photo then waits in the composer for a caption.
final class CameraViewController: NSViewController {
    var onPhoto: ((URL) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let stage = NSView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let still = NSImageView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton()
    private let shutter = ShutterButton()
    private let cancelButton = NSButton()
    private let retakeButton = NSButton()
    private let useButton = NSButton()
    private let devicePicker = NSPopUpButton()
    private var devices: [AVCaptureDevice] = []
    private var input: AVCaptureDeviceInput?
    private var captured: Data?
    private var photoDelegate: PhotoDelegate?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.layer?.cornerRadius = 12
        stage.layer?.masksToBounds = true
        still.imageScaling = .scaleProportionallyUpOrDown
        still.isHidden = true
        notice.alignment = .center
        notice.font = .systemFont(ofSize: 13)
        notice.textColor = .white
        notice.isHidden = true
        settingsButton.title = "Open Privacy & Security"
        settingsButton.bezelStyle = .push
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.isHidden = true

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .push
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(close)
        retakeButton.title = "Retake"
        retakeButton.bezelStyle = .push
        retakeButton.controlSize = .large
        retakeButton.target = self
        retakeButton.action = #selector(retake)
        useButton.title = "Use Photo"
        useButton.bezelStyle = .push
        useButton.controlSize = .large
        useButton.keyEquivalent = "\r"
        useButton.target = self
        useButton.action = #selector(usePhoto)
        shutter.target = self
        shutter.action = #selector(capture)
        shutter.toolTip = "Take Photo"
        devicePicker.controlSize = .regular
        devicePicker.target = self
        devicePicker.action = #selector(switchDevice)

        for v in [stage, still, notice, settingsButton, shutter, cancelButton, retakeButton, useButton, devicePicker] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stage.heightAnchor.constraint(equalTo: stage.widthAnchor, multiplier: 9.0 / 16.0),
            still.topAnchor.constraint(equalTo: stage.topAnchor),
            still.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            still.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            still.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            notice.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: stage.centerYAnchor, constant: -14),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            settingsButton.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            settingsButton.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 12),
            shutter.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 14),
            shutter.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            shutter.widthAnchor.constraint(equalToConstant: 56),
            shutter.heightAnchor.constraint(equalToConstant: 56),
            shutter.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            cancelButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            retakeButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            retakeButton.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            useButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            useButton.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            devicePicker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            devicePicker.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            devicePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            root.widthAnchor.constraint(equalToConstant: 640),
        ])
        view = root
        showLive(true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in ok ? self?.start() : self?.denied() }
                }
            }
        default:
            denied()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        nonisolated(unsafe) let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    private func denied() {
        notice.stringValue = "\(Brand.name) can't use the camera. Turn it on in System Settings › Privacy & Security › Camera."
        notice.isHidden = false
        settingsButton.isHidden = false
        shutter.isEnabled = false
        devicePicker.isHidden = true
    }

    private func start() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                                     mediaType: .video, position: .unspecified).devices
        devices = found
        guard let first = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? found.first else {
            notice.stringValue = "No camera found."
            notice.isHidden = false
            shutter.isEnabled = false
            devicePicker.isHidden = true
            return
        }
        devicePicker.removeAllItems()
        devicePicker.addItems(withTitles: found.map(\.localizedName))
        devicePicker.selectItem(withTitle: first.localizedName)
        devicePicker.isHidden = found.count < 2
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        use(first)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = stage.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        stage.layer?.addSublayer(layer)
        previewLayer = layer
        mirror(for: first)
        nonisolated(unsafe) let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    private func use(_ device: AVCaptureDevice) {
        guard let newInput = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        }
        session.commitConfiguration()
        mirror(for: device)
    }

    /// The Mac's own camera previews mirrored, as in FaceTime; the photo itself isn't.
    private func mirror(for device: AVCaptureDevice) {
        guard let c = previewLayer?.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = device.deviceType == .builtInWideAngleCamera
    }

    @objc private func switchDevice() {
        let i = devicePicker.indexOfSelectedItem
        guard i >= 0, i < devices.count else { return }
        use(devices[i])
    }

    @objc private func capture() {
        let d = PhotoDelegate { [weak self] data in self?.captured(data) }
        photoDelegate = d
        output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: d)
        // The shutter blinks the preview, like Photo Booth.
        if !Theme.reduceMotion {
            let flash = CABasicAnimation(keyPath: "opacity")
            flash.fromValue = 0.2
            flash.toValue = 1
            flash.duration = 0.25
            flash.timingFunction = Theme.easeOut
            previewLayer?.add(flash, forKey: "flash")
        }
    }

    private func captured(_ data: Data?) {
        guard let data, let img = NSImage(data: data) else { NSSound.beep(); return }
        captured = data
        still.image = img
        showLive(false)
    }

    @objc private func retake() {
        captured = nil
        still.image = nil
        showLive(true)
    }

    private func showLive(_ live: Bool) {
        still.isHidden = live
        shutter.isHidden = !live
        cancelButton.isHidden = !live
        devicePicker.isHidden = !live || devices.count < 2
        retakeButton.isHidden = live
        useButton.isHidden = live
    }

    @objc private func usePhoto() {
        guard let data = captured else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).jpg")
        guard (try? data.write(to: url)) != nil else { NSSound.beep(); return }
        onPhoto?(url)
        dismiss(nil)
    }

    @objc private func close() { dismiss(nil) }

    @objc private func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// AVFoundation calls back on its own queue; this hands the photo to the main actor.
private nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let done: @MainActor (Data?) -> Void

    init(_ done: @escaping @MainActor (Data?) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let done = self.done
        DispatchQueue.main.async { MainActor.assumeIsolated { done(data) } }
    }
}

/// The round white shutter: a ring and a disc that dips when pressed.
private final class ShutterButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 3
        (isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
        ring.stroke()
        let inset: CGFloat = isHighlighted ? 8 : 6
        (isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor).withAlphaComponent(isHighlighted ? 0.7 : 1).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: inset, dy: inset)).fill()
    }
}
