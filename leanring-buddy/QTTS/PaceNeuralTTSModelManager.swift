//
//  PaceNeuralTTSModelManager.swift
//  leanring-buddy
//
//  Resolves and validates approved local roots for Neural TTS models.
//  Strictly offline: zero network, zero process spawning, fail-closed
//  path traversal and symlink validation.
//

import Foundation

public enum PaceNeuralTTSModelError: LocalizedError, Equatable {
    case approvedRootNotFound
    case securityViolation(reason: String)
    case modelDirectoryNotFound(language: String, expectedPath: String)
    case requiredFileNotFound(fileName: String, expectedPath: String)
    case fileNotReadable(path: String)

    public var errorDescription: String? {
        switch self {
        case .approvedRootNotFound:
            return "No approved Neural TTS root directory exists or is accessible."
        case .securityViolation(let reason):
            return "Security violation: \(reason)"
        case .modelDirectoryNotFound(let language, let expectedPath):
            return "Model directory for '\(language)' not found at \(expectedPath)"
        case .requiredFileNotFound(let fileName, let expectedPath):
            return "Required model asset '\(fileName)' not found at \(expectedPath)"
        case .fileNotReadable(let path):
            return "Model file at \(path) is not readable."
        }
    }
}

public struct PaceKokoroModelConfiguration: Equatable, Sendable {
    public let modelPath: String
    public let voicesPath: String
    public let tokensPath: String
    public let dataDirPath: String
    public let sampleRate: Int32

    public init(
        modelPath: String,
        voicesPath: String,
        tokensPath: String,
        dataDirPath: String,
        sampleRate: Int32 = 24000
    ) {
        self.modelPath = modelPath
        self.voicesPath = voicesPath
        self.tokensPath = tokensPath
        self.dataDirPath = dataDirPath
        self.sampleRate = sampleRate
    }
}

public struct PaceSwedishModelConfiguration: Equatable, Sendable {
    public let modelPath: String
    public let tokensPath: String
    public let dataDirPath: String
    public let sampleRate: Int32
    public let configPath: String?

    public init(
        modelPath: String,
        tokensPath: String,
        dataDirPath: String,
        sampleRate: Int32 = 22050,
        configPath: String? = nil
    ) {
        self.modelPath = modelPath
        self.tokensPath = tokensPath
        self.dataDirPath = dataDirPath
        self.sampleRate = sampleRate
        self.configPath = configPath
    }
}

public struct PaceSofeliaModelConfiguration: Equatable, Sendable {
    public let modelPath: String
    public let lexiconPath: String
    public let vocabPath: String
    public let stylesPath: String
    public let sampleRate: Int32

    public init(
        modelPath: String,
        lexiconPath: String,
        vocabPath: String,
        stylesPath: String,
        sampleRate: Int32 = 24000
    ) {
        self.modelPath = modelPath
        self.lexiconPath = lexiconPath
        self.vocabPath = vocabPath
        self.stylesPath = stylesPath
        self.sampleRate = sampleRate
    }
}

public final class PaceNeuralTTSModelManager: Sendable {
    public static let shared = PaceNeuralTTSModelManager()

    private let customSearchRoots: [URL]?
    private let fileManager: FileManager

    public init(customSearchRoots: [URL]? = nil, fileManager: FileManager = .default) {
        self.customSearchRoots = customSearchRoots
        self.fileManager = fileManager
    }

    /// Default approved search roots:
    /// 1. Application bundle resources: NeuralTTS/
    /// 2. Application Support: ~/Library/Application Support/Pace/Models/TTS/
    public var approvedSearchRoots: [URL] {
        if let customSearchRoots {
            return customSearchRoots
        }

        var roots: [URL] = []
        if let bundleResourceURL = Bundle.main.resourceURL {
            roots.append(bundleResourceURL.appendingPathComponent("NeuralTTS", isDirectory: true))
        }

        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let paceTTSModels = appSupportURL
                .appendingPathComponent("Pace", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("TTS", isDirectory: true)
            roots.append(paceTTSModels)
        }

        return roots
    }

    // MARK: - Validation

    /// Validates that the target path does not contain traversal tokens (`..`)
    /// and resolves within an approved root without escaping via symlinks.
    public func validatePathSecurity(targetURL: URL, approvedRoot: URL) throws -> URL {
        let pathString = targetURL.path
        if pathString.contains("..") {
            throw PaceNeuralTTSModelError.securityViolation(
                reason: "Path traversal rejected: '\(pathString)' contains relative navigation tokens."
            )
        }

        let canonicalTarget = targetURL.resolvingSymlinksInPath()
        let canonicalRoot = approvedRoot.resolvingSymlinksInPath()

        let targetPath = canonicalTarget.standardized.path
        let rootPath = canonicalRoot.standardized.path

        guard targetPath.hasPrefix(rootPath) else {
            throw PaceNeuralTTSModelError.securityViolation(
                reason: "Symlink escape rejected: target '\(targetPath)' is outside approved root '\(rootPath)'."
            )
        }

        return canonicalTarget
    }

    // MARK: - Resolution

    /// Resolves Kokoro configuration from the first approved root containing all required assets.
    public func resolveKokoroConfiguration() -> Result<PaceKokoroModelConfiguration, PaceNeuralTTSModelError> {
        let roots = approvedSearchRoots
        guard !roots.isEmpty else {
            return .failure(.approvedRootNotFound)
        }

        var lastError: PaceNeuralTTSModelError = .approvedRootNotFound

        for root in roots {
            let kokoroDir = root.appendingPathComponent("Kokoro", isDirectory: true)

            // Validate root security
            let secureKokoroDir: URL
            do {
                secureKokoroDir = try validatePathSecurity(targetURL: kokoroDir, approvedRoot: root)
            } catch let error as PaceNeuralTTSModelError {
                lastError = error
                continue
            } catch {
                lastError = .securityViolation(reason: error.localizedDescription)
                continue
            }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: secureKokoroDir.path, isDirectory: &isDir), isDir.boolValue else {
                lastError = .modelDirectoryNotFound(language: "Kokoro (en)", expectedPath: secureKokoroDir.path)
                continue
            }

            let modelFile = secureKokoroDir.appendingPathComponent("model.onnx")
            let voicesFile = secureKokoroDir.appendingPathComponent("voices.bin")
            let tokensFile = secureKokoroDir.appendingPathComponent("tokens.txt")
            let espeakDir = secureKokoroDir.appendingPathComponent("espeak-ng-data", isDirectory: true)

            // Validate required files
            guard fileManager.fileExists(atPath: modelFile.path) else {
                lastError = .requiredFileNotFound(fileName: "model.onnx", expectedPath: modelFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: modelFile.path) else {
                lastError = .fileNotReadable(path: modelFile.path)
                continue
            }

            guard fileManager.fileExists(atPath: voicesFile.path) else {
                lastError = .requiredFileNotFound(fileName: "voices.bin", expectedPath: voicesFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: voicesFile.path) else {
                lastError = .fileNotReadable(path: voicesFile.path)
                continue
            }

            guard fileManager.fileExists(atPath: tokensFile.path) else {
                lastError = .requiredFileNotFound(fileName: "tokens.txt", expectedPath: tokensFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: tokensFile.path) else {
                lastError = .fileNotReadable(path: tokensFile.path)
                continue
            }

            var espeakIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: espeakDir.path, isDirectory: &espeakIsDir), espeakIsDir.boolValue else {
                lastError = .requiredFileNotFound(fileName: "espeak-ng-data/", expectedPath: espeakDir.path)
                continue
            }

            let config = PaceKokoroModelConfiguration(
                modelPath: modelFile.path,
                voicesPath: voicesFile.path,
                tokensPath: tokensFile.path,
                dataDirPath: espeakDir.path,
                sampleRate: 24000
            )
            return .success(config)
        }

        return .failure(lastError)
    }

    /// Resolves Swedish Piper (Alma) configuration from the first approved root containing all required assets.
    public func resolveSwedishConfiguration() -> Result<PaceSwedishModelConfiguration, PaceNeuralTTSModelError> {
        let roots = approvedSearchRoots
        guard !roots.isEmpty else {
            return .failure(.approvedRootNotFound)
        }

        var lastError: PaceNeuralTTSModelError = .approvedRootNotFound

        for root in roots {
            let swedishDir = root.appendingPathComponent("Swedish", isDirectory: true)

            // Validate root security
            let secureSwedishDir: URL
            do {
                secureSwedishDir = try validatePathSecurity(targetURL: swedishDir, approvedRoot: root)
            } catch let error as PaceNeuralTTSModelError {
                lastError = error
                continue
            } catch {
                lastError = .securityViolation(reason: error.localizedDescription)
                continue
            }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: secureSwedishDir.path, isDirectory: &isDir), isDir.boolValue else {
                lastError = .modelDirectoryNotFound(language: "Swedish (sv)", expectedPath: secureSwedishDir.path)
                continue
            }

            let modelFile = secureSwedishDir.appendingPathComponent("sv_SE-alma-medium.onnx")
            let tokensFile = secureSwedishDir.appendingPathComponent("tokens.txt")
            let espeakDir = secureSwedishDir.appendingPathComponent("espeak-ng-data", isDirectory: true)
            let configFile = secureSwedishDir.appendingPathComponent("sv_SE-alma-medium.onnx.json")

            guard fileManager.fileExists(atPath: modelFile.path) else {
                lastError = .requiredFileNotFound(fileName: "sv_SE-alma-medium.onnx", expectedPath: modelFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: modelFile.path) else {
                lastError = .fileNotReadable(path: modelFile.path)
                continue
            }

            guard fileManager.fileExists(atPath: tokensFile.path) else {
                lastError = .requiredFileNotFound(fileName: "tokens.txt", expectedPath: tokensFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: tokensFile.path) else {
                lastError = .fileNotReadable(path: tokensFile.path)
                continue
            }

            var espeakIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: espeakDir.path, isDirectory: &espeakIsDir), espeakIsDir.boolValue else {
                lastError = .requiredFileNotFound(fileName: "espeak-ng-data/", expectedPath: espeakDir.path)
                continue
            }

            let config = PaceSwedishModelConfiguration(
                modelPath: modelFile.path,
                tokensPath: tokensFile.path,
                dataDirPath: espeakDir.path,
                sampleRate: 22050,
                configPath: fileManager.fileExists(atPath: configFile.path) ? configFile.path : nil
            )
            return .success(config)
        }

        return .failure(lastError)
    }

    /// Resolves Sofelia Palestinian Arabic configuration from the first approved root containing all required assets.
    public func resolveSofeliaConfiguration() -> Result<PaceSofeliaModelConfiguration, PaceNeuralTTSModelError> {
        let roots = approvedSearchRoots
        guard !roots.isEmpty else {
            return .failure(.approvedRootNotFound)
        }

        var lastError: PaceNeuralTTSModelError = .approvedRootNotFound

        for root in roots {
            let sofeliaDir = root.appendingPathComponent("Sofelia", isDirectory: true)

            // Validate root security
            let secureSofeliaDir: URL
            do {
                secureSofeliaDir = try validatePathSecurity(targetURL: sofeliaDir, approvedRoot: root)
            } catch let error as PaceNeuralTTSModelError {
                lastError = error
                continue
            } catch {
                lastError = .securityViolation(reason: error.localizedDescription)
                continue
            }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: secureSofeliaDir.path, isDirectory: &isDir), isDir.boolValue else {
                lastError = .modelDirectoryNotFound(language: "Palestinian Arabic (Sofelia)", expectedPath: secureSofeliaDir.path)
                continue
            }

            let modelFile = secureSofeliaDir.appendingPathComponent("sofelia_palestinian.onnx")
            let lexiconFile = secureSofeliaDir.appendingPathComponent("ar_lexicon.json")
            let vocabFile = secureSofeliaDir.appendingPathComponent("vocab.json")
            let stylesFile = secureSofeliaDir.appendingPathComponent("eliaa_styles.bin")

            // Validate model file
            guard fileManager.fileExists(atPath: modelFile.path) else {
                lastError = .requiredFileNotFound(fileName: "sofelia_palestinian.onnx", expectedPath: modelFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: modelFile.path) else {
                lastError = .fileNotReadable(path: modelFile.path)
                continue
            }

            // Validate size
            if let attrs = try? fileManager.attributesOfItem(atPath: modelFile.path),
               let size = attrs[.size] as? UInt64 {
                guard size > 300_000_000 else {
                    lastError = .securityViolation(reason: "sofelia_palestinian.onnx size \(size) bytes is below required threshold.")
                    continue
                }
            }

            // Validate lexicon
            guard fileManager.fileExists(atPath: lexiconFile.path) else {
                lastError = .requiredFileNotFound(fileName: "ar_lexicon.json", expectedPath: lexiconFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: lexiconFile.path) else {
                lastError = .fileNotReadable(path: lexiconFile.path)
                continue
            }

            // Validate vocab
            guard fileManager.fileExists(atPath: vocabFile.path) else {
                lastError = .requiredFileNotFound(fileName: "vocab.json", expectedPath: vocabFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: vocabFile.path) else {
                lastError = .fileNotReadable(path: vocabFile.path)
                continue
            }

            // Validate styles
            guard fileManager.fileExists(atPath: stylesFile.path) else {
                lastError = .requiredFileNotFound(fileName: "eliaa_styles.bin", expectedPath: stylesFile.path)
                continue
            }
            guard fileManager.isReadableFile(atPath: stylesFile.path) else {
                lastError = .fileNotReadable(path: stylesFile.path)
                continue
            }

            if let attrs = try? fileManager.attributesOfItem(atPath: stylesFile.path),
               let size = attrs[.size] as? UInt64 {
                guard size == 522_240 else {
                    lastError = .securityViolation(reason: "eliaa_styles.bin size is \(size), expected 522240 bytes.")
                    continue
                }
            }

            let config = PaceSofeliaModelConfiguration(
                modelPath: modelFile.path,
                lexiconPath: lexiconFile.path,
                vocabPath: vocabFile.path,
                stylesPath: stylesFile.path,
                sampleRate: 24000
            )
            return .success(config)
        }

        return .failure(lastError)
    }
}
