import AVFoundation
import SwiftUI

/// AVCaptureVideoPreviewLayer を SwiftUI に載せるだけの薄い層。
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspect
        // 収録側と同じ向きに揃える（CameraModel 側も landscapeRight にしてある）
        if let conn = v.videoPreviewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraModel()

    @State private var lens: Float = 0.5
    @State private var shutterMS: Double = 2.0
    @State private var iso: Float = 400
    @State private var fps: Double = 120
    @State private var showFormats = false
    @State private var showRecord = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(session: cam.session).ignoresSafeArea()

            VStack {
                header
                Spacer()
                controls
            }
            .padding()
        }
        .onAppear { cam.start() }
        .sheet(isPresented: $showFormats) { formatList }
        .sheet(isPresented: $showRecord) { recordSheet }
    }

    // MARK: 上部

    private var header: some View {
        HStack {
            Text(cam.status)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Button("フォーマット一覧") { showFormats = true }
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 下部のつまみ

    private var controls: some View {
        VStack(spacing: 10) {
            slider("ピント", value: Binding(get: { Double(lens) },
                                          set: { lens = Float($0); cam.setFocus(lens) }),
                   range: 0...1, text: String(format: "%.3f", lens))

            slider("シャッター", value: Binding(get: { shutterMS },
                                             set: { shutterMS = $0; pushExposure() }),
                   range: cam.shutterRangeMS,
                   text: String(format: "%.2f ms  (1/%.0f)", shutterMS, 1000.0 / max(shutterMS, 0.01)))

            slider("ISO", value: Binding(get: { Double(iso) },
                                        set: { iso = Float($0); pushExposure() }),
                   range: Double(cam.isoRange.lowerBound)...Double(cam.isoRange.upperBound),
                   text: String(format: "%.0f", iso))

            HStack(spacing: 12) {
                Button {
                    cam.toggleRecording(lensPosition: lens, shutterMS: shutterMS, iso: iso, fps: fps)
                } label: {
                    Text(cam.isRecording ? "停止" : "録画")
                        .font(.system(size: 17, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(cam.isRecording ? .red : .white,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(cam.isRecording ? .white : .black)
                }
                if cam.lastRecordText != nil {
                    Button("記録") { showRecord = true }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minHeight: 46).padding(.horizontal, 14)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
            }

            if let name = cam.lastSavedName {
                Text("保存: \(name)  ＋ 同名の .txt（ファイルAppの GaitCam の中）")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(text).font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(.white)
            Slider(value: value, in: range)
        }
    }

    private func pushExposure() {
        cam.setExposure(shutterMS: shutterMS, iso: iso)
    }

    // MARK: フォーマット一覧（このiPhoneが third-party に何を開示しているかの実物）

    private var formatList: some View {
        NavigationStack {
            List {
                Section {
                    Text("この一覧が、このiPhoneがアプリに開示しているすべての撮影モードです。"
                         + "ここに 120 fps の行があれば、120fpsで撮れます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("100 fps 以上") { rows(cam.formats.filter { $0.maxFPS >= 100 }) }
                Section("それ以外") { rows(cam.formats.filter { $0.maxFPS < 100 }) }
            }
            .navigationTitle("フォーマット")
            .toolbar { Button("閉じる") { showFormats = false } }
        }
    }

    private func rows(_ list: [FormatInfo]) -> some View {
        ForEach(list) { f in
            Button {
                fps = min(f.maxFPS, 240)
                cam.select(formatIndex: f.id, fps: fps)
                showFormats = false
            } label: {
                HStack {
                    Text(f.label).font(.system(size: 13, design: .monospaced))
                    Spacer()
                    if f.id == cam.activeFormatIndex { Image(systemName: "checkmark") }
                }
            }
        }
    }

    // MARK: 撮影記録

    private var recordSheet: some View {
        NavigationStack {
            ScrollView {
                Text(cam.lastRecordText ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("撮影記録")
            .toolbar { Button("閉じる") { showRecord = false } }
        }
    }
}
