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
    
    private func breakFile(_ url: URL) {
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
                
                // Generate master key from file content
                let masterKey = generateMasterKey(from: fileData)
                let keyParts = splitMasterKey(masterKey)
                
                var pieceUrls: [URL] = []
                
                for i in 0..<3 {
                    self.uploadState = .processing("Processing piece \(i + 1)/3")
                    
                    let startIndex = i * pieceSize
                    let endIndex = min(startIndex + pieceSize, fileSize)
                    let chunk = fileData[startIndex..<endIndex]
                    
                    var processedData = try compressData(Data(chunk))
                    var salt: Data?
                    
                    if isSecureMode {
                        salt = generateSalt()
                        let pieceKey = deriveKey(from: keyParts[i], salt: salt!)
                        let sealedBox = try AES.GCM.seal(processedData, using: pieceKey)
                        processedData = sealedBox.combined!
                    }
                    
                    let metadata: [String: Any] = [
                        "uuid": fileId,
                        "index": i,
                        "originalFileName": fileName,
                        "timestamp": Date().ISO8601Format(),
                        "keyPart": keyParts[i].base64EncodedString(),
                        "salt": salt?.base64EncodedString() ?? "",
                        "isEncrypted": isSecureMode
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
    
    private func generateMasterKey(from data: Data) -> Data {
        let hash = SHA256.hash(data: data)
        return Data(hash)
    }
    
    private func splitMasterKey(_ masterKey: Data) -> [Data] {
        var parts: [Data] = []
        let partSize = masterKey.count / 3
        
        for i in 0..<3 {
            let start = i * partSize
            let end = i == 2 ? masterKey.count : start + partSize
            parts.append(masterKey[start..<end])
        }
        
        return parts
    }
    
    func mendFiles(_ urls: [URL]) {
        Task { @MainActor in
            self.isLoading = true
            self.uploadState = .processing("Starting")
            
            do {
                var keyParts: [Data] = []
                var encryptedPieces: [(index: Int, data: Data)] = []
                var originalFileName: String?
                
                // First pass: collect all pieces and metadata
                for url in urls {
                    let (metadata, pieceData) = try extractMetadataAndData(from: url)
                    
                    guard let index = metadata["index"] as? Int,
                          let keyPartString = metadata["keyPart"] as? String,
                          let keyPart = Data(base64Encoded: keyPartString),
                          let saltString = metadata["salt"] as? String,
                          let salt = Data(base64Encoded: saltString),
                          let isEncrypted = metadata["isEncrypted"] as? Bool,
                          let fileName = metadata["originalFileName"] as? String else {
                        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid metadata"])
                    }
                    
                    originalFileName = fileName
                    keyParts.append(keyPart)
                    
                    if isEncrypted {
                        let pieceKey = deriveKey(from: keyPart, salt: salt)
                        let sealedBox = try AES.GCM.SealedBox(combined: pieceData)
                        let decryptedData = try AES.GCM.open(sealedBox, using: pieceKey)
                        let decompressedData = try decompressData(decryptedData)
                        encryptedPieces.append((index: index, data: decompressedData))
                    } else {
                        encryptedPieces.append((index: index, data: try decompressData(pieceData)))
                    }
                    
                    self.progress = Double(encryptedPieces.count) / 3.0
                }
                
                // Sort pieces by index
                encryptedPieces.sort { $0.index < $1.index }
                
                // Combine the pieces
                let combinedData = encryptedPieces.map { $0.data }.reduce(Data(), +)
                
                // Create temporary directory if it doesn't exist
                let tempDir = temporaryDirectory
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
                
                // Save combined file with original filename
                let tempURL = tempDir.appendingPathComponent(originalFileName ?? "mended_file")
                try combinedData.write(to: tempURL, options: .atomic)
                
                await MainActor.run {
                    self.mendedFile = tempURL
                    self.isLoading = false
                    self.uploadState = .completed
                    self.progress = 1.0
                    
                    // Show save panel automatically
                    self.showSavePanel(defaultName: originalFileName ?? "mended_file")
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.uploadState = .error("Failed to mend files: \(error.localizedDescription)")
                    self.progress = 0
                }
            }
        }
    }
    
    private func deriveKey(from keyPart: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: .init(data: keyPart),
            salt: salt,
            info: "Quiebro.FileEncryption".data(using: .utf8)!,
            outputByteCount: 32
        )
    }
    
    private func generateSalt() -> Data {
        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        return salt
    }
    
    private func writePieceToFile(pieceData: Data, metadata: [String: Any], to url: URL) throws {
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var fullPieceData = Data()
        fullPieceData.append(metadataData)
        fullPieceData.append("SEPARATOR".data(using: .utf8)!)
        fullPieceData.append(pieceData)
        try fullPieceData.write(to: url, options: .atomic)
    }
    
    private func extractMetadataAndData(from url: URL) throws -> ([String: Any], Data) {
        let fullPieceData = try Data(contentsOf: url)
        
        guard let separatorRange = fullPieceData.range(of: "SEPARATOR".data(using: .utf8)!) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid piece format"])
        }
        
        let metadataData = fullPieceData[..<separatorRange.lowerBound]
        let pieceData = fullPieceData[separatorRange.upperBound...]
        
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid metadata format"])
        }
        
        return (metadata, Data(pieceData))
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
