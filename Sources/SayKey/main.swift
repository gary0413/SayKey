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

    // Voice Activity Detection: filters out silence/noise before the encoder so
    // quiet or empty clips stop producing hallucinated captions.
    let enableVAD: Bool?
    let vadModelPath: String?

    // Play a short sound when a transcript is ready (the main "done" cue in
    // clipboard-only mode).
    let soundFeedback: Bool?

    // Keep a warm whisper-server running so the model is loaded once instead of
    // re-loaded (~300ms) on every utterance. Falls back to the CLI if the
    // server isn't up yet or fails.
    let useServer: Bool?
    let whisperServerBinaryPath: String?

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
    let enableVAD: Bool
    let vadModelPath: String
    let soundFeedback: Bool
    let useServer: Bool
    let whisperServerBinaryPath: String

    static let configDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".saykey", isDirectory: true)
    static let configFileURL = configDirectoryURL.appendingPathComponent("config.json")
    static let modelsDirectoryURL = configDirectoryURL
        .appendingPathComponent("models", isDirectory: true)
    static let defaultModelURL = modelsDirectoryURL
        .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
    static let defaultVADModelURL = modelsDirectoryURL
        .appendingPathComponent("ggml-silero-v6.2.0.bin")

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

        // Only the user's OWN vocabulary is worth appending to the prompt. The
        // generic term list is already covered by the primer, and a long comma
        // list dilutes the primer and burns whisper's ~224-token budget, so we
        // append at most a handful of the user's real terms (service names,
        // internal acronyms) as a natural context line.
        var userTerms = fileConfig?.contextualTerms ?? []
        userTerms.append(contentsOf: fileConfig?.extraTerms ?? [])
        if let envTerms = env["SAYKEY_TERMS"] {
            userTerms.append(
                contentsOf: envTerms
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        let cappedTerms = Array(deduplicated(userTerms).prefix(20))

        let prompt = firstNonEmpty(
            env["SAYKEY_PROMPT"],
            fileConfig?.prompt
        ) ?? (cappedTerms.isEmpty
            ? defaultPrompt
            : defaultPrompt + "\n常用詞彙：" + cappedTerms.joined(separator: "、"))

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

        // VAD is on by default; it only actually runs if the model file is present.
        let enableVAD = parseBool(env["SAYKEY_VAD"])
            ?? fileConfig?.enableVAD
            ?? true

        let vadModelPath = firstNonEmpty(
            env["SAYKEY_VAD_MODEL"],
            fileConfig?.vadModelPath
        ) ?? defaultVADModelURL.path

        let soundFeedback = parseBool(env["SAYKEY_SOUND"])
            ?? fileConfig?.soundFeedback
            ?? true

        let useServer = parseBool(env["SAYKEY_USE_SERVER"])
            ?? fileConfig?.useServer
            ?? true

        let whisperServerBinaryPath = firstNonEmpty(
            env["SAYKEY_WHISPER_SERVER_BIN"],
            fileConfig?.whisperServerBinaryPath
        ) ?? "/opt/homebrew/bin/whisper-server"

        return AppConfig(
            whisperBinaryPath: NSString(string: whisperBinaryPath).expandingTildeInPath,
            modelPath: NSString(string: modelPath).expandingTildeInPath,
            language: language,
            prompt: prompt,
            autoPaste: autoPaste,
            termReplacements: replacements,
            convertToTraditional: convertToTraditional,
            openCCBinaryPath: NSString(string: openCCBinaryPath).expandingTildeInPath,
            openCCConfig: openCCConfig,
            enableVAD: enableVAD,
            vadModelPath: NSString(string: vadModelPath).expandingTildeInPath,
            soundFeedback: soundFeedback,
            useServer: useServer,
            whisperServerBinaryPath: NSString(string: whisperServerBinaryPath).expandingTildeInPath
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
              "enableVAD": true,
              "soundFeedback": true,
              "useServer": true,
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
    private let repasteMenuItem = NSMenuItem()
    private let autoPasteMenuItem = NSMenuItem()
    private let hud = RecordingHUD()

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var autoPasteForCurrentRecognition = false
    private var state: RecorderState = .idle
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hasShownAccessibilityHint = false
    private var lastTranscript: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateStatus(title: "Ready")
        requestMicrophonePermissionIfNeeded()

        // Warm the whisper server so the first (and every) utterance skips the
        // ~300ms model reload. Safe if it fails — transcription falls back to CLI.
        if let config = try? AppConfig.load() {
            WhisperServerManager.shared.startIfNeeded(config: config)
        }

        do {
            try registerHotKey()
        } catch {
            showError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        WhisperServerManager.shared.stop()
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

    @objc private func toggleAutoPaste() {
        let newValue = autoPasteMenuItem.state != .on
        persistAutoPaste(newValue)
        autoPasteMenuItem.state = newValue ? .on : .off
        // Enabling auto-paste needs Accessibility; prompt now rather than making
        // the user discover it fails on the next recording.
        if newValue {
            promptForAccessibilityIfNeeded()
        }
    }

    /// Flips `autoPaste` in config.json, preserving every other key.
    private func persistAutoPaste(_ enabled: Bool) {
        let url = (try? AppConfig.ensureTemplateExists()) ?? AppConfig.configFileURL
        guard
            let data = try? Data(contentsOf: url),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }
        object["autoPaste"] = enabled
        if let out = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? out.write(to: url)
        }
    }

    @objc private func repasteLast() {
        guard let text = lastTranscript else {
            return
        }
        let autoPaste = (try? AppConfig.load())?.autoPaste ?? false
        deliverTranscript(text, autoPaste: autoPaste)
    }

    private func playDoneSound() {
        NSSound(named: NSSound.Name("Pop"))?.play()
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

        lastTranscriptItem.title = "上一句：（尚無）"
        lastTranscriptItem.isEnabled = false
        menu.addItem(lastTranscriptItem)

        repasteMenuItem.title = "重貼上一句"
        repasteMenuItem.target = self
        repasteMenuItem.action = #selector(repasteLast)
        repasteMenuItem.isEnabled = false
        menu.addItem(repasteMenuItem)

        menu.addItem(.separator())

        autoPasteMenuItem.title = "自動貼上（需 Accessibility）"
        autoPasteMenuItem.target = self
        autoPasteMenuItem.action = #selector(toggleAutoPaste)
        autoPasteMenuItem.state = ((try? AppConfig.load())?.autoPaste ?? false) ? .on : .off
        menu.addItem(autoPasteMenuItem)

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
            // Prefer the warm server (model already loaded); fall back to the CLI
            // if it isn't ready yet or errors. An empty string is a valid result
            // (VAD filtered silence) and must NOT trigger the fallback.
            let rawText: String
            if let serverText = try? WhisperServerManager.shared.transcribe(fileURL: url) {
                rawText = serverText
            } else {
                rawText = try await WhisperTranscriber.transcribe(fileURL: url, config: config)
            }
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
                if config.soundFeedback {
                    playDoneSound()
                }
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
        lastTranscript = text
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        let preview = compact.count > 40
            ? String(compact.prefix(40)) + "…"
            : compact
        lastTranscriptItem.title = "上一句：\(preview)"
        repasteMenuItem.isEnabled = true
    }

    private func updateStatus(title: String) {
        switch state {
        case .idle:
            toggleMenuItem.title = "開始錄音（Control-Option-Space）"
            statusItem.button?.contentTintColor = nil
            setStatusIcon("mic")
            hud.hide()
        case .recording:
            toggleMenuItem.title = "停止並辨識（Control-Option-Space）"
            statusItem.button?.contentTintColor = .systemRed
            setStatusIcon("mic.fill")
            hud.show("🔴 錄音中… 再按一次快捷鍵停止")
        case .transcribing:
            toggleMenuItem.title = "辨識中…"
            statusItem.button?.contentTintColor = .systemBlue
            setStatusIcon("waveform")
            hud.show("⏳ 辨識中…")
        }

        statusItem.button?.toolTip = "SayKey: \(title)"
    }

    private func setStatusIcon(_ symbolName: String) {
        guard #available(macOS 11.0, *), let button = statusItem.button else {
            return
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SayKey")
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

/// Keeps a single `whisper-server` process warm so the model is loaded once at
/// launch instead of re-loaded (~300ms) on every utterance. Transcription is a
/// local HTTP POST to `/inference`. Everything degrades to the per-utterance CLI
/// path if the server isn't up, so this is a pure latency optimisation that can
/// never break transcription.
private final class WhisperServerManager {
    static let shared = WhisperServerManager()

    private enum ServerError: Error { case notReady, timeout, badStatus(Int) }

    private let lock = NSLock()
    private var process: Process?
    private var ready = false
    private let port = 8471

    private var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func startIfNeeded(config: AppConfig) {
        guard config.useServer else { return }
        lock.lock()
        let alreadyStarted = process != nil
        lock.unlock()
        guard !alreadyStarted else { return }

        guard FileManager.default.isExecutableFile(atPath: config.whisperServerBinaryPath),
              FileManager.default.fileExists(atPath: config.modelPath) else {
            return
        }

        var arguments = [
            "-m", config.modelPath,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--language", config.language,
            "--prompt", config.prompt,
            "--beam-size", "5",
            "--suppress-nst"
        ]
        if config.enableVAD, FileManager.default.fileExists(atPath: config.vadModelPath) {
            arguments += ["--vad", "--vad-model", config.vadModelPath, "--vad-speech-pad-ms", "200"]
        }

        // Free the port in case a previous run was force-quit and orphaned its
        // server (children aren't auto-reaped on macOS). Best-effort.
        freeStalePort()

        let server = Process()
        server.executableURL = URL(fileURLWithPath: config.whisperServerBinaryPath)
        server.arguments = arguments
        // Discard server logs; readiness is checked over HTTP, so there's no pipe
        // to keep drained.
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        server.environment = ProcessInfo.processInfo.environment.merging([
            "GGML_METAL_PATH_RESOURCES": "/opt/homebrew/lib"
        ]) { current, _ in current }
        server.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.ready = false
            self.process = nil
            self.lock.unlock()
        }

        do {
            try server.run()
        } catch {
            return
        }

        lock.lock()
        process = server
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.waitUntilReady()
        }
    }

    func stop() {
        lock.lock()
        let server = process
        process = nil
        ready = false
        lock.unlock()
        server?.terminate()
    }

    private func freeStalePort() {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/sh")
        killer.arguments = ["-c", "lsof -ti tcp:\(port) | xargs kill -9 2>/dev/null || true"]
        try? killer.run()
        killer.waitUntilExit()
    }

    private func waitUntilReady() {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if ping() {
                lock.lock(); ready = true; lock.unlock()
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private func ping() -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        var up = false
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            // Any HTTP response (even 404) means the port is accepting.
            if error == nil || response != nil { up = true }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        return up
    }

    /// Synchronous POST to the warm server. Callers run this off the main thread.
    func transcribe(fileURL: URL) throws -> String {
        guard isReady else { throw ServerError.notReady }

        let boundary = "saykey-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 125
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let audio = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        for (name, value) in [("response_format", "json"), ("temperature", "0")] {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpError: Error?
        var status = 0
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            httpError = error
            if let http = response as? HTTPURLResponse { status = http.statusCode }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 130) == .timedOut {
            task.cancel()
            throw ServerError.timeout
        }
        if let httpError { throw httpError }
        guard status == 200, let data = responseData else {
            throw ServerError.badStatus(status)
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private enum WhisperTranscriber {
    static func transcribe(fileURL: URL, config: AppConfig) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try transcribeSync(fileURL: fileURL, config: config)
        }.value
    }

    /// Hard cap on a single transcription. whisper-turbo does short clips in
    /// ~1s; anything past this means a stuck child, which we kill so the app's
    /// state machine can never wedge permanently in `.transcribing`.
    private static let timeout: TimeInterval = 120

    private static func transcribeSync(fileURL: URL, config: AppConfig) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperBinaryPath)

        var arguments = [
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
        // Voice Activity Detection strips silence/noise before the encoder — the
        // most effective fix for hallucinated captions on quiet/empty clips
        // (push-to-talk users often pause before speaking). Only added if the
        // VAD model is actually present, so a missing model degrades gracefully.
        if config.enableVAD, FileManager.default.fileExists(atPath: config.vadModelPath) {
            arguments += ["--vad", "--vad-model", config.vadModelPath, "--vad-speech-pad-ms", "200"]
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GGML_METAL_PATH_RESOURCES": "/opt/homebrew/lib"
        ]) { current, _ in current }

        let (output, errorOutput, timedOut) = try runWithTimeout(process, stdout: stdout, stderr: stderr)

        if timedOut {
            throw AppError.whisperFailed("辨識逾時（超過 \(Int(timeout)) 秒），已中止。請確認模型與音檔正常。")
        }
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

    /// Runs `process`, draining stdout/stderr concurrently (so a full pipe
    /// buffer can never block exit) and enforcing a wall-clock timeout. On
    /// timeout the child is terminated, then SIGKILLed if it ignores that.
    private static func runWithTimeout(
        _ process: Process,
        stdout: Pipe,
        stderr: Pipe
    ) throws -> (output: String, error: String, timedOut: Bool) {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        var outData = Data()
        var errData = Data()
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "app.saykey.whisper.io", attributes: .concurrent)
        ioGroup.enter()
        ioQueue.async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }
        ioGroup.enter()
        ioQueue.async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }

        ioGroup.wait()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            timedOut
        )
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
            // Write stdin on a background queue while we drain stdout on this
            // one. Doing both inline would deadlock on long transcripts once
            // OpenCC fills its stdout pipe buffer before we start reading.
            let inputData = Data(text.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                stdin.fileHandleForWriting.write(inputData)
                stdin.fileHandleForWriting.closeFile()
            }
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
        // whisper (esp. the server) breaks segments with newlines; for
        // dictation-into-a-field these should be spaces, not line breaks.
        .replacingOccurrences(of: "\n", with: " ")
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

/// A small borderless floating pill near the bottom of the screen that tells the
/// user, in their line of sight, whether SayKey is recording or transcribing —
/// the menu-bar tint alone is too easy to miss for a push-to-talk tool.
private final class RecordingHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String) {
        DispatchQueue.main.async { self.present(text) }
    }

    func hide() {
        DispatchQueue.main.async { self.panel?.orderOut(nil) }
    }

    private func present(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        label.stringValue = text
        label.sizeToFit()
        let width = max(180, label.frame.width + 48)
        let height: CGFloat = 46

        if let screen = NSScreen.main {
            let x = screen.frame.midX - width / 2
            let y = screen.frame.minY + 150
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        label.frame = NSRect(x: 24, y: (height - 22) / 2, width: width - 48, height: 22)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        container.addSubview(label)

        panel.contentView = container
        return panel
    }
}

private let app = NSApplication.shared
private let delegate = SayKeyApp()
app.delegate = delegate
app.run()
