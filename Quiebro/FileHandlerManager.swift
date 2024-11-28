import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

class FileHandlerManager: ObservableObject {
    @Published var isLoading = false
    @Published var inputFile: URL?
    @Published var pieces: [URL] = []
    @Published var uploadState: UploadState = .idle
    
    enum UploadState {
        case idle
        case uploading
        case processing
        case completed
        case error(String)
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
        uploadState = .idle
        isLoading = false
    }
    
    private func generateSecureUUID() -> String {
        UUID().uuidString
    }
    
    private func calculateHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func breakFile(_ url: URL) {
        Task { @MainActor in
            self.isLoading = true
            self.uploadState = .processing
            
            do {
                let data = try Data(contentsOf: url)
                let pieceSize = (data.count + 2) / 3 // Split into 3 roughly equal pieces
                
                let originalFileHash = calculateHash(data)
                let fileId = generateSecureUUID()
                let fileName = url.lastPathComponent
                
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                var pieceUrls: [URL] = []
                
                for i in 0..<3 {
                    let start = i * pieceSize
                    let end = min(start + pieceSize, data.count)
                    let pieceData = data[start..<end]
                    
                    // Create metadata
                    let metadata = [
                        "uuid": fileId,
                        "index": i,
                        "originalFileHash": originalFileHash,
                        "originalFileName": fileName,
                        "timestamp": Date().ISO8601Format(),
                        "pieceHash": calculateHash(pieceData)
                    ]
                    
                    let metadataData = try JSONSerialization.data(withJSONObject: metadata)
                    
                    // Combine metadata and piece data
                    var fullPieceData = Data()
                    fullPieceData.append(metadataData)
                    fullPieceData.append("SEPARATOR".data(using: .utf8)!)
                    fullPieceData.append(pieceData)
                    
                    let pieceUrl = documentsDirectory.appendingPathComponent("\(fileName)_piece\(i + 1)_\(fileId)")
                    try fullPieceData.write(to: pieceUrl)
                    pieceUrls.append(pieceUrl)
                }
                
                await MainActor.run {
                    self.pieces = pieceUrls
                    self.isLoading = false
                    self.uploadState = .completed
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.uploadState = .error("Failed to break file: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func mendFiles(_ urls: [URL]) {
        Task { @MainActor in
            self.isLoading = true
            self.uploadState = .processing
            
            do {
                var pieceDataArray: [(index: Int, data: Data)] = []
                var originalFileName: String?
                var originalFileHash: String?
                
                for url in urls {
                    let fullPieceData = try Data(contentsOf: url)
                    
                    guard let separatorRange = fullPieceData.range(of: "SEPARATOR".data(using: .utf8)!) else {
                        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid piece format"])
                    }
                    
                    let metadataData = fullPieceData[..<separatorRange.lowerBound]
                    let pieceData = fullPieceData[separatorRange.upperBound...]
                    
                    let metadata = try JSONSerialization.jsonObject(with: metadataData) as! [String: Any]
                    
                    if originalFileHash == nil {
                        originalFileHash = metadata["originalFileHash"] as? String
                        originalFileName = metadata["originalFileName"] as? String
                    }
                    
                    let index = metadata["index"] as! Int
                    pieceDataArray.append((index: index, data: pieceData))
                }
                
                // Sort pieces by index
                pieceDataArray.sort { $0.index < $1.index }
                
                // Combine pieces
                var finalData = Data()
                for piece in pieceDataArray {
                    finalData.append(piece.data)
                }
                
                // Verify final hash
                let finalHash = calculateHash(finalData)
                guard finalHash == originalFileHash else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "File integrity check failed"])
                }
                
                // Save merged file
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let mergedFileUrl = documentsDirectory.appendingPathComponent("restored_\(originalFileName ?? "file")")
                try finalData.write(to: mergedFileUrl)
                
                await MainActor.run {
                    self.isLoading = false
                    self.uploadState = .completed
                    self.pieces = []
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.uploadState = .error("Failed to mend file: \(error.localizedDescription)")
                }
            }
        }
    }
}
