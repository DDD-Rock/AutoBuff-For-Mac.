import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct ActivationGateView<Content: View>: View {
    @State private var activationCode = LicenseManager.savedActivationCode()
    @State private var isActivated = LicenseManager.isActivated()
    @State private var errorMessage = ""

    let content: () -> Content

    var body: some View {
        if isActivated {
            content()
        } else {
            activationView
        }
    }

    private var activationView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Image(systemName: "lock.open.display")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)

                Text("激活 AutoBuff")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("机器码")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)

                    HStack(spacing: 8) {
                        Text(LicenseManager.currentMachineCode())
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(AppTheme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LicenseManager.currentMachineCode(), forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("复制机器码")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("激活码")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)

                    TextField("粘贴激活码", text: $activationCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit(activate)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: activate) {
                    Text("激活")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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

    private func activate() {
        if LicenseManager.saveActivationCode(activationCode) {
            errorMessage = ""
            isActivated = true
        } else {
            errorMessage = "激活码不正确"
        }
    }
}
