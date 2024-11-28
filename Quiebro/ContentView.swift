import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = FileHandlerManager()
    @State private var isDragging = false
    @State private var mode = Mode.breakFile
    
    enum Mode: Hashable {
        case breakFile
        case mend
    }
    
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .headerView, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Picker("Mode", selection: $mode) {
                    Text("Break").tag(Mode.breakFile)
                    Text("Mend").tag(Mode.mend)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.5))
                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                
                ZStack {
                    if mode == .breakFile {
                        if manager.pieces.isEmpty {
                            DropZoneView(isDragging: $isDragging) {
                                handleFileSelection()
                            }
                        } else {
                            VStack {
                                Text("File broken into pieces:")
                                    .font(.headline)
                                ForEach(manager.pieces, id: \.self) { url in
                                    Text(url.lastPathComponent)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                    } else {
                        DropZoneView(isDragging: $isDragging) {
                            handlePieceSelection()
                        }
                    }
                    
                    if manager.isLoading {
                        LoaderView()
                    }
                    
                    if case .error(let message) = manager.uploadState {
                        Text(message)
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                }
                
                if !manager.pieces.isEmpty && mode == .breakFile {
                    ButtonGroup(buttons: [
                        (
                            title: "Save All",
                            icon: "arrow.down.circle",
                            action: savePieces
                        ),
                        (
                            title: "Clear",
                            icon: "trash",
                            action: manager.clearFiles
                        )
                    ])
                    .disabled(manager.isLoading)
                }
            }
            .padding(30)
        }
        .frame(minWidth: 600, minHeight: 700)
        .onDrop(of: [UTType.item], isTargeted: $isDragging) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }
    
    private func handleFileSelection() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                manager.handleFileSelection(url)
            }
        }
    }
    
    private func handlePieceSelection() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        
        panel.begin { response in
            if response == .OK, panel.urls.count == 3 {
                manager.mendFiles(panel.urls)
            } else {
                manager.uploadState = .error("Please select exactly 3 pieces")
            }
        }
    }
    
    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, error in
                guard error == nil else { return }
                
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        if self.mode == .breakFile {
                            self.manager.handleFileSelection(url)
                        } else {
                            // For mend mode, collect URLs and process when we have 3
                            if providers.count == 3 {
                                let urls = providers.compactMap { provider -> URL? in
                                    var result: URL?
                                    let semaphore = DispatchSemaphore(value: 0)
                                    
                                    provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, _ in
                                        result = item as? URL
                                        semaphore.signal()
                                    }
                                    
                                    semaphore.wait()
                                    return result
                                }
                                
                                if urls.count == 3 {
                                    self.manager.mendFiles(urls)
                                }
                            } else {
                                self.manager.uploadState = .error("Please drop exactly 3 pieces")
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func savePieces() {
        for url in manager.pieces {
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.item]
            savePanel.canCreateDirectories = true
            savePanel.isExtensionHidden = false
            savePanel.title = "Save File Piece"
            savePanel.message = "Choose a location to save the file piece"
            savePanel.nameFieldStringValue = url.lastPathComponent
            
            let response = savePanel.runModal()
            
            if response == .OK, let saveUrl = savePanel.url {
                do {
                    try FileManager.default.copyItem(at: url, to: saveUrl)
                } catch {
                    manager.uploadState = .error("Failed to save piece: \(error.localizedDescription)")
                    return
                }
            }
        }
    }
}
