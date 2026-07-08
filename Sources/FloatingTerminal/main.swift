import AppKit
import Foundation

final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command {
                let keyCode = event.charactersIgnoringModifiers?.lowercased() ?? ""
                // Forward standard Edit selectors to the text view so it uses
                // its native, delegate-aware implementation.
                if let tv = firstResponder as? NSTextView {
                    let start = (contentViewController as? TerminalViewController)?.editableInputStart ?? 0
                    let sel = tv.selectedRange()
                    switch keyCode {
                    case "c":
                        // Copy works anywhere (history is selectable).
                        tv.copy(nil)
                        return true
                    case "v":
                        // Only paste within the editable input region.
                        if sel.location >= start {
                            tv.paste(nil)
                        }
                        return true
                    case "x":
                        if sel.location >= start && sel.length > 0 {
                            tv.cut(nil)
                        }
                        return true
                    case "a":
                        // Select only the editable input region, not history.
                        let len = (tv.string as NSString).length - start
                        tv.setSelectedRange(NSRange(location: start, length: max(len, 0)))
                        return true
                    default:
                        break
                    }
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

}

final class CommandExecutor {
    private var process: Process?
    private var pipe: Pipe?

    var onOutput: ((String) -> Void)?
    var onComplete: (() -> Void)?

    var isRunning: Bool { process != nil }

    func run(command: String, workingDirectory: URL) {
        guard process == nil else {
            onOutput?("A command is already running.\n")
            onComplete?()
            return
        }

        let task = Process()
        let outputPipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", command]
        task.currentDirectoryURL = workingDirectory
        task.environment = ProcessInfo.processInfo.environment
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        process = task
        pipe = outputPipe

        let readHandle = outputPipe.fileHandleForReading
        let outputCallback = self.onOutput

        // Read all output until EOF, THEN call completion.
        // This fixes the race where terminationHandler fired before
        // buffered output was drained.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let data = readHandle.availableData
                if data.isEmpty { break }
                let chunk = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    outputCallback?(chunk)
                }
            }
            // Pipe is closed (EOF) — all output has been read.
            // Wait for process to fully exit.
            task.waitUntilExit()
            DispatchQueue.main.async {
                self?.process = nil
                self?.pipe = nil
                self?.onComplete?()
            }
        }

        do {
            try task.run()
        } catch {
            process = nil
            pipe = nil
            onOutput?("Failed to launch: \(error.localizedDescription)\n")
            onComplete?()
        }
    }

    func stop() {
        process?.terminate()
    }
}

final class TerminalViewController: NSViewController, NSTextViewDelegate {
    private var scrollView: NSScrollView!
    private var terminalView: NSTextView!
    private let executor = CommandExecutor()

    private var workingDirectory: URL
    private var history: [String] = []
    private var historyIndex = 0
    private var inputStartIndex = 0
    private var isAppendingProgrammatically = false
    private var isUpdatingSelection = false

    /// Exposed so the hosting panel can guard copy/paste to the input region.
    var editableInputStart: Int { inputStartIndex }

    private let promptColor = NSColor(calibratedRed: 0.40, green: 0.82, blue: 0.52, alpha: 1.0)
    private let textColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)
    private let errorColor = NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.55, alpha: 1.0)
    private let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var onHideRequested: (() -> Void)?

    init() {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        workingDirectory = (try? FileManager.default.url(
            for: .desktopDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? desktop
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.96).cgColor
        rootView.layer?.cornerRadius = 16
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 0
        rootView.appearance = NSAppearance(named: .darkAqua)
        view = rootView

        let scrollable = NSTextView.scrollableTextView()
        scrollView = scrollable
        terminalView = (scrollable.documentView as? NSTextView) ?? NSTextView()
        terminalView.delegate = self
        terminalView.isRichText = false
        terminalView.importsGraphics = false
        terminalView.allowsUndo = false
        terminalView.isEditable = true
        terminalView.isSelectable = true
        terminalView.font = baseFont
        terminalView.backgroundColor = .clear
        terminalView.textColor = textColor
        terminalView.insertionPointColor = textColor
        terminalView.textContainerInset = NSSize(width: 14, height: 14)
        terminalView.textContainer?.widthTracksTextView = true
        terminalView.textContainer?.lineFragmentPadding = 0
        terminalView.isHorizontallyResizable = false
        terminalView.isVerticallyResizable = true
        terminalView.autoresizingMask = [.width]
        terminalView.drawsBackground = false

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 16
        scrollView.layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.isOpaque = false
        scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.scrollerStyle = .overlay

        rootView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        appendPrompt()

        executor.onOutput = { [weak self] chunk in
            self?.appendText(chunk, color: self?.textColor ?? .white)
        }
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
        let end = (terminalView.string as NSString).length
        terminalView.setSelectedRange(NSRange(location: end, length: 0))
    }

    // MARK: - Terminal rendering

    private func promptString() -> String {
        let path = workingDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = path
        if path == home {
            display = "~"
        } else if path.hasPrefix(home + "/") {
            display = "~" + String(path.dropFirst(home.count))
        }
        return "\(display) $ "
    }

    private func appendText(_ text: String, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: color
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        isAppendingProgrammatically = true
        terminalView.textStorage?.append(attr)
        isAppendingProgrammatically = false
        terminalView.scrollToEndOfDocument(nil)
    }

    private func appendPrompt() {
        appendText(promptString(), color: promptColor)
        inputStartIndex = (terminalView.string as NSString).length
        let end = (terminalView.string as NSString).length
        terminalView.setSelectedRange(NSRange(location: end, length: 0))
    }

    // MARK: - Command execution

    private func executeCommand(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        appendText("\n", color: textColor)

        guard !command.isEmpty else {
            appendPrompt()
            return
        }

        history.append(command)
        historyIndex = history.count

        if command == "clear" || command == "cls" {
            clearScreen()
            return
        }

        if command == "cd" || command.hasPrefix("cd ") {
            handleCd(command)
            appendPrompt()
            return
        }

        if command == "exit" || command == "logout" {
            appendText("(Use the menu bar icon → Quit to exit the app.)\n", color: errorColor)
            appendPrompt()
            return
        }

        executor.onComplete = { [weak self] in
            self?.appendPrompt()
        }
        executor.run(command: command, workingDirectory: workingDirectory)
    }

    private func clearScreen() {
        isAppendingProgrammatically = true
        let fullRange = NSRange(location: 0, length: (terminalView.string as NSString).length)
        terminalView.textStorage?.replaceCharacters(in: fullRange, with: "")
        isAppendingProgrammatically = false
        inputStartIndex = 0
        appendPrompt()
    }

    private func handleCd(_ command: String) {
        var arg = command.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if (arg.hasPrefix("\"") && arg.hasSuffix("\"")) || (arg.hasPrefix("'") && arg.hasSuffix("'")) {
            arg = String(arg.dropFirst().dropLast())
        }

        let target: URL
        if arg.isEmpty || arg == "~" {
            target = FileManager.default.homeDirectoryForCurrentUser
        } else if arg.hasPrefix("~/") {
            target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(arg.dropFirst(2)))
        } else if arg.hasPrefix("/") {
            target = URL(fileURLWithPath: String(arg))
        } else {
            target = workingDirectory.appendingPathComponent(String(arg))
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            workingDirectory = target.standardizedFileURL
        } else {
            appendText("cd: no such directory: \(arg)\n", color: errorColor)
        }
    }

    private func navigateHistory(direction: Int) {
        guard !history.isEmpty else { return }
        let newIndex = historyIndex + direction
        guard newIndex >= 0, newIndex <= history.count else { return }
        historyIndex = newIndex
        let cmd = newIndex < history.count ? history[newIndex] : ""
        let full = terminalView.string as NSString
        let range = NSRange(location: inputStartIndex, length: full.length - inputStartIndex)
        isAppendingProgrammatically = true
        terminalView.textStorage?.replaceCharacters(in: range, with: cmd)
        isAppendingProgrammatically = false
        let newLen = (terminalView.string as NSString).length
        terminalView.setSelectedRange(NSRange(location: newLen, length: 0))
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isAppendingProgrammatically { return true }
        if executor.isRunning { return false }
        if replacementString == nil { return true }
        return affectedCharRange.location >= inputStartIndex
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if executor.isRunning { return }
        if isUpdatingSelection { return }
        let sel = terminalView.selectedRange()
        // Only snap the caret (zero-length selection) back into the input
        // region. Allow non-zero selections in history so the user can
        // select and copy previous output.
        if sel.length == 0 && sel.location < inputStartIndex {
            isUpdatingSelection = true
            let end = (terminalView.string as NSString).length
            terminalView.setSelectedRange(NSRange(location: end, length: 0))
            isUpdatingSelection = false
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            performTabCompletion()
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let full = textView.string as NSString
            let command = full.substring(from: inputStartIndex)
            executeCommand(command)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            navigateHistory(direction: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            navigateHistory(direction: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if executor.isRunning {
                executor.stop()
                appendText("^C\n", color: errorColor)
            } else {
                onHideRequested?()
            }
            return true
        }
        return false
    }

    // MARK: - Tab completion

    private func performTabCompletion() {
        if executor.isRunning { return }
        let full = terminalView.string as NSString
        let currentInput = full.substring(from: inputStartIndex)
        guard !currentInput.isEmpty else { return }

        let trimmedInput = currentInput.trimmingCharacters(in: .whitespaces)
        let hasTrailingSpace = currentInput.hasSuffix(" ") && !currentInput.trimmingCharacters(in: .whitespaces).isEmpty

        if !trimmedInput.contains(" ") && !hasTrailingSpace {
            let completions = completeCommand(for: trimmedInput)
            guard !completions.isEmpty else { return }
            if completions.count == 1 {
                replaceCurrentInput(with: completions[0])
            } else {
                let commonPrefixStr = completions.reduce(completions[0]) { partial, next in
                    commonPrefix(of: partial, and: next)
                }
                if commonPrefixStr.count > currentInput.count {
                    replaceCurrentInput(with: commonPrefixStr)
                } else {
                    showCompletionsList(completions, preserveInput: currentInput)
                }
            }
            return
        }

        let parts = currentInput.split(separator: " ", omittingEmptySubsequences: false)
        let cmdPart = String(parts[0])
        let lastArg = parts.count > 1 ? String(parts.last!) : ""
        let argPrefix = parts.count > 1 ? parts.dropLast().map { String($0) }.joined(separator: " ") + " " : ""

        let completions = completePath(partial: hasTrailingSpace ? "" : lastArg, directory: resolveBaseDirectory(hasTrailingSpace ? "" : lastArg))
        guard !completions.isEmpty else { return }

        if completions.count == 1 {
            replaceCurrentInput(with: argPrefix + completions[0])
        } else {
            let commonPrefixStr = completions.reduce(completions[0]) { partial, next in
                commonPrefix(of: partial, and: next)
            }
            let currentArg = hasTrailingSpace ? "" : lastArg
            if commonPrefixStr.count > currentArg.count {
                replaceCurrentInput(with: argPrefix + commonPrefixStr)
            } else {
                showCompletionsList(completions, preserveInput: currentInput)
            }
        }
    }

    private func showCompletionsList(_ completions: [String], preserveInput: String) {
        appendText("\n", color: textColor)
        let display = completions.joined(separator: "  ")
        appendText(display + "\n", color: textColor)
        appendPrompt()
        replaceCurrentInput(with: preserveInput)
    }

    private func replaceCurrentInput(with text: String) {
        let full = terminalView.string as NSString
        let range = NSRange(location: inputStartIndex, length: full.length - inputStartIndex)
        isAppendingProgrammatically = true
        terminalView.textStorage?.replaceCharacters(in: range, with: text)
        isAppendingProgrammatically = false
        let newLen = (terminalView.string as NSString).length
        isUpdatingSelection = true
        terminalView.setSelectedRange(NSRange(location: newLen, length: 0))
        isUpdatingSelection = false
    }

    private func completeCommand(for partial: String) -> [String] {
        if partial.hasPrefix("/") || partial.hasPrefix("~") || partial.hasPrefix(".") {
            return completePath(partial: partial, directory: resolveBaseDirectory(partial))
        }

        var results = [String]()
        let commands = availableCommands()
        for cmd in commands {
            if cmd.hasPrefix(partial) {
                results.append(cmd)
            }
        }
        results.sort()
        return results
    }

    private func resolveBaseDirectory(_ partial: String) -> URL {
        if partial.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
        } else if partial.hasPrefix("/") {
            return URL(fileURLWithPath: "/")
        } else {
            return workingDirectory
        }
    }

    private func completePath(partial: String, directory: URL) -> [String] {
        var baseDir = directory
        var filePart = partial
        var prefixPart = ""

        if partial.hasPrefix("~/") {
            let rest = String(partial.dropFirst(2))
            baseDir = FileManager.default.homeDirectoryForCurrentUser
            if let lastSlash = rest.lastIndex(of: "/") {
                let subPath = String(rest[rest.startIndex...lastSlash])
                baseDir = baseDir.appendingPathComponent(subPath)
                filePart = String(rest[rest.index(after: lastSlash)...])
                prefixPart = "~/" + subPath
            } else {
                filePart = rest
                prefixPart = "~/"
            }
        } else if partial.hasPrefix("/") {
            if let lastSlash = partial.lastIndex(of: "/") {
                let dirPart = String(partial[partial.startIndex...lastSlash])
                if dirPart == "/" {
                    baseDir = URL(fileURLWithPath: "/")
                    prefixPart = "/"
                } else {
                    baseDir = URL(fileURLWithPath: dirPart)
                    prefixPart = dirPart
                }
                filePart = String(partial[partial.index(after: lastSlash)...])
            }
        } else if let lastSlash = partial.lastIndex(of: "/") {
            let subPath = String(partial[partial.startIndex...lastSlash])
            baseDir = workingDirectory.appendingPathComponent(subPath)
            filePart = String(partial[partial.index(after: lastSlash)...])
            prefixPart = subPath
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: baseDir.path) else { return [] }
        var matches = [String]()
        for entry in entries {
            if entry.hasPrefix(filePart) {
                let fullEntryPath = baseDir.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullEntryPath.path, isDirectory: &isDir)
                var display = prefixPart + entry
                if isDir.boolValue { display += "/" }
                matches.append(display)
            }
        }
        matches.sort()
        return matches
    }

    private func availableCommands() -> [String] {
        var cmds = Set<String>([
            "ls", "cd", "pwd", "echo", "cat", "grep", "find", "mkdir", "rm", "cp", "mv",
            "touch", "chmod", "chown", "head", "tail", "wc", "sort", "uniq", "diff",
            "tar", "zip", "unzip", "gzip", "gunzip", "curl", "wget", "ssh", "scp",
            "ping", "ifconfig", "networksetup", "defaults", "open", "pbcopy", "pbpaste",
            "say", "caffeinate", "kill", "killall", "ps", "top", "df", "du", "free",
            "date", "cal", "uptime", "whoami", "id", "sudo", "env", "export", "source",
            "which", "whereis", "type", "alias", "unalias", "history", "jobs", "bg",
            "fg", "nohup", "xargs", "awk", "sed", "tr", "cut", "paste", "column",
            "less", "more", "man", "info", "help", "clear", "cls", "exit", "logout",
            "git", "brew", "npm", "npx", "node", "python3", "python", "pip", "pip3",
            "swift", "xcodebuild", "xcrun", "gem", "rbenv", "cargo", "rustc", "go",
            "java", "javac", "docker", "kubectl", "make", "cmake", "gcc", "clang",
            "sqlite3", "redis-cli", "mongo", "psql", "mysql", "jq", "yq", "htop",
            "tmux", "screen", "vim", "nano", "emacs", "code", "subl", "atom",
            "mdfind", "mdls", "sips", "diskutil", "hdiutil", "launchctl", "pmset",
            "system_profiler", "sysctl", "dscacheutil", "lookupd", "otool", "nm",
            "codesign", "spctl", "xattr", "plutil", "defaults", "screencapture",
            "qlmanage", "textutil", "afconvert", "afinfo", "say", "osascript"
        ])

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: String(dir)) {
                    for entry in entries {
                        let fullPath = "\(dir)/\(entry)"
                        if FileManager.default.isExecutableFile(atPath: fullPath) {
                            cmds.insert(entry)
                        }
                    }
                }
            }
        }
        cmds.insert("clear")
        cmds.insert("cls")
        cmds.insert("cd")
        cmds.insert("exit")
        return Array(cmds).sorted()
    }

    private func commonPrefix(of a: String, and b: String) -> String {
        var result = ""
        let aChars = Array(a)
        let bChars = Array(b)
        for i in 0..<min(aChars.count, bChars.count) {
            if aChars[i] == bChars[i] {
                result.append(aChars[i])
            } else {
                break
            }
        }
        return result
    }
}

final class FloatingTerminalController {
    private let panel: HoverPanel
    private let contentController = TerminalViewController()
    private var pollTimer: Timer?
    private var lastTriggerTime = Date.distantPast

    /// Trigger zone sits in the top-right corner, confined to the menu bar
    /// row (where the system clock lives) so it doesn't overlap app content.
    private let triggerWidth: CGFloat = 170
    private let triggerHeight: CGFloat = 28
    private let handoffDuration: TimeInterval = 0.7
    private let trackingPadding: CGFloat = 16

    init() {
        panel = HoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.contentViewController = contentController
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.isOpaque = false
        panel.contentView?.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.96).cgColor
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true
        panel.contentView?.layer?.shadowColor = NSColor.black.cgColor
        panel.contentView?.layer?.shadowOpacity = 0.35
        panel.contentView?.layer?.shadowRadius = 16
        panel.contentView?.layer?.shadowOffset = NSSize(width: 0, height: -4)
        panel.orderOut(nil)

        contentController.onHideRequested = { [weak self] in
            self?.hidePanel()
        }
    }

    func start() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updatePanelVisibility()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func showManually() {
        let point = NSEvent.mouseLocation
        let screen = screenContaining(point) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        lastTriggerTime = Date()
        showPanel(on: screen)
    }

    private func updatePanelVisibility() {
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen = screenContaining(mouseLocation)
        let inTriggerZone = currentScreen.map { triggerRect(on: $0).contains(mouseLocation) } ?? false
        let insidePanel = panel.isVisible && panel.frame.insetBy(dx: -trackingPadding, dy: -trackingPadding).contains(mouseLocation)
        let withinHandoff = panel.isVisible && Date().timeIntervalSince(lastTriggerTime) < handoffDuration

        if inTriggerZone, let screen = currentScreen {
            lastTriggerTime = Date()
            showPanel(on: screen)
            return
        }

        if insidePanel || withinHandoff {
            return
        }

        hidePanel()
    }

    private func showPanel(on screen: NSScreen) {
        let desiredFrame = panelFrame(on: screen)
        if panel.frame != desiredFrame {
            panel.setFrame(desiredFrame, display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.makeKey()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        contentController.focusTerminal()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private func triggerRect(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        // Anchor to the very top-right corner, limited to the menu bar height.
        return NSRect(
            x: frame.maxX - triggerWidth,
            y: frame.maxY - triggerHeight,
            width: triggerWidth,
            height: triggerHeight
        )
    }

    private func panelFrame(on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(620, max(440, visibleFrame.width - 32))
        let height = min(380, max(260, visibleFrame.height * 0.45))
        return NSRect(
            x: visibleFrame.maxX - width - 16,
            y: visibleFrame.maxY - height - 16,
            width: width,
            height: height
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let terminalController = FloatingTerminalController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        terminalController.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showPanelNow() {
        terminalController.showManually()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Floating Terminal")
            button.toolTip = "Floating Terminal"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Terminal", action: #selector(showPanelNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Floating Terminal", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
