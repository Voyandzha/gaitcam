import AVFoundation
import Foundation

/// センサーの1つの読み出しモード。「このiPhoneが何を開示しているか」を画面に出すための入れ物。
struct FormatInfo: Identifiable {
    let id: Int
    let width: Int32
    let height: Int32
    let maxFPS: Double
    let minFPS: Double
    let isBinned: Bool
    let fourCC: String

    var label: String {
        let hz = maxFPS == minFPS ? String(format: "%.0f", maxFPS)
                                  : String(format: "%.0f〜%.0f", minFPS, maxFPS)
        return "\(width)×\(height)  \(hz) fps  \(fourCC)\(isBinned ? "  binned" : "")"
    }
}

/// 撮影1回ぶんの再現条件。動画と同じ名前の .txt に書き出す。
/// (プロジェクトの決まり: 再現条件は記憶や口頭ではなくファイルに自動記録する)
struct ShotSettings {
    var formatLabel = ""
    var requestedFPS: Double = 0
    var lensPosition: Float = 0
    var iso: Float = 0
    var shutterSeconds: Double = 0
    var stabilization = "off"
    var whiteBalance = "locked"
    var deviceModel = ""
    var startedAt = Date()

    func asText(measuredFPS: Double?, frameCount: Int?) -> String {
        let f = ISO8601DateFormatter()
        var lines = [
            "# GaitCam 撮影記録",
            "撮影日時      : \(f.string(from: startedAt))",
            "端末          : \(deviceModel)",
            "フォーマット  : \(formatLabel)",
            "要求fps       : \(String(format: "%.2f", requestedFPS))",
            "レンズ位置    : \(String(format: "%.4f", lensPosition))   (0.0=最至近 1.0=無限遠。次回この値をそのまま入れれば同じピント)",
            "ISO           : \(String(format: "%.1f", iso))",
            "シャッター    : \(String(format: "%.4f", shutterSeconds)) 秒 = 1/\(String(format: "%.0f", 1.0 / max(shutterSeconds, 1e-9)))",
            "手ぶれ補正    : \(stabilization)   (座標を測るので必ず off)",
            "ホワイトバランス: \(whiteBalance)",
        ]
        if let m = measuredFPS {
            lines.append("実測fps       : \(String(format: "%.3f", m))   ← ファイルから読み直した値")
        }
        if let c = frameCount {
            lines.append("総コマ数      : \(c)")
        }
        lines.append("")
        lines.append("※ PC側で ffprobe を流して必ず突き合わせること。アプリの自己申告を信用しない。")
        return lines.joined(separator: "\n")
    }
}

final class CameraModel: NSObject, ObservableObject {

    let session = AVCaptureSession()

    @Published private(set) var formats: [FormatInfo] = []
    @Published private(set) var status = "起動中…"
    @Published private(set) var isRecording = false
    @Published private(set) var lastSavedName: String?
    @Published private(set) var lastRecordText: String?
    /// 起動時に書き出すフォーマット一覧。PCへ共有して中身を確認するためのもの。
    @Published private(set) var formatsFileURL: URL?

    /// 選んでいるフォーマットの index（formats の id と同じ）
    @Published private(set) var activeFormatIndex: Int = -1
    @Published private(set) var isoRange: ClosedRange<Float> = 50...800
    @Published private(set) var shutterRangeMS: ClosedRange<Double> = 0.5...8.0

    private let sessionQueue = DispatchQueue(label: "gaitcam.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var pendingSettings = ShotSettings()

    // MARK: - 立ち上げ

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else {
                    self.publish { self.status = "カメラの使用を許可してください" }
                    return
                }
                self.sessionQueue.async { self.configure() }
            }
        }
    }

    private func configure() {
        // 背面の広角。高フレームレートのフォーマットを持っているのは基本ここだけ。
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            publish { self.status = "背面カメラが見つかりません" }
            return
        }
        device = dev

        session.beginConfiguration()
        // ★ sessionPreset ではなく activeFormat で決める、という宣言。
        //   これを先に立てないと、セッションが勝手にフォーマットを選び直して fps が落ちる。
        session.sessionPreset = .inputPriority
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()

        if let conn = movieOutput.connection(with: .video) {
            // ★ 手ぶれ補正は必ず切る。座標を測るので、コマごとに画がワープするのは致命的。
            //   （検出は良くなったように見えるのに、座標が信用できなくなる種類の機能）
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .off
            }
            // 横向き固定。ここを設定しないと縦向きで書き出され、PC側で寝た動画になる。
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .landscapeRight
            }
        }

        let list = dev.formats.enumerated().map { (i, f) -> FormatInfo in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let maxR = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let minR = f.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
            let cc = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return FormatInfo(id: i, width: d.width, height: d.height,
                              maxFPS: maxR, minFPS: minR,
                              isBinned: f.isVideoBinned, fourCC: fourCCString(cc))
        }
        publish { self.formats = list }
        writeFormatsFile(list, device: dev)

        // 既定は「1080pで最大fpsが最も高いもの」。無ければ全体の最大fps。
        let best = list.filter { $0.height == 1080 }.max(by: { $0.maxFPS < $1.maxFPS })
            ?? list.max(by: { $0.maxFPS < $1.maxFPS })
        if let best { select(formatIndex: best.id, fps: min(best.maxFPS, 120)) }

        session.startRunning()
    }

    // MARK: - フォーマットと fps

    /// ★ 順番が命。activeFormat を先、フレーム時間を後。逆にするとアプリが即死する（Apple TN2409）。
    func select(formatIndex: Int, fps: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device,
                  dev.formats.indices.contains(formatIndex) else { return }
            let fmt = dev.formats[formatIndex]
            do {
                try dev.lockForConfiguration()
                dev.activeFormat = fmt

                // min と max を「両方」同じ値にすることで固定フレームレートになる。
                // 片方だけだと可変になり、暗いと勝手に fps が落ちる。
                let want = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
                dev.activeVideoMinFrameDuration = want
                dev.activeVideoMaxFrameDuration = want

                // 露光の上限は 1/fps に縛られる。その範囲をUIに渡す。
                let minExp = CMTimeGetSeconds(fmt.minExposureDuration)
                let maxExp = min(CMTimeGetSeconds(fmt.maxExposureDuration), 1.0 / fps)
                let isoLo = fmt.minISO, isoHi = fmt.maxISO
                dev.unlockForConfiguration()

                self.publish {
                    self.activeFormatIndex = formatIndex
                    self.isoRange = isoLo...isoHi
                    self.shutterRangeMS = (minExp * 1000)...(max(maxExp, minExp * 1.01) * 1000)
                    let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                    self.status = "\(d.width)×\(d.height) / \(Int(fps)) fps 固定"
                }
            } catch {
                self.publish { self.status = "設定できません: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - 手動フォーカス・手動露出

    /// lensPosition は 0.0〜1.0 の数値。メートルではない。この数値を記録すれば次回そのまま再現できる。
    func setFocus(_ position: Float) {
        sessionQueue.async { [weak self] in
            guard let dev = self?.device,
                  dev.isLockingFocusWithCustomLensPositionSupported else { return }
            try? dev.lockForConfiguration()
            dev.setFocusModeLocked(lensPosition: position, completionHandler: nil)
            dev.unlockForConfiguration()
        }
    }

    func setExposure(shutterMS: Double, iso: Float) {
        sessionQueue.async { [weak self] in
            guard let dev = self?.device else { return }
            let dur = CMTime(seconds: shutterMS / 1000.0, preferredTimescale: 1_000_000)
            try? dev.lockForConfiguration()
            dev.setExposureModeCustom(duration: dur,
                                      iso: max(dev.activeFormat.minISO,
                                               min(iso, dev.activeFormat.maxISO)),
                                      completionHandler: nil)
            // 明るさが撮影中に動くと DLC の精度が変わるので、ホワイトバランスも固定する。
            if dev.isWhiteBalanceModeSupported(.locked) {
                dev.whiteBalanceMode = .locked
            }
            dev.unlockForConfiguration()
        }
    }

    // MARK: - 収録

    func toggleRecording(lensPosition: Float, shutterMS: Double, iso: Float, fps: Double) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            var s = ShotSettings()
            s.formatLabel = self.formats.first { $0.id == self.activeFormatIndex }?.label ?? "?"
            s.requestedFPS = fps
            s.lensPosition = lensPosition
            s.iso = iso
            s.shutterSeconds = shutterMS / 1000.0
            s.deviceModel = deviceModelIdentifier()
            self.pendingSettings = s

            let name = "gait_\(Int(Date().timeIntervalSince1970))"
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(name).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.publish { self.isRecording = true; self.lastRecordText = nil }
        }
    }

    // MARK: - フォーマット一覧の書き出し

    /// このiPhoneがアプリに開示している撮影モードを全部テキストにする。
    /// 画面を写真に撮って送る手間を無くすため。PCへ共有して読む。
    private func writeFormatsFile(_ list: [FormatInfo], device dev: AVCaptureDevice) {
        let fast = list.filter { $0.maxFPS >= 100 }
        let slow = list.filter { $0.maxFPS < 100 }

        var lines = [
            "# GaitCam フォーマット一覧",
            "端末          : \(deviceModelIdentifier())",
            "OS            : \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "カメラ        : \(dev.localizedName)",
            "取得日時      : \(ISO8601DateFormatter().string(from: Date()))",
            "",
            "この一覧が、このiPhoneがサードパーティのアプリに開示している撮影モードのすべて。",
            "ここに 120 fps の行があれば 120fps で撮れる。無ければ撮れない。",
            "",
            "================ 100 fps 以上（\(fast.count)件）================",
        ]
        lines += fast.isEmpty ? ["  （1件も無い）"] : fast.map { "  " + $0.label }
        lines += ["", "================ それ以外（\(slow.count)件）================"]
        lines += slow.map { "  " + $0.label }
        lines += ["", "合計 \(list.count) 件"]

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("formats.txt")
        try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
        publish { self.formatsFileURL = url }
    }

    // MARK: - 小道具

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - 収録が終わったとき

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {

        // 書けた動画から fps とコマ数を読み直す。アプリの自己申告ではなく実測。
        let asset = AVURLAsset(url: outputFileURL)
        var measured: Double?
        var frames: Int?
        if let track = asset.tracks(withMediaType: .video).first {
            measured = Double(track.nominalFrameRate)
            let dur = CMTimeGetSeconds(asset.duration)
            if dur > 0, let m = measured { frames = Int((dur * m).rounded()) }
        }

        let text = pendingSettings.asText(measuredFPS: measured, frameCount: frames)
        let sidecar = outputFileURL.deletingPathExtension().appendingPathExtension("txt")
        try? text.data(using: .utf8)?.write(to: sidecar)

        publish {
            self.isRecording = false
            self.lastSavedName = outputFileURL.lastPathComponent
            self.lastRecordText = error.map { "収録エラー: \($0.localizedDescription)" } ?? text
        }
    }
}

// MARK: - ユーティリティ

private func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                 UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
}

private func deviceModelIdentifier() -> String {
    var info = utsname()
    uname(&info)
    let m = Mirror(reflecting: info.machine)
    return m.children.reduce(into: "") { acc, e in
        if let v = e.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
    }
}
