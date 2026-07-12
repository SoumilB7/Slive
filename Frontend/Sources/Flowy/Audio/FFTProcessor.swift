import Accelerate
import Foundation

/// Turns a mono PCM buffer into a small set of normalised, log-spaced
/// frequency-band magnitudes — the numbers that drive the waveform bars.
///
/// Voice energy lives roughly between 80 Hz and 8 kHz, so we map the FFT
/// bins onto log-spaced bands across that range. Log spacing matters: linear
/// bands would cram all the perceptually-interesting speech energy into the
/// first couple of bars.
final class FFTProcessor {
    let bandCount: Int
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    // Reusable scratch buffers (avoid per-call allocation on the audio thread).
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    // Precomputed [startBin, endBin) ranges for each output band.
    private let bandRanges: [(Int, Int)]

    // Level-mapping dials for bar liveliness (see `process`). `gain` is raw
    // sensitivity; `shape` (<1) expands the low end so normal speech reads
    // ~30–40%. `ceiling` soft-caps the top: bars approach ~55% of the pill's
    // height even at loud input, instead of slamming the ceiling.
    private let gain: Float = 22000
    private let logRange: Float = 3.4
    private let shape: Float = 0.6
    private let ceiling: Float = 0.6

    init(fftSize: Int = 1024, bandCount: Int = 20, sampleRate: Double = 48_000) {
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Hann window smooths spectral leakage so the bars don't jitter.
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)

        // Build log-spaced band edges across the voice range.
        let minFreq = 80.0
        let maxFreq = min(8_000.0, sampleRate / 2.0)
        let binHz = sampleRate / Double(fftSize)
        var ranges: [(Int, Int)] = []
        ranges.reserveCapacity(bandCount)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let maxBin = fftSize / 2
        for b in 0..<bandCount {
            let f0 = pow(10, logMin + (logMax - logMin) * Double(b) / Double(bandCount))
            let f1 = pow(10, logMin + (logMax - logMin) * Double(b + 1) / Double(bandCount))
            var lo = Int((f0 / binHz).rounded(.down))
            var hi = Int((f1 / binHz).rounded(.up))
            lo = max(1, min(lo, maxBin - 1))
            hi = max(lo + 1, min(hi, maxBin))
            ranges.append((lo, hi))
        }
        self.bandRanges = ranges
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Compute band magnitudes (each ~0...1) from a mono sample buffer.
    /// `samples` may be any length; only the first `fftSize` are used
    /// (zero-padded if shorter).
    func process(_ samples: [Float]) -> [Float] {
        let n = fftSize
        // Copy input into the window buffer, zero-padding as needed, then window.
        let count = min(samples.count, n)
        samples.withUnsafeBufferPointer { src in
            windowed.withUnsafeMutableBufferPointer { dst in
                if count > 0 {
                    dst.baseAddress!.update(from: src.baseAddress!, count: count)
                }
                if count < n {
                    for i in count..<n { dst[i] = 0 }
                }
            }
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Pack the real signal into split-complex form and run the FFT.
        var bands = [Float](repeating: 0, count: bandCount)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { typeConverted in
                        vDSP_ctoz(typeConverted, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Reduce each band to a log-compressed, normalised level.
        for (i, range) in bandRanges.enumerated() {
            var sum: Float = 0
            for bin in range.0..<range.1 { sum += magnitudes[bin] }
            let mean = sum / Float(max(1, range.1 - range.0))
            // Log (dB-like) mapping, not linear — lifts quiet/normal speech.
            let raw = pow(min(1, log10(1 + mean * gain) / logRange), shape)
            // Soft-saturate toward `ceiling`: loud input approaches ~55% of the
            // pill height rather than clipping the top.
            bands[i] = ceiling * tanhf(raw / ceiling)
        }
        return bands
    }

    /// Root-mean-square loudness of the buffer (0...1-ish), for the halo glow.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var mean: Float = 0
        vDSP_measqv(samples, 1, &mean, vDSP_Length(samples.count))
        return sqrt(mean)
    }
}
