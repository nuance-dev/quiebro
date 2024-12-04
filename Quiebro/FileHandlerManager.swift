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
    
    private let debug = true
    private func log(_ message: String) {
        if debug {
            print("🔐 [FileHandler] \(message)")
        }
    }
    
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
            self.uploadState = .processing("Processing file...")
            
            do {
                let fileData = try Data(contentsOf: url)
                log("Original file size: \(fileData.count) bytes")
                
                if isSecureMode {
                    // Generate a single random key for the entire file
                    let key = SymmetricKey(size: .bits256)
                    let keyData = key.withUnsafeBytes { Data($0) }
                    log("Generated master key: size=\(keyData.count), hex=\(keyData.map { String(format: "%02x", $0) }.joined())")
                    
                    // Encrypt the entire file with the key
                    let encryptedData = try encryptFile(fileData, with: key)
                    log("Encrypted file size: \(encryptedData.count) bytes")
                    
                    // Split the key into 3 parts
                    let keyParts = splitKey(keyData)
                    log("Split key into 3 parts")
                    
                    // Create pieces with metadata
                    var pieceUrls: [URL] = []
                    let tempDir = temporaryDirectory
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    // Store the same encrypted data in each piece, but with different key parts
                    for i in 0..<3 {
                        let metadata: [String: Any] = [
                            "index": i,
                            "keyPart": keyParts[i].base64EncodedString(),
                            "partIndex": i,
                            "originalFileName": url.lastPathComponent,
                            "totalPieces": 3,
                            "isSecure": true
                        ]
                        
                        let pieceUrl = tempDir.appendingPathComponent("\(url.lastPathComponent)_piece\(i + 1)")
                        try writePieceToFile(pieceData: encryptedData, metadata: metadata, to: pieceUrl)
                        pieceUrls.append(pieceUrl)
                        log("Created piece \(i + 1)")
                        
                        self.progress = Double(i + 1) / 3.0
                    }
                    
                    await MainActor.run {
                        self.pieces = pieceUrls
                        self.uploadState = .completed
                        self.progress = 1.0
                    }
                } else {
                    // Non-secure mode - just split the file
                    let pieceSize = Int(ceil(Double(fileData.count) / 3.0))
                    var pieceUrls: [URL] = []
                    let tempDir = temporaryDirectory
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    
                    for i in 0..<3 {
                        let startIndex = i * pieceSize
                        let endIndex = min(startIndex + pieceSize, fileData.count)
                        let piece = fileData[startIndex..<endIndex]
                        
                        let metadata: [String: Any] = [
                            "index": i,
                            "originalFileName": url.lastPathComponent,
                            "totalPieces": 3,
                            "totalSize": fileData.count,
                            "isSecure": false
                        ]
                        
                        let pieceUrl = tempDir.appendingPathComponent("\(url.lastPathComponent)_piece\(i + 1)")
                        try writePieceToFile(pieceData: piece, metadata: metadata, to: pieceUrl)
                        pieceUrls.append(pieceUrl)
                        log("Created non-secure piece \(i + 1)")
                        
                        self.progress = Double(i + 1) / 3.0
                    }
                    
                    await MainActor.run {
                        self.pieces = pieceUrls
                        self.uploadState = .completed
                        self.progress = 1.0
                    }
                }
            } catch {
                log("Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.uploadState = .error("Failed to process file: \(error.localizedDescription)")
                }
            }
            self.isLoading = false
        }
    }
    
    // Improved key generation for better security
    private func generateMasterKey() -> Data {
        var keyData = Data(count: 32) // 256-bit key
        _ = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        return keyData
    }
    
    // Improved key splitting for better security
    private func splitKey(_ key: Data) -> [Data] {
        let keyLength = key.count
        let partSize = keyLength / 3
        var parts: [Data] = []
        
        for i in 0..<3 {
            let start = i * partSize
            let end = i == 2 ? keyLength : start + partSize
            let part = key[start..<end]
            log("Split key part \(i): size=\(part.count), hex=\(part.map { String(format: "%02x", $0) }.joined())")
            parts.append(part)
        }
        
        return parts
    }
    
    private func combineKeyParts(_ parts: [Data]) -> SymmetricKey {
        // Sort parts by their index before combining
        let sortedParts = parts.sorted { part1, part2 in
            // The index should be stored in the metadata, this is just a placeholder
            // You'll need to pass the index information along with the parts
            return part1.count < part2.count
        }
        
        let combined = sortedParts.reduce(Data(), +)
        log("Combined key parts: size=\(combined.count), hex=\(combined.map { String(format: "%02x", $0) }.joined())")
        return SymmetricKey(data: combined)
    }
    
    private func encryptFile(_ fileData: Data, with key: SymmetricKey) throws -> Data {
        let keyHex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        log("Encrypting with key: size=\(key.bitCount/8), hex=\(keyHex)")
        
        let nonce = try AES.GCM.Nonce()
        let nonceHex = nonce.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        log("Using nonce: \(nonceHex)")
        
        let sealedBox = try AES.GCM.seal(fileData, using: key, nonce: nonce)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get combined sealed box"])
        }
        
        log("Encryption complete - Input size: \(fileData.count), Output size: \(combined.count)")
        return combined
    }
    
    private func decryptFile(_ encryptedData: Data, with key: SymmetricKey) throws -> Data {
        let keyHex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        log("Decrypting with key: size=\(key.bitCount/8), hex=\(keyHex)")
        
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        log("Created sealed box from encrypted data: \(encryptedData.count) bytes")
        
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        log("Decryption complete - Input size: \(encryptedData.count), Output size: \(decrypted.count)")
        return decrypted
    }
    
    func mendFiles(_ urls: [URL]) {
        Task { @MainActor in
            self.isLoading = true
            self.uploadState = .processing("Reconstructing file...")
            
            do {
                guard urls.count == 3 else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Need exactly 3 pieces"])
                }
                
                let (firstMetadata, firstPieceData) = try extractMetadataAndData(from: urls[0])
                let isSecure = firstMetadata["isSecure"] as? Bool ?? false
                log("Mending in \(isSecure ? "secure" : "non-secure") mode")
                
                if isSecure {
                    var keyParts = Array<Data?>(repeating: nil, count: 3)
                    var originalFileName: String?
                    
                    // Collect all key parts
                    for url in urls {
                        let (metadata, _) = try extractMetadataAndData(from: url)
                        guard let index = metadata["partIndex"] as? Int,
                              let keyPartString = metadata["keyPart"] as? String,
                              let keyPart = Data(base64Encoded: keyPartString) else {
                            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid piece format"])
                        }
                        
                        keyParts[index] = keyPart
                        originalFileName = metadata["originalFileName"] as? String
                        log("Processed key part \(index + 1), size: \(keyPart.count)")
                    }
                    
                    // Ensure all parts are present
                    guard keyParts.allSatisfy({ $0 != nil }) else {
                        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing key parts"])
                    }
                    
                    // Combine the parts in correct order
                    let combinedKey = SymmetricKey(data: keyParts.compactMap { $0 }.reduce(Data(), +))
                    log("Reconstructed key size: \(combinedKey.withUnsafeBytes { Data($0) }.count)")
                    
                    // Use the encrypted data from any piece (they're all the same)
                    let (_, encryptedData) = try extractMetadataAndData(from: urls[0])
                    log("Attempting to decrypt data of size: \(encryptedData.count)")
                    
                    let originalKeyHex = combinedKey.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
                    log("Original encrypted data hash: \(calculateHash(encryptedData))")
                    log("Attempting decryption with reconstructed key: \(originalKeyHex)")
                    
                    let decryptedData = try decryptFile(encryptedData, with: combinedKey)
                    log("Successfully decrypted data, size: \(decryptedData.count)")
                    
                    // Save decrypted file
                    let tempUrl = try saveDecryptedFile(decryptedData, fileName: originalFileName ?? "mended_file")
                    self.mendedFile = tempUrl
                    self.uploadState = .completed
                    self.progress = 1.0
                    
                    showSavePanel(defaultName: originalFileName ?? "mended_file")
                } else {
                    // Non-secure mode - just combine the pieces
                    var filePieces: [(index: Int, data: Data)] = []
                    var originalFileName: String?
                    
                    for url in urls {
                        let (metadata, pieceData) = try extractMetadataAndData(from: url)
                        guard let index = metadata["index"] as? Int,
                              let fileName = metadata["originalFileName"] as? String else {
                            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid piece format"])
                        }
                        
                        originalFileName = fileName
                        filePieces.append((index: index, data: pieceData))
                        log("Processed non-secure piece \(index + 1)")
                    }
                    
                    // Sort pieces by index and combine
                    filePieces.sort { $0.index < $1.index }
                    let combinedData = filePieces.map { $0.data }.reduce(Data(), +)
                    log("Combined pieces, total size: \(combinedData.count) bytes")
                    
                    // Save combined file
                    let tempUrl = temporaryDirectory.appendingPathComponent(originalFileName ?? "mended_file")
                    try combinedData.write(to: tempUrl)
                    
                    self.mendedFile = tempUrl
                    self.uploadState = .completed
                    self.progress = 1.0
                    
                    showSavePanel(defaultName: originalFileName ?? "mended_file")
                }
            } catch {
                log("Decryption error details: \(error)")
                self.uploadState = .error("Failed to reconstruct file: \(error.localizedDescription)")
            }
            self.isLoading = false
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
    
    private func saveDecryptedFile(_ data: Data, fileName: String) throws -> URL {
        let tempDir = temporaryDirectory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileUrl = tempDir.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileUrl)
            log("Successfully saved decrypted file at: \(fileUrl.path)")
        } catch {
            log("Failed to save decrypted file: \(error.localizedDescription)")
            throw error
        }
        
        return fileUrl
    }
}
