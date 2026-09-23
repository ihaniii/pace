//
//  PaceWAVEncoder.swift
//  leanring-buddy
//
//  Lightweight, pure in-memory WAV container encoder for Float PCM samples.
//  Zero file I/O, zero network, zero dependencies.
//

import Foundation

public enum PaceWAVEncoder {
    /// Encodes normalized Float PCM samples (range [-1.0, 1.0]) into standard 16-bit PCM WAV data.
    public static func encodeWAV(samples: [Float], sampleRate: Int32, channels: Int = 1) -> Data {
        let numSamples = samples.count
        let bytesPerSample = 2 // 16-bit
        let dataSize = numSamples * bytesPerSample
        let totalSize = 44 + dataSize

        var data = Data(capacity: totalSize)

        // 1. RIFF Header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        let chunkSize = UInt32(36 + dataSize).littleEndian
        withUnsafeBytes(of: chunkSize) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // 2. fmt Subchunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        let subchunk1Size = UInt32(16).littleEndian
        withUnsafeBytes(of: subchunk1Size) { data.append(contentsOf: $0) }

        let audioFormat = UInt16(1).littleEndian // 1 = PCM
        withUnsafeBytes(of: audioFormat) { data.append(contentsOf: $0) }

        let numChannels = UInt16(channels).littleEndian
        withUnsafeBytes(of: numChannels) { data.append(contentsOf: $0) }

        let sRate = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: sRate) { data.append(contentsOf: $0) }

        let byteRate = UInt32(sampleRate * Int32(channels) * Int32(bytesPerSample)).littleEndian
        withUnsafeBytes(of: byteRate) { data.append(contentsOf: $0) }

        let blockAlign = UInt16(channels * bytesPerSample).littleEndian
        withUnsafeBytes(of: blockAlign) { data.append(contentsOf: $0) }

        let bitsPerSample = UInt16(16).littleEndian
        withUnsafeBytes(of: bitsPerSample) { data.append(contentsOf: $0) }

        // 3. data Subchunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        let subchunk2Size = UInt32(dataSize).littleEndian
        withUnsafeBytes(of: subchunk2Size) { data.append(contentsOf: $0) }

        // 4. Sample Conversion to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intSample = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: intSample) { data.append(contentsOf: $0) }
        }

        return data
    }
}
