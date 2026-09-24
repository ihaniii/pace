//
//  PaceArabicSofeliaONNXWorker.swift
//  leanring-buddy
//
//  Actor-isolated worker managing Sofelia ONNX model lifecycle, lazy loading,
//  serialized inference, cooperative cancellation, and memory exclusivity.
//  Strictly offline: zero network, zero process spawning, zero background daemons.
//

import Foundation

#if canImport(onnxruntime)
import onnxruntime
#endif

public enum PaceSofeliaTTSError: LocalizedError, Equatable {
    case runtimeUnavailable
    case alreadySynthesizing
    case modelInitializationFailed(reason: String)
    case synthesisFailed(reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "ONNX Runtime is not linked or unavailable."
        case .alreadySynthesizing:
            return "Another Sofelia synthesis operation is already active."
        case .modelInitializationFailed(let reason):
            return "Failed to initialize Sofelia ONNX model: \(reason)"
        case .synthesisFailed(let reason):
            return "Sofelia ONNX synthesis failed: \(reason)"
        case .cancelled:
            return "Sofelia synthesis was cancelled by barge-in or stop."
        }
    }
}

public actor PaceArabicSofeliaONNXWorker {
    public static let shared = PaceArabicSofeliaONNXWorker()

    #if canImport(onnxruntime)
    private final class SessionHolder {
        let env: OpaquePointer
        let session: OpaquePointer
        let sessionOptions: OpaquePointer
        let memoryInfo: OpaquePointer
        let api: UnsafePointer<OrtApi>
        let stylesData: Data

        init(
            env: OpaquePointer,
            session: OpaquePointer,
            sessionOptions: OpaquePointer,
            memoryInfo: OpaquePointer,
            api: UnsafePointer<OrtApi>,
            stylesData: Data
        ) {
            self.env = env
            self.session = session
            self.sessionOptions = sessionOptions
            self.memoryInfo = memoryInfo
            self.api = api
            self.stylesData = stylesData
        }

        deinit {
            api.pointee.ReleaseMemoryInfo(memoryInfo)
            api.pointee.ReleaseSession(session)
            api.pointee.ReleaseSessionOptions(sessionOptions)
            api.pointee.ReleaseEnv(env)
        }

        func getStyleVector(at index: Int) -> [Float] {
            let clampedIdx = max(0, min(509, index))
            let byteOffset = clampedIdx * 256 * MemoryLayout<Float>.size
            var result = [Float](repeating: 0.0, count: 256)
            _ = result.withUnsafeMutableBytes { dest in
                stylesData.copyBytes(to: dest, from: byteOffset..<(byteOffset + 256 * MemoryLayout<Float>.size))
            }
            return result
        }
    }

    private var activeSession: SessionHolder?
    #endif

    private var isSynthesizing: Bool = false
    private var isCancelled: Bool = false
    private let frontend: PacePalestinianArabicFrontend

    public init(frontend: PacePalestinianArabicFrontend = .shared) {
        self.frontend = frontend
    }

    // MARK: - State Inspection

    public var hasLoadedEngine: Bool {
        #if canImport(onnxruntime)
        return activeSession != nil
        #else
        return false
        #endif
    }

    // MARK: - Synthesis API

    /// Synthesizes Palestinian Arabic text using Sofelia ONNX.
    public func synthesizeArabic(
        text: String,
        config: PaceSofeliaModelConfiguration,
        speed: Float = 1.0
    ) async throws -> PaceSynthesizedAudio {
        #if canImport(onnxruntime)
        guard !isSynthesizing else {
            throw PaceSofeliaTTSError.alreadySynthesizing
        }

        guard !isCancelled else {
            isCancelled = false
            throw PaceSofeliaTTSError.cancelled
        }

        isSynthesizing = true
        defer {
            isSynthesizing = false
            isCancelled = false
        }

        // 1. Frontend phonemization and tokenization
        let (phonemes, tokens, styleIndex) = try frontend.textToPhonemesAndTokens(
            text: text,
            lexiconPath: config.lexiconPath,
            vocabPath: config.vocabPath
        )

        guard tokens.count > 2 else {
            throw PaceSofeliaTTSError.synthesisFailed(reason: "Frontend produced empty token sequence.")
        }

        // 2. Cancellation check before loading / inference
        if isCancelled {
            throw PaceSofeliaTTSError.cancelled
        }

        // 3. Lazy session resolution with model exclusivity
        let holder = try await resolveOrLoadSofelia(config: config)

        if isCancelled {
            throw PaceSofeliaTTSError.cancelled
        }

        // 4. Style vector extraction
        let styleVector = holder.getStyleVector(at: styleIndex)

        // 5. Execute ONNX inference
        let samples = try executeInference(
            holder: holder,
            tokens: tokens,
            style: styleVector,
            speed: speed
        )

        // 6. Post-inference cancellation suppression
        if isCancelled {
            throw PaceSofeliaTTSError.cancelled
        }

        guard !samples.isEmpty else {
            throw PaceSofeliaTTSError.synthesisFailed(reason: "Sofelia inference produced empty audio.")
        }

        return PaceSynthesizedAudio(samples: samples, sampleRate: config.sampleRate)
        #else
        throw PaceSofeliaTTSError.runtimeUnavailable
        #endif
    }

#if canImport(onnxruntime)
private func ortErrorMessage(api: UnsafePointer<OrtApi>, status: OpaquePointer?) -> String {
    guard let status = status else { return "Success" }
    if let msgPtr = api.pointee.GetErrorMessage(status) {
        return String(cString: msgPtr)
    }
    return "Unknown ORT error"
}
#endif

    // MARK: - Internal Session Lifecycle

    #if canImport(onnxruntime)
    private func resolveOrLoadSofelia(config: PaceSofeliaModelConfiguration) async throws -> SessionHolder {
        if let current = activeSession {
            return current
        }

        // Memory exclusivity: unload Sherpa engine before loading Sofelia
        await PaceSherpaTTSWorker.shared.unload()

        guard let apiBase = OrtGetApiBase() else {
            throw PaceSofeliaTTSError.modelInitializationFailed(reason: "OrtGetApiBase returned NULL.")
        }
        guard let api = apiBase.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw PaceSofeliaTTSError.modelInitializationFailed(reason: "OrtApi for version \(ORT_API_VERSION) unavailable.")
        }

        var envPtr: OpaquePointer?
        let envStatus = api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "sofelia_prod", &envPtr)
        guard envStatus == nil, let env = envPtr else {
            let msg = ortErrorMessage(api: api, status: envStatus)
            if let envStatus { api.pointee.ReleaseStatus(envStatus) }
            throw PaceSofeliaTTSError.modelInitializationFailed(reason: "CreateEnv failed: \(msg)")
        }

        var optPtr: OpaquePointer?
        let optStatus = api.pointee.CreateSessionOptions(&optPtr)
        guard optStatus == nil, let options = optPtr else {
            api.pointee.ReleaseEnv(env)
            let msg = ortErrorMessage(api: api, status: optStatus)
            if let optStatus { api.pointee.ReleaseStatus(optStatus) }
            throw PaceSofeliaTTSError.modelInitializationFailed(reason: "CreateSessionOptions failed: \(msg)")
        }

        _ = api.pointee.SetIntraOpNumThreads(options, 4)
        _ = api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL)

        var sessPtr: OpaquePointer?
        let sessStatus = api.pointee.CreateSession(env, (config.modelPath as NSString).utf8String, options, &sessPtr)
        guard sessStatus == nil, let session = sessPtr else {
            api.pointee.ReleaseSessionOptions(options)
            api.pointee.ReleaseEnv(env)
            let msg = ortErrorMessage(api: api, status: sessStatus)
            if let sessStatus { api.pointee.ReleaseStatus(sessStatus) }
            throw PaceSofeliaTTSError.modelInitializationFailed(reason: "CreateSession failed: \(msg)")
        }

        var memPtr: OpaquePointer?
        let memStatus = api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memPtr)
        guard memStatus == nil, let memoryInfo = memPtr else {
            api.pointee.ReleaseSession(session)
            api.pointee.ReleaseSessionOptions(options)
            api.pointee.ReleaseEnv(env)
            let msg = ortErrorMessage(api: api, status: memStatus)
            if let memStatus { api.pointee.ReleaseStatus(memStatus) }
            throw PaceSofeliaTTSError.modelInitializationFailed(reason: "CreateCpuMemoryInfo failed: \(msg)")
        }

        let stylesData = try Data(contentsOf: URL(fileURLWithPath: config.stylesPath))

        let holder = SessionHolder(
            env: env,
            session: session,
            sessionOptions: options,
            memoryInfo: memoryInfo,
            api: api,
            stylesData: stylesData
        )
        self.activeSession = holder
        return holder
    }

    private func executeInference(
        holder: SessionHolder,
        tokens: [Int64],
        style: [Float],
        speed: Float
    ) throws -> [Float] {
        let api = holder.api

        var speedVal = speed
        return try tokens.withUnsafeBufferPointer { tBuf in
            try style.withUnsafeBufferPointer { sBuf in
                try withUnsafePointer(to: &speedVal) { spPtr in
                    // 1. input_ids tensor: shape [1, seq_len], int64
                    var inputShape: [Int64] = [1, Int64(tokens.count)]
                    var inInputIds: OpaquePointer?
                    let tStatus = api.pointee.CreateTensorWithDataAsOrtValue(
                        holder.memoryInfo,
                        UnsafeMutableRawPointer(mutating: tBuf.baseAddress),
                        tokens.count * MemoryLayout<Int64>.size,
                        &inputShape,
                        2,
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
                        &inInputIds
                    )
                    guard tStatus == nil, let valInputIds = inInputIds else {
                        let msg = ortErrorMessage(api: api, status: tStatus)
                        if let tStatus { api.pointee.ReleaseStatus(tStatus) }
                        throw PaceSofeliaTTSError.synthesisFailed(reason: "Failed creating input_ids tensor: \(msg)")
                    }

                    // 2. style tensor: shape [1, 256], float32
                    var styleShape: [Int64] = [1, 256]
                    var inStyle: OpaquePointer?
                    let sStatus = api.pointee.CreateTensorWithDataAsOrtValue(
                        holder.memoryInfo,
                        UnsafeMutableRawPointer(mutating: sBuf.baseAddress),
                        256 * MemoryLayout<Float>.size,
                        &styleShape,
                        2,
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                        &inStyle
                    )
                    guard sStatus == nil, let valStyle = inStyle else {
                        api.pointee.ReleaseValue(valInputIds)
                        let msg = ortErrorMessage(api: api, status: sStatus)
                        if let sStatus { api.pointee.ReleaseStatus(sStatus) }
                        throw PaceSofeliaTTSError.synthesisFailed(reason: "Failed creating style tensor: \(msg)")
                    }

                    // 3. speed tensor: shape [1], float32
                    var speedShape: [Int64] = [1]
                    var inSpeed: OpaquePointer?
                    let spStatus = api.pointee.CreateTensorWithDataAsOrtValue(
                        holder.memoryInfo,
                        UnsafeMutableRawPointer(mutating: spPtr),
                        1 * MemoryLayout<Float>.size,
                        &speedShape,
                        1,
                        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                        &inSpeed
                    )
                    guard spStatus == nil, let valSpeed = inSpeed else {
                        api.pointee.ReleaseValue(valInputIds)
                        api.pointee.ReleaseValue(valStyle)
                        let msg = ortErrorMessage(api: api, status: spStatus)
                        if let spStatus { api.pointee.ReleaseStatus(spStatus) }
                        throw PaceSofeliaTTSError.synthesisFailed(reason: "Failed creating speed tensor: \(msg)")
                    }

                    defer {
                        api.pointee.ReleaseValue(valInputIds)
                        api.pointee.ReleaseValue(valStyle)
                        api.pointee.ReleaseValue(valSpeed)
                    }

                    return try "input_ids".withCString { in0 in
                        try "style".withCString { in1 in
                            try "speed".withCString { in2 in
                                try "waveform".withCString { out0 in
                                    try "duration".withCString { out1 in
                                        var inNames: [UnsafePointer<CChar>?] = [in0, in1, in2]
                                        var inValues: [OpaquePointer?] = [valInputIds, valStyle, valSpeed]
                                        var outNames: [UnsafePointer<CChar>?] = [out0, out1]
                                        var outValues: [OpaquePointer?] = [nil, nil]

                                        let runStatus = api.pointee.Run(
                                            holder.session,
                                            nil,
                                            &inNames,
                                            &inValues,
                                            3,
                                            &outNames,
                                            2,
                                            &outValues
                                        )

                                        guard runStatus == nil else {
                                            let msg = ortErrorMessage(api: api, status: runStatus)
                                            if let runStatus { api.pointee.ReleaseStatus(runStatus) }
                                            if let waveVal = outValues[0] { api.pointee.ReleaseValue(waveVal) }
                                            if let durVal = outValues[1] { api.pointee.ReleaseValue(durVal) }
                                            throw PaceSofeliaTTSError.synthesisFailed(reason: "api.Run failed: \(msg)")
                                        }

                                        guard let waveVal = outValues[0] else {
                                            if let durVal = outValues[1] { api.pointee.ReleaseValue(durVal) }
                                            throw PaceSofeliaTTSError.synthesisFailed(reason: "Waveform output tensor is nil.")
                                        }

                                        defer {
                                            api.pointee.ReleaseValue(waveVal)
                                            if let durVal = outValues[1] {
                                                api.pointee.ReleaseValue(durVal)
                                            }
                                        }

                                        // Extract waveform data
                                        var typeShapeInfo: OpaquePointer?
                                        _ = api.pointee.GetTensorTypeAndShape(waveVal, &typeShapeInfo)
                                        guard let shapeInfo = typeShapeInfo else {
                                            throw PaceSofeliaTTSError.synthesisFailed(reason: "GetTensorTypeAndShape failed.")
                                        }
                                        var elemCount: Int = 0
                                        _ = api.pointee.GetTensorShapeElementCount(shapeInfo, &elemCount)
                                        api.pointee.ReleaseTensorTypeAndShapeInfo(shapeInfo)

                                        var rawDataPtr: UnsafeMutableRawPointer?
                                        _ = api.pointee.GetTensorMutableData(waveVal, &rawDataPtr)
                                        guard let dataPtr = rawDataPtr, elemCount > 0 else {
                                            throw PaceSofeliaTTSError.synthesisFailed(reason: "GetTensorMutableData returned empty.")
                                        }

                                        let floatPtr = dataPtr.bindMemory(to: Float.self, capacity: elemCount)
                                        return Array(UnsafeBufferPointer(start: floatPtr, count: elemCount))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Cancellation & Teardown

    /// Cancels any currently active synthesis.
    public func cancelActiveSynthesis() {
        isCancelled = true
    }

    /// Unloads resident model and releases memory back to the OS.
    public func unload() {
        #if canImport(onnxruntime)
        activeSession = nil
        #endif
        isCancelled = false
        isSynthesizing = false
    }
}
