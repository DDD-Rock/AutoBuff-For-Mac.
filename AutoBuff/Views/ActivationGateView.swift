import AppKit
import SwiftUI

extension Notification.Name {
    static let autoBuffAccountDidLogout = Notification.Name(
        "cc.juanwang.AutoBuff.accountDidLogout"
    )
}

@available(macOS 14.0, *)
@MainActor
struct AccountLoginGateView<Content: View>: View {
    private enum LoginState: Equatable {
        case restoring
        case loggedOut
        case loggedIn
    }

    @State private var loginState: LoginState = .restoring
    @State private var username: String
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var isBusy = false

    private let serverBaseURL: String
    private let client = RemoteMonitorClient()
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        let settings = SettingsManager().load()
        serverBaseURL = settings.monitorServerBaseURL
        _username = State(initialValue: settings.monitorAccountUsername)
        self.content = content
    }

    var body: some View {
        Group {
            if loginState == .loggedIn {
                content()
            } else {
                loginView
            }
        }
        .task {
            await restoreLogin()
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoBuffAccountDidLogout)) { _ in
            password = ""
            errorMessage = ""
            loginState = .loggedOut
        }
    }

    private var loginView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)

                VStack(spacing: 6) {
                    Text("登录 AutoBuff")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("使用监控网页的同一账号登录")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .disabled(isBusy || loginState == .restoring)

                    SecureField("密码（至少 8 位）", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .disabled(isBusy || loginState == .restoring)
                        .onSubmit(login)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: login) {
                    Text(buttonTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    isBusy
                        || loginState == .restoring
                        || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || password.isEmpty
                )

                Button("还没有账号？打开网页注册") {
                    openRegistrationPage()
                }
                .buttonStyle(.link)
                .disabled(loginState == .restoring)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .appCard(padding: 0)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 560)
        .tint(AppTheme.accent)
        .background {
            LinearGradient(
                colors: [AppTheme.background, Color.white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .preferredColorScheme(.light)
    }

    private var buttonTitle: String {
        if loginState == .restoring {
            return "正在恢复登录…"
        }
        return isBusy ? "正在登录…" : "登录"
    }

    private func restoreLogin() async {
        guard loginState == .restoring else { return }
        guard let token = await client.loadStoredAccessToken() else {
            loginState = .loggedOut
            return
        }
        do {
            let account = try await client.restore(
                baseURL: serverBaseURL,
                storedToken: token
            )
            username = account
            persistUsername(account)
            loginState = .loggedIn
        } catch {
            loginState = .loggedOut
            errorMessage = "登录已失效，请重新登录"
        }
    }

    private func login() {
        guard !isBusy else { return }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !password.isEmpty else { return }
        isBusy = true
        errorMessage = ""
        Task {
            defer { isBusy = false }
            do {
                let authenticatedUsername = try await client.authenticate(
                    baseURL: serverBaseURL,
                    username: account,
                    password: password
                )
                username = authenticatedUsername
                password = ""
                persistUsername(authenticatedUsername)
                loginState = .loggedIn
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func persistUsername(_ value: String) {
        let manager = SettingsManager()
        var settings = manager.load()
        settings.monitorAccountUsername = value
        _ = manager.save(settings)
    }

    private func openRegistrationPage() {
        let baseURL = serverBaseURL.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard let url = URL(string: "\(baseURL)/register") else {
            errorMessage = "注册网址无效"
            return
        }
        NSWorkspace.shared.open(url)
    }
}
