import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var runner: JobRunner
    @State private var accounts: [String] = []
    @State private var accountsError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Send to Kindle") {
                TextField("Kindle address", text: $runner.settings.kindleAddress)
                HStack {
                    TextField("Send from", text: $runner.settings.sender)
                    if !accounts.isEmpty {
                        Picker("", selection: $runner.settings.sender) {
                            ForEach(accounts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 30)
                    }
                    Button("Mail accounts") { loadAccounts() }
                }
                if let accountsError { Text(accountsError).font(.caption).foregroundStyle(.red) }
                Text("The sender must be on Amazon's Approved Personal Document E-mail List. Limit: 50 MB per email.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Send to Kindle is ticked by default", isOn: $runner.settings.sendByDefault)
            }
            Section("Conversion") {
                TextField("Model", text: $runner.settings.model)
                TextField("Downloads folder", text: $runner.settings.downloads)
            }
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLogin(launchAtLogin) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func loadAccounts() {
        do {
            accounts = try KindleMailer.accounts()
            accountsError = accounts.isEmpty ? "Mail has no accounts" : nil
        } catch {
            accountsError = error.localizedDescription
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
