// =============================================================================
// SINYALIST — iOS Seismic Engine (CoreMotion port of C++ NDK v2.1)
// =============================================================================
// Direct port of seismic_detector.hpp to Swift + CoreMotion.
// Algorithm is identical to the C++ version:
//   • 50 Hz accelerometer sampling via CMMotionManager
//   • Band-pass IIR filter: 1–15 Hz (2-pole Butterworth, cascaded biquad)
//   • Gravity subtraction (0.1 Hz low-pass → orientation-independent)
//   • STA/LTA detection with adaptive threshold (calibration window)
//   • 4-stage false-positive rejection:
//       1. Axis coherence (single-axis drops/bumps)
//       2. Frequency band (outside 1–15 Hz P-wave range)
//       3. Periodicity autocorrelation (walking ~1.5–2.5 Hz)
//       4. Energy distribution (single-axis mechanical vibration)
//   • FlutterStreamHandler: events pushed to Dart EventChannel
// =============================================================================

import Foundation
import CoreMotion
import Flutter

// MARK: - Ring Buffer

private class Ring {
    private var buf: [Float]
    private var head: Int = 0
    private var count: Int = 0
    private let capacity: Int
    private var sum: Double = 0
    private var sumSq: Double = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buf = Array(repeating: 0, count: capacity)
    }

    func push(_ v: Float) {
        let fv = Double(v)
        if count == capacity {
            let old = Double(buf[head])
            sum -= old; sumSq -= old * old
        } else {
            count += 1
        }
        buf[head] = v
        sum += fv; sumSq += fv * fv
        head = (head + 1) % capacity
    }

    var avg: Float { count > 0 ? Float(sum / Double(count)) : 0 }

    var variance: Float {
        guard count >= 2 else { return 0 }
        let m = sum / Double(count)
        let v = sumSq / Double(count) - m * m
        return Float(max(0, v))
    }

    var isFull: Bool { count == capacity }
    var size: Int { count }

    func at(_ i: Int) -> Float {
        guard i < count else { return 0 }
        return buf[(head + capacity - count + i) % capacity]
    }

    func reset() {
        head = 0; count = 0; sum = 0; sumSq = 0
        buf = Array(repeating: 0, count: capacity)
    }
}

// MARK: - Biquad IIR Section (Direct Form II Transposed)

private struct Biquad {
    let b0, b1, b2, a1, a2: Float
    var w1: Float = 0
    var w2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + w1
        w1 = b1 * x - a1 * y + w2
        w2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { w1 = 0; w2 = 0 }
}

// MARK: - Band-pass filter: 1–15 Hz @ 50 Hz Fs
// Same pre-computed coefficients as C++ seismic_detector.hpp

private struct BandPassFilter {
    // High-pass section: 1 Hz cutoff, 50 Hz Fs (2-pole Butterworth)
    var hp = Biquad(b0: 0.9429, b1: -1.8858, b2: 0.9429, a1: -1.8805, a2: 0.8853)
    // Low-pass section: 15 Hz cutoff, 50 Hz Fs (2-pole Butterworth)
    var lp = Biquad(b0: 0.2929, b1:  0.5858, b2: 0.2929, a1:  0.0000, a2: 0.1716)

    mutating func process(_ x: Float) -> Float { lp.process(hp.process(x)) }
    mutating func reset() { hp.reset(); lp.reset() }
}

// MARK: - Legacy high-pass (DC removal, alpha=0.98 → ~0.16 Hz)

private struct HighPassState {
    var prevRaw: Float = 0
    var prevFilt: Float = 0

    mutating func process(_ raw: Float, _ alpha: Float) -> Float {
        let f = alpha * (prevFilt + raw - prevRaw)
        prevRaw = raw; prevFilt = f; return f
    }

    mutating func reset() { prevRaw = 0; prevFilt = 0 }
}

// MARK: - Gravity Estimator (0.1 Hz low-pass, alpha ≈ 0.01245)

private struct GravityEstimator {
    private static let alpha: Float = 0.01245
    var gx: Float = 0; var gy: Float = 0; var gz: Float = -1.0

    mutating func update(_ ax: Float, _ ay: Float, _ az: Float) {
        let a = GravityEstimator.alpha
        gx += a * (ax - gx); gy += a * (ay - gy); gz += a * (az - gz)
    }

    func linX(_ ax: Float) -> Float { ax - gx }
    func linY(_ ay: Float) -> Float { ay - gy }
    func linZ(_ az: Float) -> Float { az - gz }

    mutating func reset() { gx = 0; gy = 0; gz = -1.0 }
}

// MARK: - Detector State

private enum DetectorState { case idle, confirm, triggered }

// MARK: - Alert Level

enum SeismicAlertLevel: Int {
    case none = 0, tremor = 1, moderate = 2, severe = 3, critical = 4

    static func from(peakG: Float) -> SeismicAlertLevel {
        if peakG >= 0.40 { return .critical }
        if peakG >= 0.15 { return .severe }
        if peakG >= 0.05 { return .moderate }
        if peakG >= 0.01 { return .tremor }
        return .none
    }
}

// MARK: - SinyalistSeismicEngine

class SinyalistSeismicEngine: NSObject, FlutterStreamHandler {

    // Configuration (matches C++ Config defaults)
    private let sampleRateHz: Float     = 50.0
    private let hpAlpha: Float          = 0.98
    private let staWindow               = 25       // 0.5 s
    private let ltaWindow               = 500      // 10 s
    private let baseTrigger: Float      = 4.5
    private let detrigger: Float        = 1.5
    private let minAmplitudeG: Float    = 0.012
    private let minSustained            = 15       // 0.3 s
    private let axisCoherenceMin: Float = 0.4
    private let cooldownSamples         = 500      // 10 s
    private let pwaveFreqMin: Float     = 1.0
    private let pwaveFreqMax: Float     = 15.0
    private let calibWindow             = 2500     // 50 s
    private let periodicityWindow       = 200      // 4 * 50
    private let adaptiveTrigMin: Float  = 3.5
    private let adaptiveTrigMax: Float  = 8.0
    private let periodicityThresh: Float = 0.6

    // DSP state
    private var bpx = BandPassFilter(); private var bpy = BandPassFilter()
    private var bpz = BandPassFilter()
    private var hx = HighPassState(); private var hy = HighPassState()
    private var hz = HighPassState()
    private var grav = GravityEstimator()

    // Ring buffers
    private lazy var sta  = Ring(capacity: staWindow)
    private lazy var lta  = Ring(capacity: ltaWindow)
    private lazy var cal  = Ring(capacity: calibWindow)
    private lazy var per  = Ring(capacity: periodicityWindow)

    // Detector state machine
    private var state: DetectorState = .idle
    private var sustainCount: Int = 0
    private var durCount: Int = 0
    private var cooldown: Int = 0
    private var peakG: Float = 0
    private var eventTimeMs: Int64 = 0
    private var prevSignPositive: Bool = false
    private var zeroCrossings: Int = 0
    private var apPeak: [Float] = [0, 0, 0]    // peak amplitude per axis
    private var aeSum: [Float] = [0, 0, 0]     // energy sum per axis
    private var totalSamples: Int64 = 0

    // CoreMotion
    private let motionManager = CMMotionManager()
    private let motionQueue   = OperationQueue()
    private(set) var isRunning = false

    // Flutter EventChannel sink (thread-safe via main queue dispatch)
    private var eventSink: FlutterEventSink?
    private let lock = NSLock()

    // MARK: - Flutter StreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock(); defer { lock.unlock() }
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock(); defer { lock.unlock() }
        eventSink = nil
        return nil
    }

    // MARK: - Lifecycle

    func initialize() {
        motionQueue.name = "com.sinyalist.seismic"
        motionQueue.qualityOfService = .userInteractive
        print("[SeismicEngine] Initialized (50 Hz CoreMotion)")
    }

    func start() {
        guard !isRunning else { return }
        guard motionManager.isAccelerometerAvailable else {
            print("[SeismicEngine] Accelerometer not available")
            return
        }

        motionManager.accelerometerUpdateInterval = 1.0 / Double(sampleRateHz)
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            // iOS CMAcceleration is already in g-units — no division needed
            let ax = Float(data.acceleration.x)
            let ay = Float(data.acceleration.y)
            let az = Float(data.acceleration.z)
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            self.processSample(ax: ax, ay: ay, az: az, timestampMs: ts)
        }

        isRunning = true
        print("[SeismicEngine] Accelerometer started at \(Int(sampleRateHz)) Hz")
    }

    func stop() {
        guard isRunning else { return }
        motionManager.stopAccelerometerUpdates()
        isRunning = false
        print("[SeismicEngine] Accelerometer stopped")
    }

    func reset() {
        bpx.reset(); bpy.reset(); bpz.reset()
        hx.reset(); hy.reset(); hz.reset()
        grav.reset()
        sta.reset(); lta.reset(); cal.reset(); per.reset()
        resetStateMachine()
        totalSamples = 0
        print("[SeismicEngine] Reset")
    }

    // MARK: - Sample Processing (ported from C++ seismic_detector.hpp)

    private func processSample(ax axRaw: Float, ay ayRaw: Float, az azRaw: Float, timestampMs ts: Int64) {
        totalSamples += 1
        if cooldown > 0 { cooldown -= 1; return }

        // B2: subtract gravity → body (linear) acceleration
        grav.update(axRaw, ayRaw, azRaw)
        let lx = grav.linX(axRaw)
        let ly = grav.linY(ayRaw)
        let lz = grav.linZ(azRaw)

        // B1: band-pass 1–15 Hz
        var ax = bpx.process(lx)
        var ay = bpy.process(ly)
        var az = bpz.process(lz)

        // Legacy high-pass for extra DC rejection
        ax = hx.process(ax, hpAlpha)
        ay = hy.process(ay, hpAlpha)
        az = hz.process(az, hpAlpha)

        let mag = (ax*ax + ay*ay + az*az).squareRoot()

        sta.push(mag); lta.push(mag); cal.push(mag); per.push(mag)
        guard lta.isFull else { return }

        let s = sta.avg; let l = lta.avg
        let bv = cal.variance
        let adaptiveTrig = min(adaptiveTrigMax, max(adaptiveTrigMin, baseTrigger + bv.squareRoot() * 100))

        guard l >= minAmplitudeG else { return }
        let ratio = s / l

        switch state {
        case .idle:
            if ratio >= adaptiveTrig {
                state = .confirm
                sustainCount = 1
                peakG = mag
                eventTimeMs = ts
                zeroCrossings = 0
                prevSignPositive = ax >= 0
                apPeak = [abs(ax), abs(ay), abs(az)]
                aeSum = [ax*ax, ay*ay, az*az]
            }

        case .confirm:
            if ratio >= adaptiveTrig {
                sustainCount += 1
                peakG = max(peakG, mag)
                apPeak[0] = max(apPeak[0], abs(ax))
                apPeak[1] = max(apPeak[1], abs(ay))
                apPeak[2] = max(apPeak[2], abs(az))
                aeSum[0] += ax*ax; aeSum[1] += ay*ay; aeSum[2] += az*az
                let sg = ax >= 0
                if sg != prevSignPositive { zeroCrossings += 1 }
                prevSignPositive = sg

                if sustainCount >= minSustained {
                    if let _ = checkReject() {
                        state = .idle; cooldown = cooldownSamples
                    } else {
                        state = .triggered
                        durCount = sustainCount
                        fireEvent(ts: ts, ratio: ratio)
                    }
                }
            } else {
                state = .idle
            }

        case .triggered:
            durCount += 1
            peakG = max(peakG, mag)
            if ratio < detrigger {
                fireEvent(ts: ts, ratio: ratio)
                resetStateMachine()
            }
        }
    }

    // MARK: - Rejection Checks

    private enum RejectReason { case axisCoherence, frequency, periodicity, energyDist }

    private func checkReject() -> RejectReason? {
        // 1. Axis coherence
        let mx = max(apPeak[0], max(apPeak[1], apPeak[2]))
        let mn = min(apPeak[0], min(apPeak[1], apPeak[2]))
        if mx > 0 && (mn / mx) < axisCoherenceMin { return .axisCoherence }

        // 2. Frequency band
        let ds = Float(sustainCount) / sampleRateHz
        if ds > 0 {
            let freq = Float(zeroCrossings) / (2.0 * ds)
            if freq < pwaveFreqMin || freq > pwaveFreqMax { return .frequency }
        }

        // 3. Periodicity (walking pattern)
        if per.isFull && autocorr() > periodicityThresh { return .periodicity }

        // 4. Energy distribution
        let totalEnergy = aeSum[0] + aeSum[1] + aeSum[2]
        if totalEnergy > 0 {
            let maxEnergy = max(aeSum[0], max(aeSum[1], aeSum[2]))
            if (maxEnergy / totalEnergy) > 0.85 { return .energyDist }
        }

        return nil
    }

    // Autocorrelation over the periodicity ring buffer.
    // Detects repetitive patterns in the 1.5–2.5 Hz walking frequency band.
    private func autocorr() -> Float {
        let n = per.size
        guard n >= 60 else { return 0 }

        var mean: Float = 0
        for i in 0..<n { mean += per.at(i) }
        mean /= Float(n)

        var variance: Float = 0
        for i in 0..<n { let d = per.at(i) - mean; variance += d * d }
        guard variance > 1e-10 else { return 0 }

        let lag0 = Int(sampleRateHz / 2.5)
        let lag1 = Int(sampleRateHz / 1.5)
        var best: Float = 0

        for lag in lag0...min(lag1, n/2 - 1) {
            var c: Float = 0
            for i in 0..<(n - lag) {
                c += (per.at(i) - mean) * (per.at(i + lag) - mean)
            }
            best = max(best, c / variance)
        }
        return best
    }

    // MARK: - Event Emission

    private func fireEvent(ts: Int64, ratio: Float) {
        let level = SeismicAlertLevel.from(peakG: peakG)
        let ds = Float(sustainCount) / sampleRateHz
        let freq: Float = ds > 0 ? Float(zeroCrossings) / (2.0 * ds) : 0

        let event: [String: Any] = [
            "level":            level.rawValue,
            "peakG":            peakG,
            "staLtaRatio":      ratio,
            "dominantFreq":     freq,
            "detectionTimeMs":  ts,
            "durationSamples":  durCount,
        ]

        DispatchQueue.main.async { [weak self] in
            self?.lock.lock(); defer { self?.lock.unlock() }
            self?.eventSink?(event)
        }

        print("[SeismicEngine] EVENT level=\(level.rawValue) peakG=\(String(format: "%.4f", peakG))g freq=\(String(format: "%.1f", freq))Hz")
    }

    // MARK: - Helpers

    private func resetStateMachine() {
        state = .idle; sustainCount = 0; durCount = 0
        peakG = 0; eventTimeMs = 0; zeroCrossings = 0
        prevSignPositive = false
        apPeak = [0, 0, 0]; aeSum = [0, 0, 0]
        cooldown = cooldownSamples
    }
}
