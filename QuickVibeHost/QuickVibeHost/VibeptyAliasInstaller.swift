import Foundation
import SwiftUI

/// 直通输入模式 onboarding 闭环的核心：检测并一键安装 `alias claude='~/.vibepty/bin/vibepty claude'`。
///
/// App 未开启 sandbox（entitlements 无 `com.apple.security.app-sandbox`），因此可直接
/// `Process` 执行 bundle 内的 `install-vibepty.sh` 并读写 `~/.zshrc`。
///
/// 检测范围：**仅 zsh**（macOS 默认）。bash/fish/nushell 用户即便脚本写了 `~/.bashrc`，
/// 此处仍会显示 `.notInstalled` —— UI 文案需明确告知。
@MainActor
final class VibeptyAliasInstaller: ObservableObject {
    /// 必须与 `tools/install-vibepty.sh` 的 ALIAS_MARKER 字节对齐。
    /// 脚本更新时 smoke test 会通过 bundle 读取脚本源码比对，防止漂移。
    static let aliasMarker = "# vibepty-alias (managed by install-vibepty.sh)"
    /// REQ-019: codex alias 独立 marker(与脚本 CODEX_ALIAS_MARKER 字节对齐)
    static let codexAliasMarker = "# vibepty-alias-codex (managed by install-vibepty.sh)"

    enum Status: Equatable {
        case unknown
        case installed
        case notInstalled
        /// `~/.vibepty/bin/vibepty` 存在但 `~/.zshrc` 无 marker
        case partialFileOnly
        /// `~/.zshrc` 有 marker 但可执行文件缺失（被删除或路径变更）
        case partialMarkerOnly
        /// marker + 文件都在，但 marker 下一非空行不是预期的 alias 行（手改/旧路径/命令链/注释）
        case aliasLineBroken
        /// alias 正常，但已安装 wrapper 与当前 App 打包版本不一致
        case versionOutdated
        case detectionError(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var isInstalling: Bool = false
    @Published private(set) var lastInstallLog: String?
    @Published private(set) var lastError: String?

    /// 允许注入 homeURL，smoke test 用 `/tmp` fixture。
    private let homeURL: URL
    private let bundledVibeptyURL: URL?
    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         bundledVibeptyURL: URL? = Bundle.main.url(forResource: "vibepty", withExtension: "py")) {
        self.homeURL = homeURL
        self.bundledVibeptyURL = bundledVibeptyURL
    }

    // MARK: - Paths

    private var vibeptyBinURL: URL { homeURL.appendingPathComponent(".vibepty/bin/vibepty") }
    private var zshrcURL: URL { homeURL.appendingPathComponent(".zshrc") }

    /// 与 `install-vibepty.sh` 的 `ALIAS_LINE="alias claude='$INSTALL_PATH claude'"` 字节对齐。
    /// 任何其他写法（双引号、命令链、拼接、注释）都判定为损坏，避免假阳性。
    private var expectedAliasLine: String {
        "alias claude='\(vibeptyBinURL.path) claude'"
    }
    /// REQ-019: 与脚本 `CODEX_ALIAS_LINE` 字节对齐
    private var expectedCodexAliasLine: String {
        "alias codex='\(vibeptyBinURL.path) codex'"
    }

    // MARK: - Detection

    func refreshStatus() {
        let fm = FileManager.default
        let binExists = fm.fileExists(atPath: vibeptyBinURL.path)

        // ~/.zshrc 不存在 → 视为没写过 marker
        guard fm.fileExists(atPath: zshrcURL.path) else {
            status = binExists ? .partialFileOnly : .notInstalled
            return
        }

        let contents: String
        do {
            contents = try String(contentsOf: zshrcURL, encoding: .utf8)
        } catch {
            status = .detectionError(AppL10n.format("读取 ~/.zshrc 失败：%@", error.localizedDescription))
            return
        }

        let markerPresent = contents.contains(Self.aliasMarker)
        guard markerPresent else {
            status = binExists ? .partialFileOnly : .notInstalled
            return
        }

        // REQ-019: installed 要求 claude + codex 两条 alias 都完好;
        // codex marker 缺失(旧版安装)归为 aliasLineBroken,重装即补齐。
        let aliasLineValid = isAliasLineExact(in: contents, marker: Self.aliasMarker,
                                              expected: expectedAliasLine)
            && isAliasLineExact(in: contents, marker: Self.codexAliasMarker,
                                expected: expectedCodexAliasLine)

        switch (binExists, aliasLineValid) {
        case (true, true):   status = installedVibeptyMatchesBundle() ? .installed : .versionOutdated
        case (true, false):  status = .aliasLineBroken
        case (false, _):     status = .partialMarkerOnly
        }
    }

    private func installedVibeptyMatchesBundle() -> Bool {
        guard let bundledVibeptyURL else { return true }
        guard let installed = try? Data(contentsOf: vibeptyBinURL),
              let bundled = try? Data(contentsOf: bundledVibeptyURL) else {
            return false
        }
        return installed == bundled
    }

    /// 找到 marker 行（trim 后等于 marker）后，向下扫描第一行非空白内容，
    /// 要求 trim 后**字节完全等于** expected。
    /// 拒绝：注释行、双引号变体、命令链、旧路径。
    private func isAliasLineExact(in contents: String, marker: String, expected: String) -> Bool {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == marker
        }) else { return false }

        for i in (markerIdx + 1)..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            return line == expected
        }
        return false
    }

    // MARK: - Install

    func install() async {
        isInstalling = true
        defer { isInstalling = false }
        lastError = nil
        lastInstallLog = nil

        guard let scriptURL = Bundle.main.url(forResource: "install-vibepty", withExtension: "sh"),
              let pyURL = Bundle.main.url(forResource: "vibepty", withExtension: "py") else {
            lastError = AppL10n.tr("安装资源未打包（install-vibepty.sh / vibepty.py）")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibepty-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let scriptDst = tempDir.appendingPathComponent("install-vibepty.sh")
            let pyDst = tempDir.appendingPathComponent("vibepty.py")
            try FileManager.default.copyItem(at: scriptURL, to: scriptDst)
            try FileManager.default.copyItem(at: pyURL, to: pyDst)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptDst.path)
            try await runInstallScript(scriptPath: scriptDst.path)
        } catch {
            lastError = AppL10n.format("安装失败：%@", error.localizedDescription)
        }

        refreshStatus()
    }

    /// 用 `/bin/bash <script>` 执行（避开 shebang/执行权限在代码签名下的差异），
    /// `HOME` 被显式覆盖为 `homeURL.path`，确保 smoke test 时子进程写入 fixture 而非真实 ~。
    private func runInstallScript(scriptPath: String) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath]

        // 关键：生产环境下 homeURL == FileManager.homeDirectoryForCurrentUser，行为不变；
        // 测试环境下 homeURL = fixture，子进程不会污染真实 ~/.zshrc。
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = homeURL.path
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let collector = OutputCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await collector.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await collector.append(chunk) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { proc in
                // 1. 先卸掉 readabilityHandler（防止 drain 时 handler 还在触发，导致并发写同一 Data）
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // 2. 排空残余数据（readabilityHandler 不保证读到 EOF）
                Task {
                    await collector.drain(from: stdoutPipe.fileHandleForReading)
                    await collector.drain(from: stderrPipe.fileHandleForReading)
                    let log = await collector.decoded()
                    await MainActor.run { [weak self] in
                        self?.lastInstallLog = log
                    }
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "VibeptyAliasInstaller",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey:
                                "install-vibepty.sh exited with status \(proc.terminationStatus)"]
                        ))
                    }
                }
            }
            do {
                try proc.run()
            } catch {
                // 启动失败也要清 handler，避免泄漏
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}

/// 子进程输出收集器。用 actor 隔离，避免 `readabilityHandler` 闭包里的并发写入。
/// 只保留尾部 4KB（足以看出错误，避免巨型 ScrollView）。
private actor OutputCollector {
    private var buf = Data()

    func append(_ data: Data) { buf.append(data) }

    /// 进程退出后一次性排空 pipe（readabilityHandler 非保证读到 EOF）。
    func drain(from handle: FileHandle) {
        let rest = handle.availableData
        if !rest.isEmpty { buf.append(rest) }
    }

    func decoded(maxTailBytes: Int = 4096) -> String {
        let tail = buf.suffix(maxTailBytes)
        return String(data: Data(tail), encoding: .utf8) ?? "<binary>"
    }
}
