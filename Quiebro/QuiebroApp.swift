import SwiftUI
import AppKit

class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var downloadURL: URL?
    var onUpdateAvailable: (() -> Void)?
    
    func checkForUpdates() {
        // Replace with your actual update checking logic
        guard let url = URL(string: "https://api.github.com/repos/YOUR_USERNAME/Quiebro/releases/latest") else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, as: [String: Any].self),
                  let tagName = json["tag_name"] as? String,
                  let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
                return
            }
            
            // Compare versions and set updateAvailable
            DispatchQueue.main.async {
                self?.updateAvailable = tagName.compare(currentVersion, options: .numeric) == .orderedDescending
                if self?.updateAvailable == true {
                    if let downloadURLString = json["html_url"] as? String {
                        self?.downloadURL = URL(string: downloadURLString)
                    }
                    self?.onUpdateAvailable?()
                }
            }
        }.resume()
    }
}

@main
struct QuiebroApp: App {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var updater = UpdateChecker()
    @State private var showingUpdateSheet = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .background(WindowAccessor())
                .sheet(isPresented: $showingUpdateSheet) {
                    UpdateView(updater: updater)
                }
                .onAppear {
                    updater.checkForUpdates()
                    updater.onUpdateAvailable = {
                        showingUpdateSheet = true
                    }
                }
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    showingUpdateSheet = true
                    updater.checkForUpdates()
                }
                .keyboardShortcut("U", modifiers: [.command])
                
                if updater.updateAvailable {
                    Button("Download Update") {
                        if let url = updater.downloadURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                
                Divider()
            }
        }
    }
}
