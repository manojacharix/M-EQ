// BassEQ: a menu-bar bass equalizer for one Bluetooth speaker (default SA-D40M2).
//
// How it works (no audio driver needed, macOS 14.4+):
//   1. A global Core Audio process tap captures everything the system plays and
//      mutes the original ("mutedWhenTapped"), excluding this app itself.
//   2. A private aggregate device pairs that tap (input) with the speaker (output).
//   3. An IOProc on the aggregate runs the audio through the bass filters and
//      writes it straight to the speaker.
// The EQ only engages while the target speaker is the default output. Quit the
// app (or toggle it off) and audio flows exactly as before.

import SwiftUI
import CoreAudio
import AudioToolbox

// MARK: - Core Audio helpers

enum CAError: LocalizedError {
    case status(String, OSStatus)
    var errorDescription: String? {
        if case let .status(what, s) = self { return "\(what) failed (\(s))" }
        return nil
    }
}

@inline(__always)
func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw CAError.status(what, s) }
}

func address(_ sel: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T: BitwiseCopyable>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var addr = address(sel, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "read property")
    return value
}

func readString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = address(sel)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func defaultOutputDevice() -> AudioDeviceID {
    (try? readValue(AudioObjectID(kAudioObjectSystemObject),
                    kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(kAudioObjectUnknown)))
        ?? AudioDeviceID(kAudioObjectUnknown)
}

func ownProcessObject() -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = getpid()
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    return s == noErr ? obj : AudioObjectID(kAudioObjectUnknown)
}

// MARK: - Filters

enum BassMode: String, CaseIterable, Identifiable {
    case shelf = "Shelf", punch = "Punch"
    var id: String { rawValue }
}

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    // RBJ Audio EQ Cookbook formulas, normalised by a0.
    static func lowShelf(fs: Double, f0: Double, gainDB: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs
        let c = cos(w), alpha = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * alpha
        let a0 = (A + 1) + (A - 1) * c + sA
        return Biquad(b0: A * ((A + 1) - (A - 1) * c + sA) / a0,
                      b1: 2 * A * ((A - 1) - (A + 1) * c) / a0,
                      b2: A * ((A + 1) - (A - 1) * c - sA) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * c) / a0,
                      a2: ((A + 1) + (A - 1) * c - sA) / a0)
    }

    static func peaking(fs: Double, f0: Double, gainDB: Double, q: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs
        let c = cos(w), alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0, b1: -2 * c / a0, b2: (1 - alpha * A) / a0,
                      a1: -2 * c / a0, a2: (1 - alpha / A) / a0)
    }

    static func highPass(fs: Double, f0: Double) -> Biquad {
        let w = 2 * .pi * f0 / fs, c = cos(w), alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    func magnitudeDB(at f: Double, fs: Double) -> Double {
        let w = 2 * .pi * f / fs
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

struct EQSettings: Equatable {
    var bassDB = 6.0
    var frequency = 90.0
    var mode = BassMode.shelf
    var lowCut = true

    static let lowCutHz = 40.0

    func filters(fs: Double) -> (bass: Biquad, hp: Biquad?) {
        let bass = mode == .shelf
            ? Biquad.lowShelf(fs: fs, f0: frequency, gainDB: bassDB)
            : Biquad.peaking(fs: fs, f0: frequency, gainDB: bassDB, q: 1.0)
        return (bass, lowCut ? Biquad.highPass(fs: fs, f0: Self.lowCutHz) : nil)
    }

    func responseDB(at f: Double, fs: Double = 48000) -> Double {
        let (bass, hp) = filters(fs: fs)
        return bass.magnitudeDB(at: f, fs: fs) + (hp?.magnitudeDB(at: f, fs: fs) ?? 0)
    }
}

/// Real-time processor. Called on the Core Audio IO thread; never allocates or locks.
/// Coefficient updates from the UI thread are plain struct stores: a torn read at
/// worst affects a single buffer and is inaudible.
final class BassDSP: @unchecked Sendable {
    private static let maxChannels = 16
    private var bass = Biquad()
    private var hp = Biquad()
    private var hpOn = false
    /// Peak input level since the UI last read it (diagnostic: 0 means the tap delivers silence).
    var inputPeak: Float = 0
    // Per channel: bass z1, z2, hp z1, hp z2.
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * 4)

    init() { state.initialize(repeating: 0, count: Self.maxChannels * 4) }
    deinit { state.deallocate() }

    func configure(_ s: EQSettings, sampleRate fs: Double) {
        let (b, h) = s.filters(fs: fs)
        bass = b
        if let h { hp = h }
        hpOn = h != nil
    }

    func reset() { state.update(repeating: 0, count: Self.maxChannels * 4) }

    /// Finds input channel `index` (wrapping) across however the tap lays out its buffers.
    private func source(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int)
        -> (UnsafeMutablePointer<Float>, Int, Int)? {
        var total = 0
        for b in list { total += Int(b.mNumberChannels) }
        guard total > 0 else { return nil }
        var i = index % total
        for b in list {
            let n = Int(b.mNumberChannels)
            if i < n, let d = b.mData {
                return (d.assumingMemoryBound(to: Float.self) + i, n, Int(b.mDataByteSize) / (4 * n))
            }
            i -= n
        }
        return nil
    }

    func process(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        let bq = bass, hq = hp, useHP = hpOn
        var channel = 0
        for ob in output {
            guard let od = ob.mData else { continue }
            let oc = Int(ob.mNumberChannels)
            guard oc > 0 else { continue }
            let outFrames = Int(ob.mDataByteSize) / (4 * oc)
            let out = od.assumingMemoryBound(to: Float.self)
            for c in 0..<oc {
                defer { channel += 1 }
                let o = out + c
                guard channel < Self.maxChannels, let (src, stride, inFrames) = source(input, channel) else {
                    for f in 0..<outFrames { o[f * oc] = 0 }
                    continue
                }
                let st = state + channel * 4
                var z1 = st[0], z2 = st[1], h1 = st[2], h2 = st[3]
                let n = min(inFrames, outFrames)
                var peak = inputPeak
                for f in 0..<n {
                    let sample = src[f * stride]
                    peak = max(peak, abs(sample))
                    var x = Double(sample)
                    if useHP {
                        let y = hq.b0 * x + h1
                        h1 = hq.b1 * x - hq.a1 * y + h2
                        h2 = hq.b2 * x - hq.a2 * y
                        x = y
                    }
                    var y = bq.b0 * x + z1
                    z1 = bq.b1 * x - bq.a1 * y + z2
                    z2 = bq.b2 * x - bq.a2 * y
                    // Soft limiter above 0.85 so bass boost never hard-clips.
                    let a = abs(y)
                    if a > 0.85 { y = (y < 0 ? -1 : 1) * (0.85 + 0.15 * tanh((a - 0.85) / 0.15)) }
                    o[f * oc] = Float(y)
                }
                if n < outFrames { for f in n..<outFrames { o[f * oc] = 0 } }
                inputPeak = peak
                st[0] = z1; st[1] = z2; st[2] = h1; st[3] = h2
            }
        }
    }
}

// MARK: - Engine

@MainActor
final class EQEngine: ObservableObject {
    @Published var settings: EQSettings { didSet { settingsChanged() } }
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); reconcile() } }
    @Published private(set) var status = "Starting…" { didSet { NSLog("BassEQ status: %@", status) } }
    @Published private(set) var running = false
    @Published private(set) var level: Float = 0
    private var everHeardAudio = false

    let targetName: String
    private let defaults = UserDefaults.standard
    private let dsp = BassDSP()
    private let ioQueue = DispatchQueue(label: "basseq.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate = 44100.0
    private var reconcilePending = false

    init() {
        defaults.register(defaults: ["enabled": true, "bassDB": 6.0, "frequency": 90.0,
                                     "mode": BassMode.shelf.rawValue, "lowCut": true,
                                     "targetName": "SA-D40M2"])
        targetName = defaults.string(forKey: "targetName") ?? "SA-D40M2"
        enabled = defaults.bool(forKey: "enabled")
        settings = EQSettings(bassDB: defaults.double(forKey: "bassDB"),
                              frequency: defaults.double(forKey: "frequency"),
                              mode: BassMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .shelf,
                              lowCut: defaults.bool(forKey: "lowCut"))
        dsp.configure(settings, sampleRate: sampleRate)

        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(sys, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleReconcile() }
            }
        }
        reconcile()

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollLevel() }
        }
    }

    private func pollLevel() {
        let peak = dsp.inputPeak
        dsp.inputPeak = 0
        level = running ? max(peak, level * 0.8) : 0
        if running && peak > 0.001 && !everHeardAudio {
            everHeardAudio = true
            NSLog("BassEQ: receiving system audio (peak %.3f)", peak)
        }
    }

    private func settingsChanged() {
        defaults.set(settings.bassDB, forKey: "bassDB")
        defaults.set(settings.frequency, forKey: "frequency")
        defaults.set(settings.mode.rawValue, forKey: "mode")
        defaults.set(settings.lowCut, forKey: "lowCut")
        dsp.configure(settings, sampleRate: sampleRate)
    }

    /// Bluetooth connects fire several notifications in a burst; coalesce them.
    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcilePending = false
                self?.reconcile()
            }
        }
    }

    func reconcile() {
        let target = allDevices().first { readString($0, kAudioObjectPropertyName) == targetName }
        let isDefault = target != nil && target == defaultOutputDevice()

        guard enabled else { stop(); status = "Off"; return }
        guard let target else { stop(); status = "\(targetName) not connected"; return }
        guard isDefault else { stop(); status = "\(targetName) is not the current output"; return }
        if running { return }
        do {
            try start(device: target)
            status = "Active on \(targetName) · \(Int(sampleRate)) Hz"
        } catch {
            stop()
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    private func start(device: AudioDeviceID) throws {
        guard let deviceUID = readString(device, kAudioDevicePropertyDeviceUID) else {
            throw CAError.status("read speaker UID", -1)
        }

        let me = ownProcessObject()
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        tap.uuid = UUID()
        tap.name = "BassEQ Tap"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create system audio tap")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BassEQ",
            kAudioAggregateDeviceUIDKey: "basseq-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID), "create aggregate device")

        sampleRate = (try? readValue(aggID, kAudioDevicePropertyNominalSampleRate, Float64(0))) ?? 0
        if sampleRate <= 0 { sampleRate = 44100 }
        dsp.reset()
        dsp.configure(settings, sampleRate: sampleRate)

        // Bluetooth speakers can change rate (e.g. when a call grabs the mic); retune if so.
        var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(aggID, &rateAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.running,
                      let r = try? readValue(self.aggID, kAudioDevicePropertyNominalSampleRate, Float64(0)), r > 0
                else { return }
                self.sampleRate = r
                self.dsp.configure(self.settings, sampleRate: r)
                self.status = "Active on \(self.targetName) · \(Int(r)) Hz"
            }
        }

        let dsp = self.dsp
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inData, _, outData, _ in
            dsp.process(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                        output: UnsafeMutableAudioBufferListPointer(outData))
        }, "create IO proc")
        try check(AudioDeviceStart(aggID, procID), "start audio")
        running = true
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggID, procID)
                AudioDeviceDestroyIOProcID(aggID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }
}

// MARK: - UI

struct ResponseCurve: View {
    let settings: EQSettings
    private let fMin = 20.0, fMax = 2000.0, dbRange = 15.0

    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / fMin) / log10(fMax / fMin)) * size.width }
            func y(_ db: Double) -> CGFloat { CGFloat((dbRange - max(-dbRange, min(dbRange, db))) / (2 * dbRange)) * size.height }

            var grid = Path()
            for f in [50.0, 100, 200, 500, 1000] {
                grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height))
            }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)

            var curve = Path()
            for i in 0...120 {
                let f = fMin * pow(fMax / fMin, Double(i) / 120)
                let p = CGPoint(x: x(f), y: y(settings.responseDB(at: f)))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)

            for (f, label) in [(50.0, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k")] {
                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: x(f), y: size.height - 6))
            }
        }
        .frame(height: 90)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }
}

struct PanelView: View {
    @ObservedObject var engine: EQEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bass EQ").font(.headline)
                Spacer()
                Toggle("", isOn: $engine.enabled).toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: 6) {
                Circle().fill(engine.running ? .green : .orange).frame(width: 7, height: 7)
                Text(engine.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            ResponseCurve(settings: engine.settings)

            HStack(spacing: 8) {
                Text("Signal").font(.caption2).foregroundStyle(.secondary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(engine.level > 0.95 ? Color.red : Color.green)
                            .frame(width: g.size.width * CGFloat(min(1, sqrt(engine.level))))
                    }
                }
                .frame(height: 5)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Bass")
                    Spacer()
                    Text(String(format: "%+.1f dB", engine.settings.bassDB)).monospacedDigit()
                }
                Slider(value: $engine.settings.bassDB, in: -12...12, step: 0.5)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Frequency")
                    Spacer()
                    Text("\(Int(engine.settings.frequency)) Hz").monospacedDigit()
                }
                Slider(value: $engine.settings.frequency, in: 40...250, step: 5)
            }

            Picker("Shape", selection: $engine.settings.mode) {
                ForEach(BassMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(engine.settings.mode == .shelf
                 ? "Shelf lifts everything below the frequency."
                 : "Punch boosts a band around the frequency (kick drum thump).")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("Low cut below 40 Hz (protects small drivers)", isOn: $engine.settings.lowCut)
                .font(.caption)

            HStack {
                preset("Flat", 0, 90, .shelf)
                preset("Warm", 4, 120, .shelf)
                preset("Boost", 8, 90, .shelf)
                preset("Thump", 6, 70, .punch)
                preset("Less boom", -6, 150, .shelf)
            }
            .controlSize(.small)

            Divider()
            HStack {
                Text("Target: \(engine.targetName)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { engine.stop(); NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func preset(_ name: String, _ db: Double, _ f: Double, _ m: BassMode) -> some View {
        Button(name) {
            engine.settings.bassDB = db
            engine.settings.frequency = f
            engine.settings.mode = m
        }
    }
}

@main
struct BassEQApp: App {
    @StateObject private var engine = EQEngine()

    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(engine: engine)
        } label: {
            Image(systemName: engine.running ? "speaker.wave.3.fill" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Self test (BassEQ.app/Contents/MacOS/BassEQ --selftest)

enum SelfTest {
    /// Feeds sine waves through the real-time processor and compares measured gain
    /// with the analytic response curve.
    static func run() -> Never {
        let fs = 44100.0
        var failures = 0
        let cases: [(EQSettings, Double)] = [
            (EQSettings(bassDB: 6, frequency: 90, mode: .shelf, lowCut: false), 30),
            (EQSettings(bassDB: 6, frequency: 90, mode: .shelf, lowCut: false), 5000),
            (EQSettings(bassDB: -6, frequency: 150, mode: .shelf, lowCut: false), 40),
            (EQSettings(bassDB: 6, frequency: 70, mode: .punch, lowCut: false), 70),
            (EQSettings(bassDB: 6, frequency: 70, mode: .punch, lowCut: false), 1000),
            (EQSettings(bassDB: 0, frequency: 90, mode: .shelf, lowCut: true), 20),
            (EQSettings(bassDB: 0, frequency: 90, mode: .shelf, lowCut: true), 1000),
        ]
        for (s, f) in cases {
            let dsp = BassDSP()
            dsp.configure(s, sampleRate: fs)
            let frames = 44100, amp: Float = 0.1
            let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames {
                let v = amp * Float(sin(2 * .pi * f * Double(i) / fs))
                inBuf[2 * i] = v; inBuf[2 * i + 1] = v
            }
            let inList = AudioBufferList.allocate(maximumBuffers: 1)
            inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: inBuf)
            // Output as two non-interleaved buffers to exercise channel mapping.
            let outR = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let outList = AudioBufferList.allocate(maximumBuffers: 2)
            outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outBuf)
            outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outR)
            dsp.process(input: inList, output: outList)
            // RMS over the second half (after filter settles).
            func rms(_ p: UnsafeMutablePointer<Float>, _ stride: Int) -> Double {
                var acc = 0.0
                for i in frames / 2..<frames { let v = Double(p[i * stride]); acc += v * v }
                return sqrt(acc / Double(frames / 2))
            }
            let measured = 20 * log10(rms(outBuf, 1) / rms(inBuf, 2))
            let right = 20 * log10(rms(outR, 1) / rms(inBuf, 2))
            let expected = s.responseDB(at: f, fs: fs)
            let ok = abs(measured - expected) < 0.3 && abs(right - measured) < 0.01
            if !ok { failures += 1 }
            print(String(format: "%@ %-5@ %+5.1f dB @ %4.0f Hz, lowCut=%@ -> measured %+6.2f dB, expected %+6.2f dB",
                         ok ? "PASS" : "FAIL", s.mode.rawValue, s.bassDB, s.frequency,
                         s.lowCut ? "on " : "off", measured, expected) + "  (tone \(Int(f)) Hz)")
        }
        // Limiter: a loud boosted bass tone must never exceed full scale.
        let dsp = BassDSP()
        dsp.configure(EQSettings(bassDB: 12, frequency: 100, mode: .shelf, lowCut: false), sampleRate: fs)
        let n = 4410
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        for i in 0..<n { let v = Float(0.9 * sin(2 * .pi * 60 * Double(i) / fs)); buf[2*i] = v; buf[2*i+1] = v }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        let il = AudioBufferList.allocate(maximumBuffers: 1)
        il[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: buf)
        let ol = AudioBufferList.allocate(maximumBuffers: 1)
        ol[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: out)
        dsp.process(input: il, output: ol)
        var peak: Float = 0
        for i in 0..<n * 2 { peak = max(peak, abs(out[i])) }
        let limOK = peak <= 1.0
        if !limOK { failures += 1 }
        print(String(format: "%@ limiter: +12 dB boost on 0.9 peak tone -> output peak %.3f", limOK ? "PASS" : "FAIL", peak))
        print(failures == 0 ? "All self tests passed" : "\(failures) self test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
