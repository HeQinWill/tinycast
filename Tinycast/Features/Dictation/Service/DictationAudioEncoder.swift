import AudioToolbox
import AVFoundation
import Foundation

enum DictationAudioEncoder {
    enum Failure: LocalizedError {
        case emptyAudio
        case encodingFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyAudio: String(localized: "No audio was recorded.")
            case .encodingFailed(let status): String(localized: "Audio encoding failed (\(status)).")
            }
        }
    }

    static func encode(
        samples: [Float],
        format: DictationAudioFormat,
        sampleRate: Double = 16000
    ) throws -> Data {
        guard !samples.isEmpty else { throw Failure.emptyAudio }
        switch format {
        case .m4a:
            return try encodeM4A(samples: samples, sampleRate: sampleRate)
        case .wav:
            return encodeWAV(samples: samples, sampleRate: Int(sampleRate))
        }
    }

    static func encodeDataURI(
        samples: [Float],
        format: DictationAudioFormat,
        sampleRate: Double = 16000
    ) throws -> String {
        let data = try encode(samples: samples, format: format, sampleRate: sampleRate)
        return "data:\(format.mimeType);base64,\(data.base64EncodedString())"
    }

    static func encodeWAV(samples: [Float], sampleRate: Int = 16000) -> Data {
        let numSamples = UInt32(samples.count)
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)
        let dataSize = numSamples * 2
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataSize))

        data.append(contentsOf: "RIFF".utf8)
        var chunkSizeLE = chunkSize.littleEndian
        data.append(Data(bytes: &chunkSizeLE, count: MemoryLayout<UInt32>.size))
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        var subchunk1Size = UInt32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: MemoryLayout<UInt32>.size))
        var audioFormat = UInt16(1).littleEndian
        data.append(Data(bytes: &audioFormat, count: MemoryLayout<UInt16>.size))
        var channels = UInt16(1).littleEndian
        data.append(Data(bytes: &channels, count: MemoryLayout<UInt16>.size))
        var rate = UInt32(sampleRate).littleEndian
        data.append(Data(bytes: &rate, count: MemoryLayout<UInt32>.size))
        var byteRateLE = byteRate.littleEndian
        data.append(Data(bytes: &byteRateLE, count: MemoryLayout<UInt32>.size))
        var blockAlignLE = blockAlign.littleEndian
        data.append(Data(bytes: &blockAlignLE, count: MemoryLayout<UInt16>.size))
        var bitsPerSampleLE = bitsPerSample.littleEndian
        data.append(Data(bytes: &bitsPerSampleLE, count: MemoryLayout<UInt16>.size))

        data.append(contentsOf: "data".utf8)
        var dataSizeLE = dataSize.littleEndian
        data.append(Data(bytes: &dataSizeLE, count: MemoryLayout<UInt32>.size))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0).littleEndian
        }
        pcm.withUnsafeBytes { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
        return data
    }

    static func encodeM4A(samples: [Float], sampleRate: Double = 16000) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var dstDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var extAudioFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            tempURL as CFURL,
            kAudioFileM4AType,
            &dstDesc,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extAudioFile
        )
        guard status == noErr, let file = extAudioFile else {
            throw Failure.encodingFailed(status)
        }

        var srcDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &srcDesc
        )
        guard status == noErr else {
            ExtAudioFileDispose(file)
            throw Failure.encodingFailed(status)
        }

        var samplesCopy = samples
        let frameCount = UInt32(samples.count)
        let bufferByteSize = frameCount * 4

        let writeStatus = samplesCopy.withUnsafeMutableBufferPointer { pointer in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: bufferByteSize,
                    mData: pointer.baseAddress
                )
            )
            return ExtAudioFileWrite(file, frameCount, &bufferList)
        }
        guard writeStatus == noErr else {
            ExtAudioFileDispose(file)
            throw Failure.encodingFailed(writeStatus)
        }

        ExtAudioFileDispose(file)
        return try Data(contentsOf: tempURL)
    }
}
