import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class PermissionGuide: ObservableObject {
    enum Request {
        case standalone
        case switchAccount(StoreAccount)
        case checkLogin

        var completionTitle: LocalizedStringResource {
            switch self {
            case .standalone: return .init("common.done", defaultValue: "完成")
            case .switchAccount: return .init("permission.continueSwitch", defaultValue: "继续切换")
            case .checkLogin: return .init("permission.continueCheck", defaultValue: "继续检查")
            }
        }

        var completionMessage: LocalizedStringResource {
            switch self {
            case .standalone: return .init("permission.successGeneral", defaultValue: "现在可以切换 App Store 账号和检查登录状态。")
            case .switchAccount: return .init("permission.successSwitch", defaultValue: "现在可以继续切换 App Store 账号。")
            case .checkLogin: return .init("permission.successCheck", defaultValue: "现在可以继续检查 App Store 的登录状态。")
            }
        }
    }

    enum Page: Equatable {
        case introduction, waiting, troubleshooting(settingsUnavailable: Bool), granted
    }

    @Published var request: Request
    @Published private(set) var page: Page

    init(request: Request, trusted: Bool) {
        self.request = request
        page = trusted ? .granted : .introduction
    }

    func waitForPermission() { page = .waiting }

    func showTroubleshooting() { page = .troubleshooting(settingsUnavailable: false) }

    func settingsDidNotOpen() { page = .troubleshooting(settingsUnavailable: true) }

    func refresh(trusted: Bool) {
        if trusted, page != .granted {
            page = .granted
        } else if !trusted, page == .granted {
            showTroubleshooting()
        }
    }
}

@MainActor
struct PermissionGuideView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .preferred
    @ObservedObject var guide: PermissionGuide
    let openSettings: () -> Void
    let cancel: () -> Void
    let finish: () -> Void

    private var settingsPath: String {
        if #available(macOS 27, *) {
            return language.text(.init("permission.settingsPath27", defaultValue: "隐私与安全 → 设备控制和数据访问"))
        }
        return language.text(.init("permission.settingsPathLegacy", defaultValue: "隐私与安全性 → 辅助功能"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch guide.page {
            case .introduction: introduction
            case .waiting: waiting
            case .troubleshooting(let settingsUnavailable): troubleshooting(settingsUnavailable: settingsUnavailable)
            case .granted: granted
            }
        }
        .padding(24)
        .frame(width: 510, height: 330, alignment: .topLeading)
        .onExitCommand(perform: cancel)
        .task(id: guide.page != .introduction) {
            guard guide.page != .introduction else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guide.refresh(trusted: AXIsProcessTrusted())
            }
        }
        .task(id: guide.page == .waiting) {
            guard guide.page == .waiting else { return }
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard !Task.isCancelled, guide.page == .waiting else { return }
            checkWaitingPermission()
        }
    }

    private func checkWaitingPermission() {
        guide.refresh(trusted: AXIsProcessTrusted())
        if guide.page == .waiting { guide.showTroubleshooting() }
    }

    private var introduction: some View {
        Group {
            HStack(spacing: 12) {
                appIcon(size: 56)
                heading(language.text(.init("permission.introTitle", defaultValue: "开启辅助功能")))
            }
            Text(language.text(.init("permission.purpose", defaultValue: "StoreSwitch 用这项权限检查 App Store 的登录状态，\n并在你切换账号时协助退出与登录。")))
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text(.init("permission.verification", defaultValue: "验证码和触控 ID 仍由你在 Apple 界面完成。")))
                Text(language.text(.init("permission.scope", defaultValue: "macOS 会允许获授权的 App 控制其他应用。\n你可以随时在系统设置中关闭这项权限。")))
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(language.text(.init("common.later", defaultValue: "稍后")), action: cancel)
                Button(language.text(.init("permission.openSettings", defaultValue: "打开系统设置")), action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var waiting: some View {
        Group {
            HStack(spacing: 12) {
                symbol("gear", color: .secondary, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    heading(language.text(.init("permission.turnOn", defaultValue: "打开 StoreSwitch 的开关")))
                    Text(settingsPath).foregroundStyle(.secondary)
                }
            }
            settingsIllustration
            Text(language.text(.init("permission.returnForCheck", defaultValue: "开启后回到这里，StoreSwitch 会自动检查。")))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(language.text(.init("permission.waiting", defaultValue: "等待授权…"))).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button(action: guide.showTroubleshooting) {
                    Label(language.text(.init("permission.help", defaultValue: "授权遇到问题？")), systemImage: "chevron.right")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(language.text(.init("menu.checkAgain", defaultValue: "重新检查")), action: checkWaitingPermission)
                Button(language.text(.init("permission.reopenSettings", defaultValue: "再次打开系统设置")), action: openSettings)
            }
        }
    }

    private var settingsIllustration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text(.init("permission.illustration", defaultValue: "系统设置示意"))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                appIcon(size: 28)
                Text(verbatim: "StoreSwitch").fontWeight(.medium)
                Spacer()
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.28)).frame(width: 34, height: 18)
                    Circle().fill(.white).frame(width: 14, height: 14).padding(.leading, 2)
                }
                .padding(5)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text(.init("permission.illustrationAX", defaultValue: "系统设置示意。打开 StoreSwitch 右侧的开关。")))
    }

    private var granted: some View {
        Group {
            HStack(spacing: 12) {
                symbol("checkmark.circle.fill", color: .green, size: 44)
                heading(language.text(.init("permission.enabled", defaultValue: "辅助功能已开启")))
            }
            Text(language.text(guide.request.completionMessage))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(language.text(guide.request.completionTitle), action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func troubleshooting(settingsUnavailable: Bool) -> some View {
        Group {
            HStack(spacing: 12) {
                symbol("exclamationmark.triangle", color: .secondary, size: 32)
                heading(language.text(.init("permission.notDetected", defaultValue: "仍未检测到授权")))
            }
            if settingsUnavailable {
                Text(language.text(.init("permission.openManually", defaultValue: "请手动打开系统设置，前往「\(settingsPath)」。")))
            }
            recoveryRow(language.text(.init("permission.notListed", defaultValue: "列表中找不到 StoreSwitch")), icon: "plus",
                        detail: language.text(.init("permission.addCurrentApp", defaultValue: "点系统设置里的「＋」，添加当前的 StoreSwitch.app。")))
            recoveryRow(language.text(.init("permission.switchOnNoAccess", defaultValue: "开关已开启，但仍未生效")), icon: "arrow.clockwise",
                        detail: language.text(.init("permission.replaceOldApp", defaultValue: "移除已有条目，再用「＋」添加「在访达中显示」所选中的 StoreSwitch.app，并开启开关。")))
            Spacer(minLength: 0)
            HStack {
                Button(language.text(.init("permission.reopenSettings", defaultValue: "再次打开系统设置")), action: openSettings)
                Spacer()
                Button(language.text(.init("permission.revealInFinder", defaultValue: "在访达中显示"))) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Button(language.text(.init("menu.checkAgain", defaultValue: "重新检查"))) { guide.refresh(trusted: AXIsProcessTrusted()) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func recoveryRow(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            symbol(icon, color: .secondary, size: 15)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    private func symbol(_ name: String, color: Color, size: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: size)).foregroundStyle(color).accessibilityHidden(true)
    }

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
