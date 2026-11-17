import AppKit
import AVFoundation
import CoreAudio

/// Audio inputs and apps that play sound, for the recorder's pickers.
enum AudioSources {
    struct Device: Identifiable, Hashable {
        var id: AudioDeviceID
        var uid: String
        var name: String
    }

    /// An app that has audio processes (helpers included), by bundle id.
    struct App: Identifiable, Hashable {
        var id: String { bundleId }
        var bundleId: String
        var name: String
        var processes: [AudioObjectID]
    }

    static func inputDevices() -> [Device] {
        allDevices().filter { hasInput($0) }.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// Apps with audio process objects; helpers (Chrome, Zoom…) count under their app.
    static func apps() -> [App] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        var byApp: [String: App] = [:]
        for process in objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let bundle = string(process, kAudioProcessPropertyBundleID), !bundle.isEmpty,
                  bundle != Bundle.main.bundleIdentifier else { continue }
            guard let app = running.first(where: { bundle == $0.bundleIdentifier! || bundle.hasPrefix($0.bundleIdentifier! + ".") }) else { continue }
            let key = app.bundleIdentifier!
            byApp[key, default: App(bundleId: key, name: app.localizedName ?? key, processes: [])].processes.append(process)
        }
        return byApp.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultOutputUID() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    // MARK: Core Audio helpers

    private static func allDevices() -> [AudioDeviceID] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    }

    private static func objects(_ owner: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(owner, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(owner, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// One track's .m4a at a fixed rate. Whatever arrives (a Bluetooth headset drops to 16 kHz when its
/// microphone opens, at any moment) is converted, so the file never plays at the wrong speed.
final class TrackWriter {
    static let sampleRate = 48_000.0
    private let file: AVAudioFile
    private var converter: AVAudioConverter?
    private(set) var frames: Int64 = 0
    private(set) var problem: String?

    init(url: URL, channels: AVAudioChannelCount) throws {
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
                                                           AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels > 1 ? 128_000 : 64_000],
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let target = file.processingFormat
        do {
            if buffer.format == target {
                try file.write(from: buffer)
                frames += Int64(buffer.frameLength)
                return
            }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
                converter?.downmix = true
            }
            guard let converter else {
                if problem == nil { problem = "the sound came in a format that can't be converted (\(buffer.format))" }
                return
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if out.frameLength > 0 {
                try file.write(from: out)
                frames += Int64(out.frameLength)
            }
        } catch {
            if problem == nil { problem = "writing failed: \(error.localizedDescription)" }
        }
    }
}

/// The microphone (or another input) into an .m4a file.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?
    private var device: AudioDeviceID?
    private var observer: NSObjectProtocol?
    private let lock = NSLock()
    private var restartProblem: String?

    func start(device: AudioDeviceID?, to url: URL) throws {
        self.device = device
        writer = try TrackWriter(url: url, channels: 1)
        try configure()
        // A device change (a headset switching modes, a mic plugged in) stops the engine; start it again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.writer != nil else { return }
            do { try self.configure() } catch { self.lock.withLock { self.restartProblem = error.localizedDescription } }
        }
    }

    private func configure() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        if let device, let unit = input.audioUnit {
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw ClaudistAudioError("Could not use that microphone (\(status))") }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ClaudistAudioError("The microphone gives no sound — check access in System Settings → Privacy → Microphone") }
        // nil: the tap takes the bus's own format. A format read a moment earlier can already be stale
        // while a headset switches modes, and a mismatch raises an Objective-C exception that kills the app.
        // The writer converts whatever format arrives.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.withLock { self.writer?.write(buffer) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { writer = nil }
    }

    /// Why nothing was recorded, when nothing was; read before `stop`.
    var emptyReason: String? {
        lock.withLock {
            guard let writer, writer.frames == 0 else { return nil }
            return writer.problem ?? restartProblem ?? "no sound came from the microphone — check access in System Settings → Privacy & Security → Microphone"
        }
    }
}

/// Sound that apps play, through a Core Audio process tap (macOS 14.2+): one app's processes or the whole system.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private var scratch: UnsafeMutableAudioBufferListPointer?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "Claudist.SystemAudio", qos: .userInitiated)
    /// What arrived, for telling an empty recording apart from a silent one (written on `queue`).
    private(set) var callbacks = 0
    private(set) var problem: String?

    private static var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private static func nominalRate(_ device: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = rateAddress
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// `processes` empty = everything except Claudist.
    func start(processes: [AudioObjectID], to url: URL) throws {
        guard #available(macOS 14.2, *) else { throw ClaudistAudioError("Recording other apps needs macOS 14.2 or later") }
        let tap = processes.isEmpty ? CATapDescription(stereoGlobalTapButExcludeProcesses: []) : CATapDescription(stereoMixdownOfProcesses: processes)
        tap.uuid = UUID()
        tap.muteBehavior = .unmuted
        tap.isPrivate = true
        tap.name = "Claudist recording"
        var err = AudioHardwareCreateProcessTap(tap, &tapID)
        guard err == noErr else { throw ClaudistAudioError("Could not tap the sound (\(err)). Allow Claudist in System Settings → Privacy & Security → Screen & System Audio Recording.") }

        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description)
        guard err == noErr, description.mSampleRate > 0 else {
            stop()
            throw ClaudistAudioError("Could not read the sound format (\(err))")
        }

        guard let output = AudioSources.defaultOutputUID() else { stop(); throw ClaudistAudioError("No sound output device") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Claudist recording",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { stop(); throw ClaudistAudioError("Could not set up the recording device (\(err))") }

        let writer = try TrackWriter(url: url, channels: min(max(description.mChannelsPerFrame, 1), 2))
        self.writer = writer
        // Buffers come at the aggregate device's rate (its main device, the output), not the tap's:
        // a Bluetooth headset drops to 16 kHz when its microphone opens, also in the middle of a recording.
        var current = description
        current.mSampleRate = Self.nominalRate(aggregateID) ?? description.mSampleRate
        var format = AVAudioFormat(streamDescription: &current)
        let aggregateID = aggregateID
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            guard let rate = Self.nominalRate(aggregateID), rate != current.mSampleRate else { return }
            current.mSampleRate = rate
            format = AVAudioFormat(streamDescription: &current)
        }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(aggregateID, &Self.rateAddress, queue, listener)

        // The aggregate's input can carry the output device's own input streams (a headset mic) before
        // the tap's; the tap's buffers are the last ones.
        let wanted = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(description.mChannelsPerFrame) : 1
        let scratch = AudioBufferList.allocate(maximumBuffers: wanted)
        self.scratch = scratch
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.callbacks += 1
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count >= wanted else {
                if self.problem == nil { self.problem = "the tap gave \(list.count) buffer(s), expected \(wanted)" }
                return
            }
            for i in 0..<wanted { scratch[i] = list[list.count - wanted + i] }
            guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: scratch.unsafePointer, deallocator: nil) else {
                if self.problem == nil { self.problem = "the sound came in an unexpected format" }
                return
            }
            writer.write(buffer)
        }
        guard err == noErr else { stop(); throw ClaudistAudioError("Could not start recording (\(err))") }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { stop(); throw ClaudistAudioError("Could not start recording (\(err))") }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            if let rateListener { AudioObjectRemovePropertyListenerBlock(aggregateID, &Self.rateAddress, queue, rateListener) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        rateListener = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Let the IO queue finish its last buffer before the file closes.
        queue.sync {}
        scratch?.unsafeMutablePointer.deallocate()
        scratch = nil
    }

    /// Why nothing was recorded, when nothing was; the file closes when the capture is released.
    var emptyReason: String? {
        queue.sync {
            guard (writer?.frames ?? 0) == 0 else { return nil }
            if let problem = problem ?? writer?.problem { return problem }
            return callbacks == 0 ? "no sound arrived — allow Claudist in System Settings → Privacy & Security → Screen & System Audio Recording"
                : "the app played no sound"
        }
    }
}

struct ClaudistAudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
