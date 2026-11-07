import Security
import SwiftUI

enum Signing {
    static func identity() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "unknown" }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            return SecCertificateCopySubjectSummary(leaf) as String? ?? "certificate"
        }
        return "ad-hoc"
    }
}

@main
struct ShelfApp: App {
    @State private var runner: JobRunner
    @State private var downloads: DownloadsModel

    init() {
        Log.write("launch: \(Bundle.main.bundlePath) pid \(ProcessInfo.processInfo.processIdentifier) signed by \(Signing.identity()) home \(NSHomeDirectory())")
        let runner = JobRunner()
        Log.write("settings: downloads=\(runner.settings.downloads) model=\(runner.settings.model)")
        let downloads = DownloadsModel()
        downloads.watch(URL(fileURLWithPath: runner.settings.downloads))
        _runner = State(initialValue: runner)
        _downloads = State(initialValue: downloads)
        Notifier.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(runner: runner, downloads: downloads)
        } label: {
            if let icon = Brand.image(runner.isBusy ? "menubar-busy" : "menubar", template: true) {
                Image(nsImage: icon)
            } else {
                Image(systemName: "books.vertical")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(runner: runner)
        }
    }
}
