import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import Compression

class FileHandlerManager: ObservableObject {
    @Published var isLoading = false
    @Published var inputFile: URL?
    @Published var pieces: [URL] = []
    @Published var uploadState: UploadState = .idle
    @Published var mendedFile: URL?
    @Published var progress: Double = 0
    @Published var isSecureMode = false
    
    enum UploadState {
        case idle
        case uploading
        case processing(String)
        case completed
        case error(String)
    }
    
    private var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    
    private let chunkSize = 1024 * 1024 // 1MB chunks for streaming
    
    deinit {
        cleanupTemporaryFiles()
    }
    
    func handleFileSelection(_ url: URL) {
        Task { @MainActor in
            self.uploadState = .uploading
            self.inputFile = url
            self.breakFile(url)
        }
    }
    
    func clearFiles() {
        inputFile = nil
        pieces = []
        mendedFile = nil
        uploadState = .idle
        isLoading = false
        progress = 0
        cleanupTemporaryFiles()
    }
    
    private func cleanupTemporaryFiles() {
        for url in pieces {
            try? FileManager.default.removeItem(atPath: url.path(percentEncoded: false))
        }
        
        if let mendedFile = mendedFile,
           mendedFile.path(percentEncoded: false).contains(FileManager.default.temporaryDirectory.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(atPath: mendedFile.path(percentEncoded: false))
        }
    }
    
    private func compressData(_ data: Data) throws -> Data {
        let sourceSize = data.count
        let destinationSize = sourceSize * 2 // Allow for potential compression expansion
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }
        
        let compressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let baseAddress = sourceBuffer.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                sourceBuffer.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
        
        return Data(bytes: destinationBuffer, count: compressedSize)
    }
    
    private func decompressData(_ data: Data) throws -> Data {
        let sourceSize = data.count
        let destinationSize = sourceSize * 10 // Allow for significant decompression expansion
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }
        
        let decompressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let baseAddress = sourceBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                sourceBuffer.count,
                nil,
                COMPRESSION_LZFSE
            )
        }
        
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
    
    private func encryptData(_ data: Data, using key: SymmetricKey) throws -> (encryptedData: Data, salt: Data) {
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let derivedKey = deriveKey(from: key.withUnsafeBytes { Data($0) }.base64EncodedString(), salt: salt)
        let sealedBox = try AES.GCM.seal(data, using: derivedKey, nonce: AES.GCM.Nonce())
        return (sealedBox.combined!, salt)
    }
    
    private func decryptData(_ data: Data, salt: Data, using key: SymmetricKey) throws -> Data {
        let derivedKey = deriveKey(from: key.withUnsafeBytes { Data($0) }.base64EncodedString(), salt: salt)
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: derivedKey)
    }
    
    private func deriveKey(from hash: String, salt: Data) -> SymmetricKey {
        let hashData = hash.data(using: .utf8)!
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: .init(data: hashData),
            salt: salt,
            info: "Quiebro.FileEncryption".data(using: .utf8)!,
            outputByteCount: 32
        )
    }
    
    func breakFile(_ url: URL) {
        Task { @MainActor in
            self.isLoading = true
            self.uploadState = .processing("Analyzing file...")
            self.progress = 0
            
            do {
                let tempDir = temporaryDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                let fileData = try Data(contentsOf: url)
                let fileSize = fileData.count
                let pieceSize = Int(ceil(Double(fileSize) / 3.0))
                
                let fileId = UUID().uuidString
                let fileName = url.lastPathComponent
                let originalFileHash = calculateHash(fileData)
                
                var pieceUrls: [URL] = []
                
                for i in 0..<3 {
                    self.uploadState = .processing("Processing piece \(i + 1)/3")
                    
                    let startIndex = i * pieceSize
                    let endIndex = min(startIndex + pieceSize, fileSize)
                    let chunk = fileData[startIndex..<endIndex]
                    
                    var processedData = try compressData(Data(chunk))
                    var salt: Data?
                    
                    if isSecureMode {
                        let key = deriveKey(from: originalFileHash, salt: Data()) // Initial salt for key derivation
                        let (encryptedData, encryptionSalt) = try encryptData(processedData, using: key)
                        processedData = encryptedData
                        salt = encryptionSalt
                    }
                    
                    let metadata: [String: Any] = [
                        "uuid": fileId,
                        "index": i,
                        "originalFileName": fileName,
                        "timestamp": Date().ISO8601Format(),
                        "pieceHash": calculateHash(processedData),
                        "originalFileHash": originalFileHash,
                        "originalSize": fileSize,
                        "isCompressed": true,
                        "isEncrypted": isSecureMode,
                        "salt": salt?.base64EncodedString() ?? ""
                    ]
                    
                    let pieceUrl = tempDir.appendingPathComponent("\(fileName)_piece\(i + 1)_\(fileId)")
                    try writePieceToFile(pieceData: processedData, metadata: metadata, to: pieceUrl)
                    pieceUrls.append(pieceUrl)
                    
                    self.progress = Double(i + 1) / 3.0
                }
                
                await MainActor.run {
                    self.pieces = pieceUrls
                    self.isLoading = false
                    self.uploadState = .completed
                    self.progress = 1.0
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.uploadState = .error("Failed to break file: \(error.localizedDescription)")
                    self.progress = 0
                }
            }
        }
    }
    
    private func writePieceToFile(pieceData: Data, metadata: [String: Any], to url: URL) throws {
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var fullPieceData = Data()
        fullPieceData.append(metadataData)
        fullPieceData.append("SEPARATOR".data(using: .utf8)!)
        fullPieceData.append(pieceData)
        try fullPieceData.write(to: url, options: .atomic)
    }
    
    func mendFiles(_ urls: [URL]) {
        Task { @MainActor in
            self.isLoading = true
            self.uploadState = .processing("Starting")
            
            do {
                var pieceDataArray: [(index: Int, data: Data)] = []
                var originalFileName: String?
                var originalFileHash: String?
                var isEncrypted = false
                
                for url in urls {
                    let fullPieceData = try Data(contentsOf: url)
                    
                    guard let separatorRange = fullPieceData.range(of: "SEPARATOR".data(using: .utf8)!) else {
                        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid piece format"])
                    }
                    
                    let metadataData = fullPieceData[..<separatorRange.lowerBound]
                    var pieceData = fullPieceData[separatorRange.upperBound...]
                    
                    guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
                        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid metadata"])
                    }
                    
                    if originalFileHash == nil {
                        originalFileHash = metadata["originalFileHash"] as? String
                        originalFileName = metadata["originalFileName"] as? String
                        isEncrypted = metadata["isEncrypted"] as? Bool ?? false
                    }
                    
                    if isEncrypted {
                        guard let saltString = metadata["salt"] as? String,
                              let salt = Data(base64Encoded: saltString) else {
                            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid encryption salt"])
                        }
                        let key = deriveKey(from: originalFileHash!, salt: Data()) // Initial salt for key derivation
                        pieceData = try decryptData(Data(pieceData), salt: salt, using: key)
                    }
                    
                    guard let index = metadata["index"] as? Int else {
                        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid piece index"])
                    }
                    
                    pieceDataArray.append((index: index, data: try decompressData(pieceData)))
                }
                
                pieceDataArray.sort { $0.index < $1.index }
                
                var finalData = Data()
                for piece in pieceDataArray {
                    finalData.append(piece.data)
                }
                
                let finalHash = calculateHash(finalData)
                guard finalHash == originalFileHash else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "File integrity check failed"])
                }
                
                let tempDir = temporaryDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                guard let originalFileName = originalFileName else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Original filename not found"])
                }
                
                let mendedFileUrl = tempDir.appendingPathComponent(originalFileName)
                try finalData.write(to: mendedFileUrl)
                
                await MainActor.run {
                    self.mendedFile = mendedFileUrl
                    self.isLoading = false
                    self.uploadState = .completed
                    
                    showSavePanel(defaultName: originalFileName)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.uploadState = .error("Failed to mend file: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func showSavePanel(defaultName: String) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = defaultName
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        
        savePanel.begin { [weak self] response in
            guard let self = self,
                  let mendedFile = self.mendedFile,
                  response == .OK,
                  let targetURL = savePanel.url else { return }
            
            do {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: mendedFile, to: targetURL)
                self.clearFiles()
            } catch {
                self.uploadState = .error("Failed to save file: \(error.localizedDescription)")
            }
        }
    }
    
    private func calculateHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func saveAllPieces() {
        Task { @MainActor in
            do {
                let openPanel = NSOpenPanel()
                openPanel.canChooseDirectories = true
                openPanel.canChooseFiles = false
                openPanel.canCreateDirectories = true
                openPanel.message = "Choose where to save the file pieces"
                openPanel.prompt = "Save Pieces"
                
                guard openPanel.runModal() == .OK,
                      let targetDirectory = openPanel.url else {
                    return
                }
                
                self.uploadState = .processing("Saving pieces...")
                self.isLoading = true
                
                for (index, pieceUrl) in pieces.enumerated() {
                    let fileName = pieceUrl.lastPathComponent
                    let destinationUrl = targetDirectory.appendingPathComponent(fileName)
                    
                    if FileManager.default.fileExists(atPath: destinationUrl.path) {
                        try FileManager.default.removeItem(at: destinationUrl)
                    }
                    try FileManager.default.copyItem(at: pieceUrl, to: destinationUrl)
                    
                    self.progress = Double(index + 1) / Double(pieces.count)
                }
                
                self.uploadState = .completed
                self.isLoading = false
                self.progress = 1.0
                
                // Clear after successful save
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.clearFiles()
                }
            } catch {
                self.uploadState = .error("Failed to save pieces: \(error.localizedDescription)")
                self.isLoading = false
                self.progress = 0
            }
        }
    }
}
