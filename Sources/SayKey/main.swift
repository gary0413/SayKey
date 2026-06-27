import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Foundation

// whisper's initial prompt is a *context primer*, not an instruction it obeys.
// A short, natural sample that mentions the key vocabulary biases spelling far
// better than a long instruction paragraph (which just wastes the 224-token
// budget). The user's own terms are appended below at load time.
private let defaultPrompt = """
以下是繁體中文夾雜 SRE / DevOps 英文術語的值班口述，會出現服務名、CLI 指令與錯誤碼，例如：CloudWatch、kubectl、Terraform、PagerDuty、Datadog、Kubernetes、deployment、rollback、latency、timeout、incident、on-call、p95、5xx。
"""

private let defaultTerms = [
    "SRE",
    "DevOps",
    "AWS",
    "CloudWatch",
    "CloudTrail",
    "ECS",
    "EKS",
    "EC2",
    "ALB",
    "NLB",
    "IAM",
    "VPC",
    "Route 53",
    "RDS",
    "Redis",
    "Kafka",
    "Kubernetes",
    "kubectl",
    "Helm",
    "Terraform",
    "Docker",
    "container",
    "pod",
    "node",
    "deployment",
    "service",
    "ingress",
    "autoscaling",
    "latency",
    "timeout",
    "incident",
    "runbook",
    "playbook",
    "alert",
    "metric",
    "log",
    "trace",
    "span",
    "dashboard",
    "Grafana",
    "Prometheus",
    "Datadog",
    "PagerDuty",
    "on-call",
    "rollback",
    "deploy",
    "CI/CD",
    "GitHub Actions",
    "CLI",
    "SSH",
    "DNS",
    "HTTP",
    "HTTPS",
    "4xx",
    "5xx",
    "p95",
    "p99"
]

private let defaultTermReplacements: [String: String] = [
    "cloud watch": "CloudWatch",
    "cloudwatch": "CloudWatch",
    "cloud trail": "CloudTrail",
    "cloudtrail": "CloudTrail",
    "route fifty three": "Route 53",
    "route 53": "Route 53",
    "cube ctl": "kubectl",
    "cube control": "kubectl",
    "kube ctl": "kubectl",
    "kube control": "kubectl",
    "terra form": "Terraform",
    "terraform": "Terraform",
    "terrafone": "Terraform",
    "terra fone": "Terraform",
    "pager duty": "PagerDuty",
    "pagerduty": "PagerDuty",
    "data dog": "Datadog",
    "prometheus": "Prometheus",
    "grafana": "Grafana",
    "get hub actions": "GitHub Actions",
    "github actions": "GitHub Actions",
    "ci cd": "CI/CD",
    "cicd": "CI/CD",
    "h t t p s": "HTTPS",
    "h t t p": "HTTP",
    "five xx": "5xx",
    "four xx": "4xx",
    "p ninety five": "p95",
    "p ninety nine": "p99"
]

private struct FileConfig: Decodable {
    let whisperBinaryPath: String?
    let modelPath: String?
    let language: String?
    let prompt: String?
    let autoPaste: Bool?
    let contextualTerms: [String]?
    let extraTerms: [String]?
    let termReplacements: [String: String]?

    // whisper's zh training data is mostly Simplified, so it sometimes emits
    // Simplified characters. These convert the output to Taiwan Traditional.
    let convertToTraditional: Bool?
    let openCCBinaryPath: String?
    let openCCConfig: String?

    // Older Apple Speech config keys are tolerated so existing files do not fail.
    let localeIdentifier: String?
    let requiresOnDeviceRecognition: Bool?
}

private struct AppConfig {
    let whisperBinaryPath: String
    let modelPath: String
    let language: String
    let prompt: String
    let autoPaste: Bool
    let termReplacements: [String: String]
    let convertToTraditional: Bool
    let openCCBinaryPath: String
    let openCCConfig: String

    static let configDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".saykey", isDirectory: true)
    static let configFileURL = configDirectoryURL.appendingPathComponent("config.json")
    static let defaultModelURL = configDirectoryURL
        .appendingPathComponent("models", isDirectory: true)
        .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")

    static func load() throws -> AppConfig {
        let fileConfig = try readFileConfig()
        let env = ProcessInfo.processInfo.environment

        let whisperBinaryPath = firstNonEmpty(
            env["SAYKEY_WHISPER_BIN"],
            fileConfig?.whisperBinaryPath
        ) ?? "/opt/homebrew/bin/whisper-cli"

        let modelPath = firstNonEmpty(
            env["SAYKEY_MODEL_PATH"],
            fileConfig?.modelPath
        ) ?? defaultModelURL.path

        let language = firstNonEmpty(
            env["SAYKEY_LANGUAGE"],
            fileConfig?.language
        ) ?? "zh"

        let autoPaste = parseBool(env["SAYKEY_AUTO_PASTE"])
            ?? fileConfig?.autoPaste
            ?? false

        var terms = defaultTerms
        terms.append(contentsOf: fileConfig?.contextualTerms ?? [])
        terms.append(contentsOf: fileConfig?.extraTerms ?? [])
        if let envTerms = env["SAYKEY_TERMS"] {
            terms.append(
                contentsOf: envTerms
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }

        let prompt = firstNonEmpty(
            env["SAYKEY_PROMPT"],
            fileConfig?.prompt
        ) ?? defaultPrompt + "\n額外詞彙: \(deduplicated(terms).joined(separator: ", "))"

        var replacements = defaultTermReplacements
        for (from, to) in fileConfig?.termReplacements ?? [:] {
            replacements[from] = to
        }

        // Default ON: always normalise to Taiwan Traditional Chinese.
        let convertToTraditional = parseBool(env["SAYKEY_TRADITIONAL"])
            ?? fileConfig?.convertToTraditional
            ?? true

        let openCCBinaryPath = firstNonEmpty(
            env["SAYKEY_OPENCC_BIN"],
            fileConfig?.openCCBinaryPath
        ) ?? "/opt/homebrew/bin/opencc"

        // s2twp = Simplified -> Traditional (Taiwan standard) with phrase/idiom
        // conversion (e.g. 软件->軟體, 打印->列印, 鼠标->滑鼠).
        let openCCConfig = firstNonEmpty(
            fileConfig?.openCCConfig
        ) ?? "s2twp.json"

        return AppConfig(
            whisperBinaryPath: NSString(string: whisperBinaryPath).expandingTildeInPath,
            modelPath: NSString(string: modelPath).expandingTildeInPath,
            language: language,
            prompt: prompt,
            autoPaste: autoPaste,
            termReplacements: replacements,
            convertToTraditional: convertToTraditional,
            openCCBinaryPath: NSString(string: openCCBinaryPath).expandingTildeInPath,
            openCCConfig: openCCConfig
        )
    }

    static func ensureTemplateExists() throws -> URL {
        try FileManager.default.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            let template = """
            {
              "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
              "modelPath": "~/.saykey/models/ggml-large-v3-turbo-q5_0.bin",
              "language": "zh",
              "autoPaste": false,
              "convertToTraditional": true,
              "contextualTerms": [
                "SRE",
                "AWS",
                "CloudWatch",
                "kubectl",
                "Terraform",
                "PagerDuty",
                "your-service-name",
                "your-runbook-key",
                "your-internal-acronym"
              ],
              "termReplacements": {
                "cloud watch": "CloudWatch",
                "cube control": "kubectl",
                "terra form": "Terraform"
              }
            }
            """
            try template.write(to: configFileURL, atomically: true, encoding: .utf8)
        }

        return configFileURL
    }

    private static func readFileConfig() throws -> FileConfig? {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FileConfig.self, from: data)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let normalized = value.lowercased()
            guard !seen.contains(normalized) else {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }
}

private enum AppError: LocalizedError {
    case microphoneDenied
    case whisperBinaryMissing(String)
    case whisperModelMissing(String)
    case whisperFailed(String)
    case hotKeyRegistrationFailed(OSStatus)
    case accessibilityDenied
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "SayKey 沒有麥克風權限。請到 macOS Privacy & Security 的 Microphone 開啟權限。"
        case .whisperBinaryMissing(let path):
            return "找不到 whisper-cli：\(path)。請先執行 `brew install whisper-cpp`，或在 ~/.saykey/config.json 設定 whisperBinaryPath。"
        case .whisperModelMissing(let path):
            return "找不到 whisper 模型：\(path)。請執行 ./scripts/install_whisper.sh 下載模型，或在 ~/.saykey/config.json 設定 modelPath。"
        case .whisperFailed(let message):
            return "whisper.cpp 辨識失敗：\(message)"
        case .hotKeyRegistrationFailed(let status):
            return "註冊快捷鍵失敗，可能已被其他 App 佔用。OSStatus: \(status)"
        case .accessibilityDenied:
            return "轉錄文字已放到剪貼簿，但 SayKey 沒有 Accessibility 權限，所以無法自動貼上。若你要讓它辨識完直接補字，請到 macOS Privacy & Security 的 Accessibility 開啟 SayKey。"
        case .emptyTranscript:
            return "沒有辨識到文字。"
        }
    }
}

private enum RecorderState {
    case idle
    case recording
    case transcribing
}

private final class SayKeyApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let toggleMenuItem = NSMenuItem()
    private let lastTranscriptItem = NSMenuItem()

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var autoPasteForCurrentRecognition = false
    private var state: RecorderState = .idle
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hasShownAccessibilityHint = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateStatus(title: "Ready")
        requestMicrophonePermissionIfNeeded()

        do {
            try registerHotKey()
        } catch {
            showError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @objc private func toggleRecordingFromMenu() {
        toggleRecording()
    }

    @objc private func openConfig() {
        do {
            let url = try AppConfig.ensureTemplateExists()
            NSWorkspace.shared.open(url)
        } catch {
            showError(error)
        }
    }

    @objc private func openMicrophoneSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func openAccessibilitySettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureMenu() {
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "SayKey")
                button.imagePosition = .imageOnly
            } else {
                button.title = "SayKey"
            }
        }

        toggleMenuItem.title = "Start Recording (Control-Option-Space)"
        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleRecordingFromMenu)
        menu.addItem(toggleMenuItem)

        lastTranscriptItem.title = "Last transcript: none"
        lastTranscriptItem.isEnabled = false
        menu.addItem(lastTranscriptItem)

        menu.addItem(.separator())

        let configItem = NSMenuItem(title: "Open Config...", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let microphoneItem = NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        microphoneItem.target = self
        menu.addItem(microphoneItem)

        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SayKey", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func registerHotKey() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return noErr
            }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.id == 1 else {
                return noErr
            }

            let app = Unmanaged<SayKeyApp>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                app.toggleRecording()
            }
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            throw AppError.hotKeyRegistrationFailed(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("SKEY"), id: 1)
        let modifiers = UInt32(controlKey | optionKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            throw AppError.hotKeyRegistrationFailed(status)
        }
    }

    private func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            NSSound.beep()
        }
    }

    private func startRecording() {
        let config: AppConfig
        do {
            config = try AppConfig.load()
            try validateWhisper(config)
            if config.autoPaste {
                promptForAccessibilityIfNeeded()
            }
        } catch {
            showError(error)
            return
        }

        requestMicrophoneAccess { [weak self] granted in
            guard let self else {
                return
            }

            guard granted else {
                self.showError(AppError.microphoneDenied)
                return
            }

            do {
                try self.beginRecording(config: config)
            } catch {
                self.showError(error)
            }
        }
    }

    private func beginRecording(config: AppConfig) throws {
        let url = try recordingDirectory()
            .appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        recorder.record()

        self.recorder = recorder
        self.recordingURL = url
        self.recordingStartedAt = Date()
        self.autoPasteForCurrentRecognition = config.autoPaste
        self.state = .recording
        updateStatus(title: "Recording")
    }

    private func stopRecordingAndTranscribe() {
        recorder?.stop()
        recorder = nil

        guard let url = recordingURL else {
            state = .idle
            updateStatus(title: "Ready")
            return
        }

        let duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingURL = nil
        recordingStartedAt = nil

        guard duration > 0.35 else {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            updateStatus(title: "Ready")
            return
        }

        let shouldAutoPaste = autoPasteForCurrentRecognition
        autoPasteForCurrentRecognition = false
        state = .transcribing
        updateStatus(title: "Transcribing")

        Task { [weak self] in
            await self?.transcribeAndDeliver(url: url, autoPaste: shouldAutoPaste)
        }
    }

    private func transcribeAndDeliver(url: URL, autoPaste: Bool) async {
        do {
            let config = try AppConfig.load()
            try validateWhisper(config)
            let rawText = try await WhisperTranscriber.transcribe(fileURL: url, config: config)
            let traditional = TraditionalConverter.convert(rawText, config: config)
            let text = normalizeTranscript(traditional, replacements: config.termReplacements)
            try? FileManager.default.removeItem(at: url)

            await MainActor.run {
                guard !text.isEmpty else {
                    state = .idle
                    updateStatus(title: "Ready")
                    showError(AppError.emptyTranscript)
                    return
                }

                deliverTranscript(text, autoPaste: autoPaste)
                rememberTranscript(text)
                state = .idle
                updateStatus(title: "Ready")
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                state = .idle
                updateStatus(title: "Error")
                showError(error)
            }
        }
    }

    private func validateWhisper(_ config: AppConfig) throws {
        guard FileManager.default.isExecutableFile(atPath: config.whisperBinaryPath) else {
            throw AppError.whisperBinaryMissing(config.whisperBinaryPath)
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw AppError.whisperModelMissing(config.modelPath)
        }
    }

    private func recordingDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SayKey", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func deliverTranscript(_ text: String, autoPaste: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard autoPaste else {
            return
        }

        guard AXIsProcessTrusted() else {
            handleAccessibilityDenied()
            return
        }

        // Give the frontmost app a beat to observe the new clipboard contents
        // before we synthesize Command-V; some text fields read the pasteboard
        // asynchronously and would otherwise paste stale/empty content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.postPasteKeystroke()
        }
    }

    private func postPasteKeystroke() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        )
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        )
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func handleAccessibilityDenied() {
        statusItem.button?.toolTip = "SayKey: 已複製到剪貼簿（缺 Accessibility，無法自動貼上）"

        // Only nag with a modal once per launch; after that just beep so the
        // user is not interrupted on every transcription.
        guard !hasShownAccessibilityHint else {
            NSSound.beep()
            return
        }
        hasShownAccessibilityHint = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "SayKey 需要 Accessibility 權限"
        alert.informativeText = """
        轉錄文字已複製到剪貼簿，但要自動貼到游標位置需要 Accessibility 權限。

        請點「打開設定」→ 在清單裡把 SayKey 打勾 → 之後再說一次話就會自動補字。
        （這個提示本次啟動只會出現一次；在那之前你都能手動按 ⌘V 貼上。）
        """
        alert.addButton(withTitle: "打開設定")
        alert.addButton(withTitle: "稍後")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func rememberTranscript(_ text: String) {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        let preview = compact.count > 50
            ? String(compact.prefix(50)) + "..."
            : compact
        lastTranscriptItem.title = "Last transcript: \(preview)"
    }

    private func updateStatus(title: String) {
        switch state {
        case .idle:
            toggleMenuItem.title = "Start Recording (Control-Option-Space)"
            statusItem.button?.contentTintColor = nil
        case .recording:
            toggleMenuItem.title = "Stop and Transcribe (Control-Option-Space)"
            statusItem.button?.contentTintColor = .systemRed
        case .transcribing:
            toggleMenuItem.title = "Transcribing..."
            statusItem.button?.contentTintColor = .systemBlue
        }

        statusItem.button?.toolTip = "SayKey: \(title)"
    }

    private func requestMicrophonePermissionIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    private func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else {
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func showError(_ error: Error) {
        // A couple of "errors" are routine and should not block with a modal.
        if let appError = error as? AppError {
            switch appError {
            case .emptyTranscript:
                NSSound.beep()
                statusItem.button?.toolTip = "SayKey: 沒有辨識到文字，請再試一次"
                return
            case .accessibilityDenied:
                handleAccessibilityDenied()
                return
            default:
                break
            }
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SayKey"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openSettingsPane(_ string: String) {
        guard let url = URL(string: string) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private enum WhisperTranscriber {
    static func transcribe(fileURL: URL, config: AppConfig) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try transcribeSync(fileURL: fileURL, config: config)
        }.value
    }

    private static func transcribeSync(fileURL: URL, config: AppConfig) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperBinaryPath)
        process.arguments = [
            "-m", config.modelPath,
            "-f", fileURL.path,
            "--language", config.language,
            "--prompt", config.prompt,
            // Beam search + keep-best improve accuracy over greedy decoding.
            "--beam-size", "5",
            "--best-of", "5",
            // Suppress non-speech tokens so imperfect/noisy audio produces fewer
            // garbage characters and hallucinated symbols.
            "--suppress-nst",
            "--no-timestamps",
            "--no-prints"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GGML_METAL_PATH_RESOURCES": "/opt/homebrew/lib"
        ]) { current, _ in current }

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorOutput.isEmpty ? output : errorOutput
            throw AppError.whisperFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let text = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("whisper_") && !$0.hasPrefix("ggml_") && !$0.hasPrefix("load_") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw AppError.emptyTranscript
        }

        return text
    }
}

private enum TraditionalConverter {
    /// Pipes whisper's output through OpenCC to normalise any Simplified
    /// characters to Taiwan Traditional. If OpenCC is disabled or missing, the
    /// text is returned unchanged rather than failing the transcription.
    static func convert(_ text: String, config: AppConfig) -> String {
        guard config.convertToTraditional,
              !text.isEmpty,
              FileManager.default.isExecutableFile(atPath: config.openCCBinaryPath)
        else {
            return text
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.openCCBinaryPath)
        process.arguments = ["-c", config.openCCConfig]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            stdin.fileHandleForWriting.write(Data(text.utf8))
            stdin.fileHandleForWriting.closeFile()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let converted = String(data: outData, encoding: .utf8)
            else {
                return text
            }
            let trimmed = converted.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        } catch {
            return text
        }
    }
}

private func normalizeTranscript(_ rawText: String, replacements: [String: String]) -> String {
    var text = rawText
        .replacingOccurrences(of: "，", with: ", ")
        .replacingOccurrences(of: "。", with: ". ")
        .replacingOccurrences(of: "、", with: ", ")

    for (from, to) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
        text = replaceCaseInsensitive(text, from: from, to: to)
    }

    while text.contains("  ") {
        text = text.replacingOccurrences(of: "  ", with: " ")
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func replaceCaseInsensitive(_ text: String, from: String, to: String) -> String {
    guard !from.isEmpty else {
        return text
    }

    let pattern = NSRegularExpression.escapedPattern(for: from)
    guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
    ) else {
        return text
    }

    // Escape $ and \ so replacement values are treated literally rather than as
    // regex template back-references (e.g. a future term containing "$1").
    let template = NSRegularExpression.escapedTemplate(for: to)
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(
        in: text,
        options: [],
        range: fullRange,
        withTemplate: template
    )
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { result, byte in
        (result << 8) + OSType(byte)
    }
}

private let app = NSApplication.shared
private let delegate = SayKeyApp()
app.delegate = delegate
app.run()
