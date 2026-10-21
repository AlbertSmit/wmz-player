import Accelerate
import AppKit
import CoreAudio
import Foundation

/// Captures one player's audio with a CoreAudio process tap and publishes FFT
/// bands for the visualizer.
///
/// A process tap is the right tool here: it follows Apple Music / Spotify /
/// Tidal specifically (not every sound on the machine) and, unlike screen
/// capture, needs no Screen Recording permission.
public final class AudioSpectrum {
    public private(set) var isRunning = false
    public var onBands: (([Float]) -> Void)?

    private let bundleIdentifier: String
    private let bandCount: Int
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var description: CATapDescription?

    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 8192)
    private var writeIndex = 0
    private var channels = 2

    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var samples = [Float](repeating: 0, count: 1024)
    private var real = [Float](repeating: 0, count: 512)
    private var imag = [Float](repeating: 0, count: 512)
    private var magnitudes = [Float](repeating: 0, count: 512)
    private var overallPeak: Float = 0.3
    private var timer: Timer?

    public init(bundleIdentifier: String, bandCount: Int = 28) {
        self.bundleIdentifier = bundleIdentifier
        self.bandCount = bandCount
    }

    deinit {
        stop()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard #available(macOS 14.2, *) else { return false }
        guard let process = Self.audioProcess(bundleIdentifier: bundleIdentifier) else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        self.description = description

        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            NSLog("WMZPlayer: could not create an audio tap for %@", bundleIdentifier)
            return false
        }

        guard let outputUID = Self.defaultOutputUID() else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return false
        }
        // Clocking the aggregate from the real output device keeps the tap in
        // step with playback instead of drifting against it.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WMZPlayer Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1
            ]]
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
            return false
        }

        channels = Self.streamChannels(device: aggregateID) ?? 2
        prepareFFT()

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, input, _, _, _ in
            self?.capture(input)
        }
        guard status == noErr, let ioProcID else {
            teardown()
            return false
        }
        guard AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            teardown()
            return false
        }

        isRunning = true
        NSLog("WMZPlayer: audio tap started for %@", bundleIdentifier)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.analyse() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        teardown()
        isRunning = false
        lock.lock()
        ring = [Float](repeating: 0, count: ring.count)
        writeIndex = 0
        lock.unlock()
    }

    private func teardown() {
        if aggregateID != 0 {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
            ioProcID = nil
        }
        if tapID != 0 {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = 0
        }
    }

    // MARK: - Realtime capture

    private func capture(_ input: UnsafePointer<AudioBufferList>) {
        // The tap's stream follows any input streams of the output device.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let tap = buffers.last, let data = tap.mData else { return }
        let channelCount = max(1, Int(tap.mNumberChannels))
        let frames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
        guard frames > 0 else { return }
        let samples = data.bindMemory(to: Float.self, capacity: frames * channelCount)

        // Never block the realtime thread; a dropped buffer only costs the
        // visualizer one frame.
        guard lock.try() else { return }
        var index = writeIndex
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += samples[frame * channelCount + channel] }
            ring[index] = sum / Float(channelCount)
            index = (index + 1) % ring.count
        }
        writeIndex = index
        lock.unlock()
    }

    // MARK: - Analysis

    private func prepareFFT() {
        guard fftSetup == nil else { return }
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    private func analyse() {
        guard let fftSetup else { return }

        lock.lock()
        let end = writeIndex
        let start = (end - fftSize + ring.count) % ring.count
        for i in 0..<fftSize {
            samples[i] = ring[(start + i) % ring.count]
        }
        lock.unlock()

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                samples.withUnsafeBufferPointer { samplePointer in
                    samplePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Bands are log-spaced from ~40 Hz to ~16 kHz.
        let sampleRate = 48_000.0
        let minimum = 40.0
        let maximum = min(16_000.0, sampleRate / 2)
        var bands = [Float](repeating: 0, count: bandCount)
        let binWidth = sampleRate / Double(fftSize)
        for band in 0..<bandCount {
            let low = minimum * pow(maximum / minimum, Double(band) / Double(bandCount))
            let high = minimum * pow(maximum / minimum, Double(band + 1) / Double(bandCount))
            let firstBin = max(1, Int(low / binWidth))
            let lastBin = min(magnitudes.count - 1, max(firstBin, Int(high / binWidth)))
            var energy: Float = 0
            for bin in firstBin...lastBin { energy += magnitudes[bin] }
            // `magnitudes` holds squared magnitudes; the band average lands
            // around -35…-5 dB for normal music.
            // vDSP's magnitudes scale with (fftSize/2)²; normalise to a power
            // in 0…1 before converting to dBFS.
            let scale = Float(fftSize * fftSize / 4)
            let power = (energy / Float(lastBin - firstBin + 1)) / scale
            var decibels = 10 * log10(power + 1e-12)
            // Music rolls off towards the top; tilt the spectrum so the high
            // bars are not permanently pinned at zero.
            decibels += 18 * Float(band) / Float(max(bandCount - 1, 1))
            bands[band] = max(0, min(1, (decibels + 60) / 60))
        }

        // A slow gain lifts quiet passages; loud material keeps its dynamics.
        let loudest = bands.max() ?? 0
        overallPeak = max(loudest, overallPeak * 0.985)
        let gain: Float = overallPeak < 0.75 ? min(1.4, 0.75 / max(overallPeak, 0.25)) : 1
        if gain > 1 {
            for band in 0..<bandCount { bands[band] = min(1, bands[band] * gain) }
        }

        let result = bands
        DispatchQueue.main.async { [weak self] in self?.onBands?(result) }
    }

    // MARK: - CoreAudio lookups

    private static func audioProcess(bundleIdentifier: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &list) == noErr else {
            return nil
        }

        for object in list {
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  let application = NSRunningApplication(processIdentifier: pid),
                  let identifier = application.bundleIdentifier else { continue }
            if identifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
                return object
            }
        }
        return nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func streamChannels(device: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioDevicePropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0 ? channels : nil
    }
}
