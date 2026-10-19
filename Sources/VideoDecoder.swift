import Foundation
import AppKit
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreImage

/// NAL unit handling for Annex-B H.264.
///
/// Convert Annex-B packets to the AVCC format consumed by VideoToolbox.
enum AnnexB {
    /// Converts Annex-B to AVCC in a single pass, writing straight into the target buffer without intermediate array allocations.
    static func toAVCC(_ data: Data) -> Data {
        var out = Data()
        let count = data.count
        guard count > 3 else { return out }
        out.reserveCapacity(count + 16)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            var nalStart = -1
            while i + 2 < count {
                if base[i] == 0 && base[i + 1] == 0 {
                    let is3 = base[i + 2] == 1
                    let is4 = base[i + 2] == 0 && i + 3 < count && base[i + 3] == 1
                    if is3 || is4 {
                        if nalStart >= 0 {
                            appendNAL(out: &out, base: base, start: nalStart, end: i)
                        }
                        let codeLen = is3 ? 3 : 4
                        nalStart = i + codeLen
                        i += codeLen
                        continue
                    }
                }
                i += 1
            }
            if nalStart >= 0 && nalStart < count {
                appendNAL(out: &out, base: base, start: nalStart, end: count)
            }
        }
        return out
    }

    private static func appendNAL(out: inout Data, base: UnsafePointer<UInt8>, start: Int, end: Int) {
        let nalLen = end - start
        guard nalLen > 0 else { return }
        out.appendBE(UInt32(nalLen))
        out.append(contentsOf: UnsafeBufferPointer(start: base + start, count: nalLen))
    }

    /// Extracts SPS (type 7) and PPS (type 8) in a single pass, copying only on first encounter.
    static func parameterSets(from data: Data) -> (sps: Data?, pps: Data?) {
        var sps: Data?
        var pps: Data?
        let count = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            var nalStart = -1
            while i + 2 < count {
                if base[i] == 0 && base[i + 1] == 0 {
                    let is3 = base[i + 2] == 1
                    let is4 = base[i + 2] == 0 && i + 3 < count && base[i + 3] == 1
                    if is3 || is4 {
                        if nalStart >= 0 {
                            collect(base: base, start: nalStart, end: i, sps: &sps, pps: &pps)
                        }
                        let codeLen = is3 ? 3 : 4
                        nalStart = i + codeLen
                        i += codeLen
                        continue
                    }
                }
                i += 1
            }
            if nalStart >= 0 && nalStart < count {
                collect(base: base, start: nalStart, end: count, sps: &sps, pps: &pps)
            }
        }
        return (sps, pps)
    }

    private static func collect(base: UnsafePointer<UInt8>, start: Int, end: Int,
                                sps: inout Data?, pps: inout Data?) {
        let type = base[start] & 0x1F
        guard (type == 7 && sps == nil) || (type == 8 && pps == nil) else { return }
        let nal = Data(bytes: base + start, count: end - start)
        if type == 7 { sps = nal } else { pps = nal }
    }
}

/// Decode once with VideoToolbox; share output between display and skill inference.
final class VideoDecoder {
    private let layer: AVSampleBufferDisplayLayer
    private var formatDescription: CMVideoFormatDescription?
    private let queue = DispatchQueue(label: "adbquick.video")
    private var session: VTDecompressionSession?
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var decodeError: OSStatus?
    private let imageContext = CIContext()

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Called on the replay queue; retain the buffer while encoding its snapshot.
    func saveCurrentFrame(to url: URL) throws -> (Int, Int) {
        frameLock.lock()
        let frame = latestFrame
        let error = decodeError
        frameLock.unlock()
        if let error { throw replayError("Video decode failed: \(error)") }
        guard let frame else { throw replayError("No decoded video frame yet.") }
        let image = CIImage(cvPixelBuffer: frame)
        try imageContext.writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                               colorSpace: CGColorSpaceCreateDeviceRGB())
        return (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
    }

    private func clearSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        frameLock.lock()
        latestFrame = nil
        decodeError = nil
        frameLock.unlock()
        layer.flush()
    }

    private func failedDecode(_ status: OSStatus) {
        frameLock.lock()
        latestFrame = nil
        decodeError = status
        frameLock.unlock()
    }

    private func display(_ frame: CVPixelBuffer) {
        frameLock.lock()
        latestFrame = frame
        decodeError = nil
        frameLock.unlock()
        guard layer.isReadyForMoreMediaData else { return }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
           let sample {
            layer.enqueue(sample)
        }
    }

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    /// Clears state on session switches (e.g. rotation).
    func reset() {
        queue.async { [weak self] in
            self?.formatDescription = nil
            self?.clearSession()
        }
    }

    /// Parses a config packet (SPS/PPS) and rebuilds the format description.
    func setConfig(_ annexb: Data) {
        let (sps, pps) = AnnexB.parameterSets(from: annexb)
        guard let sps, let pps else { return }

        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress,
                      let pp = p.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-1)
                }
                var ptrs: [UnsafePointer<UInt8>] = [sp, pp]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: &ptrs,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        if status == noErr, let desc {
            queue.async { [weak self] in
                guard let self else { return }
                self.clearSession()
                self.formatDescription = desc
                let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
                let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc,
                    decoderSpecification: nil, imageBufferAttributes: attributes,
                    outputCallback: nil, decompressionSessionOut: &self.session)
                if result != noErr { self.formatDescription = nil; self.failedDecode(result) }
            }
        }
    }

    /// Feeds one Annex-B video frame for decode and rendering.
    func enqueue(_ annexbFrame: Data) {
        queue.async { [weak self] in
            self?.enqueueInternal(annexbFrame)
        }
    }

    private func enqueueInternal(_ annexbFrame: Data) {
        // Feed every packet: dropping compressed delta frames breaks future decoding.
        guard let fd = formatDescription, let session else { return }
        let avcc = AnnexB.toAVCC(annexbFrame)
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &blockBuffer)
        guard createStatus == kCMBlockBufferNoErr, let bb = blockBuffer else { return }

        let replaceStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb,
                                                 offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: now,
                                        decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        let sampleStatus = CMSampleBufferCreate(
            allocator: nil, dataBuffer: bb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fd, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        if sampleStatus == noErr, let sb = sampleBuffer {
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) {
                [weak self] status, _, frame, _, _ in
                guard status == noErr else { self?.failedDecode(status); return }
                if let frame { self?.display(frame) }
            }
            if status != noErr { failedDecode(status) }
        }
    }
}

/// View hosting video rendering and mouse/keyboard events.
final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    private func point(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(point(event)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(point(event)) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(point(event)) }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func keyDown(with event: NSEvent) { onKeyDown?(event) }
}
