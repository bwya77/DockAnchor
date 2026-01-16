import Foundation
import SwiftUI

struct GitHubRelease: Codable {
    let tag_name: String
    let name: String
    let html_url: String
    let body: String
    let published_at: String
}

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isLoading = false
    @Published var lastChecked: Date?
    
    private let currentVersion: String
    private let githubURL = "https://api.github.com/repos/bwya77/DockAnchor/releases/latest"
    private var isManualCheck = false
    
    init() {
        // Get current app version from the same source as the settings display
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.currentVersion = version
        } else {
            self.currentVersion = "1.2" // Fallback
        }
    }
    
    func checkForUpdates(isManual: Bool = false) {
        isLoading = true
        self.isManualCheck = isManual
        
        guard let url = URL(string: githubURL) else {
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    print("Update check failed: \(error)")
                    if self?.isManualCheck == true {
                        self?.showErrorNotification(message: "Could not check for updates. Please check your internet connection.")
                    }
                    return
                }

                guard let data = data else {
                    print("No data received from GitHub API")
                    if self?.isManualCheck == true {
                        self?.showErrorNotification(message: "Could not check for updates. No response from server.")
                    }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    self?.processRelease(release)
                } catch {
                    print("Failed to decode GitHub release: \(error)")
                    if self?.isManualCheck == true {
                        self?.showErrorNotification(message: "Could not check for updates. Invalid response from server.")
                    }
                }
            }
        }.resume()
    }
    
    private func processRelease(_ release: GitHubRelease) {
        let latestVersion = release.tag_name.replacingOccurrences(of: "v", with: "")
        
        if isNewerVersion(latestVersion) {
            DispatchQueue.main.async {
                self.showUpdateNotification(latestVersion: latestVersion, url: release.html_url)
            }
        } else if self.isManualCheck {
            DispatchQueue.main.async {
                self.showNoUpdateNotification()
            }
        }
        
        self.lastChecked = Date()
    }
    
    private func isNewerVersion(_ latestVersion: String) -> Bool {
        let currentComponents = currentVersion.split(separator: ".").compactMap { Int($0) }
        let latestComponents = latestVersion.split(separator: ".").compactMap { Int($0) }
        
        // Ensure both versions have at least major and minor components
        guard currentComponents.count >= 2, latestComponents.count >= 2 else {
            return false
        }
        
        // Compare major version
        if latestComponents[0] > currentComponents[0] {
            return true
        } else if latestComponents[0] < currentComponents[0] {
            return false
        }
        
        // Compare minor version
        if latestComponents[1] > currentComponents[1] {
            return true
        } else if latestComponents[1] < currentComponents[1] {
            return false
        }
        
        // Compare patch version if available
        if currentComponents.count >= 3 && latestComponents.count >= 3 {
            return latestComponents[2] > currentComponents[2]
        }
        
        return false
    }
    
    private func showUpdateNotification(latestVersion: String, url: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Version \(latestVersion) is available. You are running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let updateURL = URL(string: url) {
            NSWorkspace.shared.open(updateURL)
        }
    }
    
    private func showNoUpdateNotification() {
        let alert = NSAlert()
        alert.messageText = "No Updates Available"
        alert.informativeText = "You are already running the latest version of DockAnchor (\(currentVersion))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorNotification(message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
} 