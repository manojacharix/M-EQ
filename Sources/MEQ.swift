// M-EQ: a menu-bar equalizer for Bluetooth speakers.
//
// How it works (no audio driver needed, macOS 14.4+):
//   1. A global Core Audio process tap captures everything the system plays and
//      mutes the original ("mutedWhenTapped"), excluding this app itself.
//   2. A private aggregate device pairs that tap (input) with the speaker (output).
//   3. An IOProc on the aggregate runs the audio through the EQ filters and
//      writes it straight to the speaker.
// The EQ engages whenever the default output is a Bluetooth device (or any output,
// if enabled) and keeps separate settings per device. Quit the app (or toggle it
// off) and audio flows exactly as before.
//
// Features are modelled on the Sony Headphones Connect and Nothing X apps:
// Simple (Lows/Mids/Highs) and Advanced (10-band graphic) modes, a separate bass
// boost control, style presets and savable custom presets.

import SwiftUI
import CoreAudio
import AudioToolbox
import os

/// Appends a timestamped line to ~/Library/Logs/M-EQ.log (status changes only, so it stays small).
func appLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/M-EQ.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

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

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = (try? readValue(id, kAudioDevicePropertyTransportType, UInt32(0))) ?? 0
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
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

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = Biquad()

    /// Filters at or above ~Nyquist are meaningless (e.g. 16 kHz band while a
    /// Bluetooth speaker is in 16 kHz call mode), so they pass audio through.
    private static func usable(_ f0: Double, _ fs: Double) -> Bool { f0 > 0 && f0 < fs * 0.45 }

    // RBJ Audio EQ Cookbook formulas, normalised by a0. Shelves use slope S = 1.
    static func lowShelf(fs: Double, f0: Double, gainDB: Double) -> Biquad {
        guard usable(f0, fs), gainDB != 0 else { return identity }
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs
        let c = cos(w), alpha = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * alpha
        let a0 = (A + 1) + (A - 1) * c + sA
        return Biquad(b0: A * ((A + 1) - (A - 1) * c + sA) / a0,
                      b1: 2 * A * ((A - 1) - (A + 1) * c) / a0,
                      b2: A * ((A + 1) - (A - 1) * c - sA) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * c) / a0,
                      a2: ((A + 1) + (A - 1) * c - sA) / a0)
    }

    static func highShelf(fs: Double, f0: Double, gainDB: Double) -> Biquad {
        guard usable(f0, fs), gainDB != 0 else { return identity }
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs
        let c = cos(w), alpha = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * c + sA
        return Biquad(b0: A * ((A + 1) + (A - 1) * c + sA) / a0,
                      b1: -2 * A * ((A - 1) + (A + 1) * c) / a0,
                      b2: A * ((A + 1) + (A - 1) * c - sA) / a0,
                      a1: 2 * ((A - 1) - (A + 1) * c) / a0,
                      a2: ((A + 1) - (A - 1) * c - sA) / a0)
    }

    static func peaking(fs: Double, f0: Double, gainDB: Double, q: Double) -> Biquad {
        guard usable(f0, fs), gainDB != 0 else { return identity }
        let A = pow(10, gainDB / 40), w = 2 * .pi * f0 / fs
        let c = cos(w), alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0, b1: -2 * c / a0, b2: (1 - alpha * A) / a0,
                      a1: -2 * c / a0, a2: (1 - alpha / A) / a0)
    }

    static func highPass(fs: Double, f0: Double) -> Biquad {
        guard usable(f0, fs) else { return identity }
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

// MARK: - EQ model

enum EQMode: String, Codable, CaseIterable, Identifiable {
    case simple = "Simple", advanced = "Advanced"
    var id: String { rawValue }
}

enum BassShape: String, Codable, CaseIterable, Identifiable {
    case shelf = "Shelf", punch = "Punch"
    var id: String { rawValue }
}

/// Octave-spaced bands, same layout as Sony's 10-band equalizer.
let graphicBands: [Double] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

/// Everything one device remembers.
struct EQProfile: Codable, Equatable {
    var mode = EQMode.simple
    // Simple mode (Nothing-style tone controls)
    var lows = 0.0, mids = 0.0, highs = 0.0
    // Advanced mode (10-band graphic)
    var bands = Array(repeating: 0.0, count: graphicBands.count)
    // Bass boost, independent of the EQ curve (like Sony Clear Bass / Nothing Bass Enhance)
    var bassBoost = 0.0
    var bassFreq = 90.0
    var bassShape = BassShape.shelf
    var lowCut = true
    var trim = 0.0

    static let lowCutHz = 40.0
    static let lowsHz = 150.0, midsHz = 1000.0, highsHz = 5000.0
    /// Fixed filter layout so filter state stays attached to the same filter as settings change:
    /// 0-9 graphic bands, 10-12 lows/mids/highs, 13 bass boost, 14 low cut.
    static let filterCount = 15

    func filters(fs: Double) -> [Biquad] {
        var f = [Biquad](repeating: .identity, count: Self.filterCount)
        switch mode {
        case .advanced:
            for (i, hz) in graphicBands.enumerated() {
                f[i] = .peaking(fs: fs, f0: hz, gainDB: bands[i], q: 1.4)
            }
        case .simple:
            f[10] = .lowShelf(fs: fs, f0: Self.lowsHz, gainDB: lows)
            f[11] = .peaking(fs: fs, f0: Self.midsHz, gainDB: mids, q: 0.7)
            f[12] = .highShelf(fs: fs, f0: Self.highsHz, gainDB: highs)
        }
        f[13] = bassShape == .shelf
            ? .lowShelf(fs: fs, f0: bassFreq, gainDB: bassBoost)
            : .peaking(fs: fs, f0: bassFreq, gainDB: bassBoost, q: 1.0)
        if lowCut { f[14] = .highPass(fs: fs, f0: Self.lowCutHz) }
        return f
    }

    static func responseDB(_ filters: [Biquad], trim: Double, at f: Double, fs: Double) -> Double {
        filters.reduce(trim) { $0 + $1.magnitudeDB(at: f, fs: fs) }
    }

    func responseDB(at f: Double, fs: Double = 48000) -> Double {
        Self.responseDB(filters(fs: fs), trim: trim, at: f, fs: fs)
    }
}

struct EQPreset: Codable, Identifiable, Equatable {
    var name: String
    var bands: [Double]
    var lows: Double, mids: Double, highs: Double
    /// Custom presets also store bass boost (like Sony's Custom slots); built-ins leave it alone.
    var bassBoost: Double?
    var isCustom = false
    var id: String { (isCustom ? "custom:" : "") + name }

    /// Built-in preset defined as a 10-band curve; the Simple-mode equivalent is derived from it.
    init(_ name: String, _ bands: [Double]) {
        func avg(_ r: Range<Int>) -> Double { (bands[r].reduce(0, +) / Double(r.count) * 2).rounded() / 2 }
        self.name = name
        self.bands = bands
        lows = avg(0..<3); mids = avg(4..<7); highs = avg(8..<10)
    }

    init(custom name: String, from p: EQProfile) {
        self.name = name
        bands = p.bands; lows = p.lows; mids = p.mids; highs = p.highs
        bassBoost = p.bassBoost
        isCustom = true
    }

    func apply(to p: inout EQProfile) {
        p.bands = bands; p.lows = lows; p.mids = mids; p.highs = highs
        if let bassBoost { p.bassBoost = bassBoost }
    }

    func matches(_ p: EQProfile) -> Bool {
        let tone = p.mode == .advanced ? p.bands == bands : (p.lows, p.mids, p.highs) == (lows, mids, highs)
        return tone && (bassBoost == nil || bassBoost == p.bassBoost)
    }

    //                                   31  63 125 250 500  1k  2k  4k  8k 16k
    static let builtIn: [EQPreset] = [
        EQPreset("Balanced",     [ 0,  0,  0,  0,  0,  0,  0,  0,  0,  0]),
        EQPreset("More Bass",    [ 4,  4,  3,  1,  0,  0,  0,  0,  0,  0]),
        EQPreset("Bass Boost",   [ 7,  6,  5,  3,  1,  0,  0,  0,  0,  0]),
        EQPreset("More Treble",  [ 0,  0,  0,  0,  0,  0,  1,  2,  3,  4]),
        EQPreset("Treble Boost", [ 0,  0,  0,  0,  0,  0,  2,  4,  6,  6]),
        EQPreset("Bright",       [ 0,  0, -1, -1,  0,  1,  2,  3,  4,  4]),
        EQPreset("Excited",      [ 4,  4,  2,  0, -2, -2,  0,  2,  4,  4]),
        EQPreset("Mellow",       [ 3,  3,  2,  1,  0, -1, -2, -3, -4, -4]),
        EQPreset("Relaxed",      [ 2,  2,  1,  0, -1, -2, -2, -2, -3, -4]),
        EQPreset("Vocal",        [-2, -2, -1,  0,  2,  3,  3,  2,  0, -1]),
        EQPreset("Speech",       [-6, -5, -3,  0,  2,  4,  4,  3,  0, -2]),
        EQPreset("Loudness",     [ 5,  4,  3,  1,  0, -1,  0,  1,  3,  4]),
    ]
}

// MARK: - Real-time processor

/// Called on the Core Audio IO thread; never allocates or blocks. The UI thread
/// publishes new coefficients under a lock that the IO thread only *tries* to take,
/// so a busy lock just means the next buffer picks up the change.
final class EQDSP: @unchecked Sendable {
    private static let maxChannels = 16
    private static let n = EQProfile.filterCount
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let pending = UnsafeMutablePointer<Biquad>.allocate(capacity: n)
    private let active = UnsafeMutablePointer<Biquad>.allocate(capacity: n)
    private var pendingTrim: Double = 1, trim: Double = 1, dirty = false
    // Per channel, per filter: z1, z2 (transposed direct form II).
    private let state = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * n * 2)
    /// Peak input level since the UI last read it (diagnostic: 0 means the tap delivers silence).
    var inputPeak: Float = 0

    init() {
        lock.initialize(to: os_unfair_lock())
        pending.initialize(repeating: .identity, count: Self.n)
        active.initialize(repeating: .identity, count: Self.n)
        state.initialize(repeating: 0, count: Self.maxChannels * Self.n * 2)
    }

    deinit {
        lock.deallocate(); pending.deallocate(); active.deallocate(); state.deallocate()
    }

    func configure(_ p: EQProfile, sampleRate fs: Double) {
        let f = p.filters(fs: fs)
        os_unfair_lock_lock(lock)
        for i in 0..<Self.n { pending[i] = f[i] }
        pendingTrim = pow(10, p.trim / 20)
        dirty = true
        os_unfair_lock_unlock(lock)
    }

    func reset() { state.update(repeating: 0, count: Self.maxChannels * Self.n * 2) }

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
        if os_unfair_lock_trylock(lock) {
            if dirty {
                active.update(from: pending, count: Self.n)
                trim = pendingTrim
                dirty = false
            }
            os_unfair_lock_unlock(lock)
        }
        let n = Self.n, gain = trim
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
                let st = state + channel * n * 2
                let frames = min(inFrames, outFrames)
                var peak = inputPeak
                for f in 0..<frames {
                    let sample = src[f * stride]
                    peak = max(peak, abs(sample))
                    var x = Double(sample)
                    for k in 0..<n {
                        let q = active[k], z = st + 2 * k
                        let y = q.b0 * x + z[0]
                        z[0] = q.b1 * x - q.a1 * y + z[1]
                        z[1] = q.b2 * x - q.a2 * y
                        x = y
                    }
                    var y = x * gain
                    // Soft limiter above 0.85 so boosts never hard-clip.
                    let a = abs(y)
                    if a > 0.85 { y = (y < 0 ? -1 : 1) * (0.85 + 0.15 * tanh((a - 0.85) / 0.15)) }
                    o[f * oc] = Float(y)
                }
                if frames < outFrames { for f in frames..<outFrames { o[f * oc] = 0 } }
                inputPeak = peak
            }
        }
    }
}

// MARK: - Engine

@MainActor
final class EQEngine: ObservableObject {
    @Published var profile = EQProfile() { didSet { profileChanged() } }
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); reconcile() } }
    @Published var allOutputs: Bool { didSet { defaults.set(allOutputs, forKey: "allOutputs"); reconcile() } }
    @Published private(set) var deviceName: String?
    @Published private(set) var userPresets: [EQPreset] = []
    @Published private(set) var status = "Starting…" { didSet { appLog("status: \(deviceName ?? "-") · \(status)") } }
    @Published private(set) var running = false
    @Published private(set) var level: Float = 0

    private let defaults = UserDefaults.standard
    private let dsp = EQDSP()
    private let ioQueue = DispatchQueue(label: "meq.io", qos: .userInteractive)
    private var profiles: [String: EQProfile] = [:]
    private var currentUID: String?
    private var runningDevice = AudioDeviceID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate = 44100.0
    private var reconcilePending = false
    private var everHeardAudio = false

    init() {
        Self.migrateFromBassEQ(into: defaults)
        defaults.register(defaults: ["enabled": true, "allOutputs": false])
        enabled = defaults.bool(forKey: "enabled")
        allOutputs = defaults.bool(forKey: "allOutputs")
        profiles = load([String: EQProfile].self, "profiles") ?? [:]
        userPresets = load([EQPreset].self, "userPresets") ?? []
        if let uid = defaults.string(forKey: "lastUID"), let p = profiles[uid] {
            profile = p
            currentUID = uid
            deviceName = defaults.string(forKey: "lastName")
        }
        dsp.configure(profile, sampleRate: sampleRate)

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

    // MARK: Persistence

    /// The app used to be called Bass EQ (com.manojachari.basseq). Copy its settings once so
    /// per-device profiles and custom presets survive the rename.
    private static func migrateFromBassEQ(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: "migratedFromBassEQ") else { return }
        defaults.set(true, forKey: "migratedFromBassEQ")
        guard defaults.object(forKey: "profiles") == nil,
              let old = UserDefaults(suiteName: "com.manojachari.basseq") else { return }
        let keys = ["enabled", "allOutputs", "profiles", "userPresets", "lastUID", "lastName",
                    "targetName", "bassDB", "frequency", "mode", "lowCut"]
        for key in keys { if let value = old.object(forKey: key) { defaults.set(value, forKey: key) } }
        appLog("migrated settings from Bass EQ")
    }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func profileChanged() {
        if let uid = currentUID {
            profiles[uid] = profile
            save(profiles, "profiles")
        }
        dsp.configure(profile, sampleRate: sampleRate)
    }

    /// New devices start flat, except the speaker this app was first built for keeps
    /// the bass settings from the earlier bass-only version.
    private func newProfile(for name: String) -> EQProfile {
        var p = EQProfile()
        if name == (defaults.string(forKey: "targetName") ?? "SA-D40M2"), defaults.object(forKey: "bassDB") != nil {
            p.bassBoost = defaults.double(forKey: "bassDB")
            p.bassFreq = defaults.double(forKey: "frequency")
            p.bassShape = BassShape(rawValue: defaults.string(forKey: "mode") ?? "") ?? .shelf
            p.lowCut = defaults.bool(forKey: "lowCut")
        }
        return p
    }

    private func selectDevice(uid: String, name: String) {
        guard uid != currentUID else { deviceName = name; return }
        currentUID = nil                       // don't write the old profile under the new device
        profile = profiles[uid] ?? newProfile(for: name)
        currentUID = uid
        profiles[uid] = profile
        save(profiles, "profiles")
        deviceName = name
        defaults.set(uid, forKey: "lastUID")
        defaults.set(name, forKey: "lastName")
    }

    // MARK: Presets

    func apply(_ preset: EQPreset) { preset.apply(to: &profile) }

    func saveCustomPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        userPresets.removeAll { $0.name == trimmed }
        userPresets.append(EQPreset(custom: trimmed, from: profile))
        save(userPresets, "userPresets")
    }

    func deleteCustomPreset(_ preset: EQPreset) {
        userPresets.removeAll { $0.id == preset.id }
        save(userPresets, "userPresets")
    }

    func resetProfile() {
        let keep = (profile.mode, profile.lowCut)
        profile = EQProfile()
        (profile.mode, profile.lowCut) = keep
    }

    // MARK: Device tracking

    private func pollLevel() {
        let peak = dsp.inputPeak
        dsp.inputPeak = 0
        level = running ? max(peak, level * 0.8) : 0
        if running && peak > 0.001 && !everHeardAudio {
            everHeardAudio = true
            appLog(String(format: "receiving system audio (peak %.3f)", peak))
        }
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
        let device = defaultOutputDevice()
        guard enabled else { stop(); status = "Off"; return }
        guard device != kAudioObjectUnknown,
              let uid = readString(device, kAudioDevicePropertyDeviceUID) else {
            stop(); status = "No output device"; return
        }
        let name = readString(device, kAudioObjectPropertyName) ?? "Output"
        guard allOutputs || isBluetooth(device) else {
            stop(); status = "Waiting for a Bluetooth speaker (now: \(name))"; return
        }
        if running && runningDevice == device { return }

        stop()
        selectDevice(uid: uid, name: name)
        do {
            try start(device: device, uid: uid)
            status = "Active · \(Int(sampleRate)) Hz"
        } catch {
            stop()
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    private func start(device: AudioDeviceID, uid deviceUID: String) throws {
        let me = ownProcessObject()
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        tap.uuid = UUID()
        tap.name = "M-EQ Tap"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create system audio tap")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "M-EQ",
            kAudioAggregateDeviceUIDKey: "meq-\(UUID().uuidString)",
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
        dsp.configure(profile, sampleRate: sampleRate)

        // Bluetooth speakers can change rate (e.g. when a call grabs the mic); retune if so.
        let agg = aggID
        var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(agg, &rateAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.aggID == agg,
                      let r = try? readValue(agg, kAudioDevicePropertyNominalSampleRate, Float64(0)), r > 0
                else { return }
                self.sampleRate = r
                self.dsp.configure(self.profile, sampleRate: r)
                self.status = "Active · \(Int(r)) Hz"
            }
        }

        let dsp = self.dsp
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inData, _, outData, _ in
            dsp.process(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                        output: UnsafeMutableAudioBufferListPointer(outData))
        }, "create IO proc")
        try check(AudioDeviceStart(aggID, procID), "start audio")
        runningDevice = device
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
        runningDevice = AudioDeviceID(kAudioObjectUnknown)
        running = false
    }
}

// MARK: - UI

func formatDB(_ v: Double) -> String {
    v == 0 ? "0" : String(format: v == v.rounded() ? "%+.0f" : "%+.1f", v)
}

func formatHz(_ f: Double) -> String {
    f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
}

struct ResponseCurve: View {
    let profile: EQProfile
    private let fMin = 20.0, fMax = 20000.0, dbRange = 15.0

    var body: some View {
        let fs = 48000.0, filters = profile.filters(fs: fs)
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / fMin) / log10(fMax / fMin)) * size.width }
            func y(_ db: Double) -> CGFloat {
                CGFloat((dbRange - max(-dbRange, min(dbRange, db))) / (2 * dbRange)) * size.height
            }

            var grid = Path()
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height))
            }
            for db in [-10.0, -5, 5, 10] {
                grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: size.width, y: y(db)))
            }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)

            var curve = Path(), fill = Path()
            fill.move(to: CGPoint(x: 0, y: y(0)))
            for i in 0...160 {
                let f = fMin * pow(fMax / fMin, Double(i) / 160)
                let p = CGPoint(x: x(f), y: y(EQProfile.responseDB(filters, trim: profile.trim, at: f, fs: fs)))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
                fill.addLine(to: p)
            }
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(.accentColor.opacity(0.15)))
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)

            for f in [50.0, 100, 500, 1000, 5000, 10000] {
                ctx.draw(Text(formatHz(f)).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: x(f), y: size.height - 6))
            }
            for db in [-10.0, 10] {
                ctx.draw(Text(formatDB(db)).font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: 10, y: y(db)))
            }
        }
        .frame(height: 100)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}

/// Vertical slider for the graphic EQ; the fill grows from 0 dB toward the knob.
struct VSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12
    var step = 0.5
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, inner = g.size.height - knob
            let span = range.upperBound - range.lowerBound
            let y = { (v: Double) in knob / 2 + CGFloat((range.upperBound - v) / span) * inner }
            let y0 = y(0), yv = y(value)
            ZStack {
                Capsule().fill(.quaternary).frame(width: 4, height: inner).position(x: w / 2, y: g.size.height / 2)
                Rectangle().fill(Color.accentColor).frame(width: 4, height: abs(yv - y0))
                    .position(x: w / 2, y: (y0 + yv) / 2)
                Circle().fill(.white).overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob).position(x: w / 2, y: yv)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let frac = 1 - min(max((d.location.y - knob / 2) / inner, 0), 1)
                value = ((range.lowerBound + Double(frac) * span) / step).rounded() * step
            })
        }
    }
}

struct GraphicEQ: View {
    @Binding var bands: [Double]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(graphicBands.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Text(formatDB(bands[i])).font(.system(size: 9).monospacedDigit())
                    VSlider(value: $bands[i]).frame(height: 120)
                    Text(formatHz(graphicBands[i])).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    var detail: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.5
    var unit = "dB"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(unit == "dB" ? "\(formatDB(value)) dB" : "\(Int(value)) \(unit)").monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct PresetChip: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct PanelView: View {
    @ObservedObject var engine: EQEngine
    @State private var bassTuning = false
    @State private var newPresetName: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ResponseCurve(profile: engine.profile)
            meter
            presets
            Picker("", selection: $engine.profile.mode) {
                ForEach(EQMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if engine.profile.mode == .simple {
                LabeledSlider(title: "Lows", detail: "below \(Int(EQProfile.lowsHz)) Hz",
                              value: $engine.profile.lows, range: -12...12)
                LabeledSlider(title: "Mids", detail: "around 1 kHz", value: $engine.profile.mids, range: -12...12)
                LabeledSlider(title: "Highs", detail: "above 5 kHz", value: $engine.profile.highs, range: -12...12)
            } else {
                GraphicEQ(bands: $engine.profile.bands)
            }

            Divider()
            LabeledSlider(title: "Bass Boost", detail: "\(Int(engine.profile.bassFreq)) Hz \(engine.profile.bassShape.rawValue.lowercased())",
                          value: $engine.profile.bassBoost, range: -10...10)
            DisclosureGroup("Bass tuning", isExpanded: $bassTuning) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledSlider(title: "Frequency", value: $engine.profile.bassFreq, range: 40...250, step: 5, unit: "Hz")
                    Picker("Shape", selection: $engine.profile.bassShape) {
                        ForEach(BassShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(engine.profile.bassShape == .shelf
                         ? "Shelf lifts everything below the frequency."
                         : "Punch boosts a band around the frequency (kick drum thump).")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("Low cut below 40 Hz (protects small drivers)", isOn: $engine.profile.lowCut)
                        .font(.caption)
                }
                .padding(.top, 6)
            }
            .font(.callout)
            LabeledSlider(title: "Output trim", detail: "lower it if heavy boosts distort",
                          value: $engine.profile.trim, range: -12...6)

            Divider()
            Toggle("EQ every output, not just Bluetooth", isOn: $engine.allOutputs).font(.caption)
            HStack {
                Button("Reset") { engine.resetProfile() }
                Spacer()
                Button("Quit") { engine.stop(); NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("M-EQ").font(.headline)
                    Text(engine.deviceName ?? "No speaker yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.enabled).toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: 6) {
                Circle().fill(engine.running ? .green : .orange).frame(width: 7, height: 7)
                Text(engine.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var meter: some View {
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
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(EQPreset.builtIn) { p in
                    PresetChip(title: p.name, active: p.matches(engine.profile)) { engine.apply(p) }
                }
                ForEach(engine.userPresets) { p in
                    PresetChip(title: "★ " + p.name, active: p.matches(engine.profile)) { engine.apply(p) }
                        .contextMenu { Button("Delete \"\(p.name)\"") { engine.deleteCustomPreset(p) } }
                }
                if newPresetName == nil {
                    PresetChip(title: "+ Save", active: false) {
                        newPresetName = "Custom \(engine.userPresets.count + 1)"
                    }
                }
            }
            if let name = newPresetName {
                HStack {
                    TextField("Preset name", text: Binding(get: { name }, set: { newPresetName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { engine.saveCustomPreset(named: name); newPresetName = nil }
                    Button("Save") { engine.saveCustomPreset(named: name); newPresetName = nil }
                    Button("Cancel") { newPresetName = nil }
                }
                .controlSize(.small)
            }
        }
    }
}

@main
struct MEQApp: App {
    @StateObject private var engine = EQEngine()

    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if CommandLine.arguments.contains("--devices") { SelfTest.listDevices() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(engine: engine)
        } label: {
            Image(systemName: engine.running ? "slider.vertical.3" : "speaker.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Self test (M-EQ.app/Contents/MacOS/M-EQ --selftest | --devices)

enum SelfTest {
    static func listDevices() -> Never {
        let def = defaultOutputDevice()
        for d in allDevices() {
            var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size)
            guard size > 0 else { continue }
            print("\(d == def ? "*" : " ") \(readString(d, kAudioObjectPropertyName) ?? "?")"
                  + (isBluetooth(d) ? "  [Bluetooth: EQ applies]" : ""))
        }
        exit(0)
    }

    /// Feeds sine waves through the real-time processor and compares measured gain
    /// with the analytic response curve.
    static func run() -> Never {
        var failures = 0
        func profile(_ edit: (inout EQProfile) -> Void) -> EQProfile {
            var p = EQProfile(); p.lowCut = false; edit(&p); return p
        }
        let cases: [(String, EQProfile, Double, Double)] = [
            ("flat passthrough", profile { _ in }, 1000, 44100),
            ("simple lows +6", profile { $0.lows = 6 }, 50, 44100),
            ("simple lows +6, no effect on highs", profile { $0.lows = 6 }, 8000, 44100),
            ("simple mids -6", profile { $0.mids = -6 }, 1000, 44100),
            ("simple highs +6", profile { $0.highs = 6 }, 12000, 44100),
            ("advanced 1k band +6", profile { $0.mode = .advanced; $0.bands[5] = 6 }, 1000, 44100),
            ("advanced 63 Hz band -8", profile { $0.mode = .advanced; $0.bands[1] = -8 }, 63, 44100),
            ("advanced ignores simple sliders", profile { $0.mode = .advanced; $0.highs = 9 }, 12000, 44100),
            ("bass boost +6 shelf", profile { $0.bassBoost = 6 }, 30, 44100),
            ("bass boost punch +6", profile { $0.bassBoost = 6; $0.bassShape = .punch; $0.bassFreq = 70 }, 70, 44100),
            ("low cut", profile { $0.lowCut = true }, 20, 44100),
            ("output trim -6", profile { $0.trim = -6 }, 1000, 44100),
            ("Bright preset", profile { EQPreset.builtIn[5].apply(to: &$0); $0.mode = .advanced }, 8000, 44100),
            ("16 kHz band at 16 kHz call rate", profile { $0.mode = .advanced; $0.bands[9] = 6 }, 1000, 16000),
        ]
        for (label, p, f, fs) in cases {
            let dsp = EQDSP()
            dsp.configure(p, sampleRate: fs)
            let frames = Int(fs), amp: Float = 0.05
            let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames {
                let v = amp * Float(sin(2 * .pi * f * Double(i) / fs))
                inBuf[2 * i] = v; inBuf[2 * i + 1] = v
            }
            let outL = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let outR = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let inList = AudioBufferList.allocate(maximumBuffers: 1)
            inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: inBuf)
            // Output as two non-interleaved buffers to exercise channel mapping.
            let outList = AudioBufferList.allocate(maximumBuffers: 2)
            outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outL)
            outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outR)
            dsp.process(input: inList, output: outList)
            func rms(_ ptr: UnsafeMutablePointer<Float>, _ stride: Int) -> Double {
                var acc = 0.0
                for i in frames / 2..<frames { let v = Double(ptr[i * stride]); acc += v * v }
                return sqrt(acc / Double(frames / 2))
            }
            let measured = 20 * log10(rms(outL, 1) / rms(inBuf, 2))
            let right = 20 * log10(rms(outR, 1) / rms(inBuf, 2))
            let expected = p.responseDB(at: f, fs: fs)
            let ok = measured.isFinite && abs(measured - expected) < 0.3 && abs(right - measured) < 0.01
            if !ok { failures += 1 }
            print(String(format: "%@ %-36@ tone %5.0f Hz: measured %+6.2f dB, expected %+6.2f dB",
                         ok ? "PASS" : "FAIL", label, f, measured, expected))
        }

        // Every built-in preset must derive Simple sliders in step with the 10-band curve.
        let presetsOK = EQPreset.builtIn.allSatisfy { preset in
            var simple = EQProfile(), advanced = EQProfile()
            advanced.mode = .advanced
            preset.apply(to: &simple); preset.apply(to: &advanced)
            return preset.matches(simple) && preset.matches(advanced)
        }
        if !presetsOK { failures += 1 }
        print("\(presetsOK ? "PASS" : "FAIL") presets: \(EQPreset.builtIn.count) built-ins apply and re-match")

        // Limiter: a loud boosted tone must never exceed full scale.
        let dsp = EQDSP()
        dsp.configure(profile { $0.bassBoost = 10; $0.lows = 12 }, sampleRate: 44100)
        let n = 4410
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
        for i in 0..<n { let v = Float(0.9 * sin(2 * .pi * 60 * Double(i) / 44100)); buf[2*i] = v; buf[2*i+1] = v }
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
        print(String(format: "%@ limiter: +22 dB of boost on a 0.9 peak tone -> output peak %.3f",
                     limOK ? "PASS" : "FAIL", peak))
        print(failures == 0 ? "All self tests passed" : "\(failures) self test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
