import AppKit
import Darwin
import Foundation

// Swift marks fork() unavailable to discourage misuse with threads, but we
// need the real POSIX fork() to set up the PTY controlling terminal before
// exec'ing the shell. We call the underlying C symbol directly.
@_silgen_name("fork")
private func posixFork() -> pid_t

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

/// Runs shell commands attached to a real pseudo-terminal (PTY) instead of a
/// plain pipe. This is required for interactive programs like `python3`,
/// `ssh`, `vim`, pagers, etc. — they check `isatty()` on their stdout and
/// switch to line-buffered/raw behavior (prompts, colors, cursor control)
/// only when connected to a TTY. A plain Pipe makes them fully-buffered,
/// which is why output like the Python `>>>` prompt never showed up.
final class CommandExecutor {
    /// Child process ID (-1 when not running).
    private var childPID: pid_t = -1
    private var masterHandle: FileHandle?
    private var childWatchSource: DispatchSourceProcess?
    /// Leftover bytes from a previous read that didn't end on a UTF-8
    /// character boundary. Held until more data arrives so multi-byte
    /// characters (e.g. Chinese) aren't split and rendered as '?'.
    private var pendingData = Data()

    var onOutput: ((String) -> Void)?
    var onComplete: (() -> Void)?

    var isRunning: Bool { childPID != -1 }

    func run(command: String, workingDirectory: URL) {
        guard childPID == -1 else {
            onOutput?("A command is already running.\n")
            onComplete?()
            return
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
            onOutput?("Failed to allocate a pseudo-terminal.\n")
            onComplete?()
            return
        }

        // Build environment for the child.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        let userName = ProcessInfo.processInfo.userName
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if env["USER"] == nil || env["USER"]!.isEmpty { env["USER"] = userName }
        if env["LOGNAME"] == nil || env["LOGNAME"]!.isEmpty { env["LOGNAME"] = userName }
        if env["HOME"] == nil || env["HOME"]!.isEmpty { env["HOME"] = homeDir }
        // Remove any askpass helpers – sudo must read via the PTY tty.
        env.removeValue(forKey: "SUDO_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS")

        // Convert env dict to C-string array expected by execve.
        let envCStrings: [UnsafeMutablePointer<CChar>?] = env.map { k, v in
            strdup("\(k)=\(v)")
        } + [nil]
        defer { envCStrings.forEach { if let p = $0 { free(p) } } }

        // argv: /bin/zsh -l -c <command>
        // The command appears in argv (visible via ps), which is identical to
        // how Terminal.app and iTerm2 behave — this is expected and harmless.
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/zsh"),
            strdup("-l"),
            strdup("-c"),
            strdup(command),
            nil
        ]
        defer { argv.forEach { if let p = $0 { free(p) } } }

        let cwdPath = workingDirectory.path

        // fork() — child sets up PTY as controlling terminal then exec's.
        let pid = posixFork()
        guard pid >= 0 else {
            close(masterFD); close(slaveFD)
            onOutput?("fork() failed: \(String(cString: strerror(errno)))\n")
            onComplete?()
            return
        }

        if pid == 0 {
            // ── Child process ──────────────────────────────────────────────
            // 1. Become a new session leader (detach from parent's tty).
            _ = setsid()

            // 2. Make the slave PTY the controlling terminal of this session.
            //    TIOCSCTTY is available on macOS (value 0x20007461).
            _ = ioctl(slaveFD, UInt(TIOCSCTTY), 1 as Int32)

            // 3. Wire slave PTY to stdin/stdout/stderr.
            dup2(slaveFD, STDIN_FILENO)
            dup2(slaveFD, STDOUT_FILENO)
            dup2(slaveFD, STDERR_FILENO)

            // 4. Close all other descriptors (master + original slave copy).
            var maxFD = Int32(getdtablesize())
            if maxFD < 0 { maxFD = 1024 }
            var fd: Int32 = 3
            while fd < maxFD { close(fd); fd += 1 }

            // 5. Change working directory.
            _ = chdir(cwdPath)

            // 6. exec the shell.
            envCStrings.withUnsafeBufferPointer { envPtr in
                argv.withUnsafeBufferPointer { argvPtr in
                    _ = execve("/bin/zsh",
                               argvPtr.baseAddress!,
                               envPtr.baseAddress!)
                }
            }
            // exec failed – exit child immediately.
            _exit(127)
        }

        // ── Parent process ────────────────────────────────────────────────
        close(slaveFD)   // Parent doesn't need the slave end.

        childPID = pid
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        masterHandle = master

        // Watch the master PTY for output from the child.
        master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.flushOutput(data)
        }

        // Watch for child exit using a DispatchSource so we don't block.
        let src = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: DispatchQueue.global()
        )
        src.setEventHandler { [weak self] in
            // Reap child to avoid zombie.
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                self?.teardown()
                self?.onComplete?()
            }
        }
        src.resume()
        childWatchSource = src
    }

    /// Sends a line of input to the running program's stdin (via the PTY).
    func sendInput(_ text: String) {
        guard let master = masterHandle else { return }
        var line = text
        if !line.hasSuffix("\n") { line += "\n" }
        if let data = line.data(using: .utf8) { master.write(data) }
    }

    /// Sends raw bytes to the PTY without appending a newline.
    func sendRaw(_ text: String) {
        guard let master = masterHandle else { return }
        if let data = text.data(using: .utf8) { master.write(data) }
    }

    /// Sends a raw control byte (e.g. Ctrl+C = 0x03) directly to the PTY.
    func sendControlCharacter(_ byte: UInt8) {
        guard let master = masterHandle else { return }
        master.write(Data([byte]))
    }

    func stop() {
        sendControlCharacter(0x03)
        if childPID != -1 { kill(childPID, SIGTERM) }
    }

    private func teardown() {
        childWatchSource?.cancel()
        childWatchSource = nil
        masterHandle?.readabilityHandler = nil
        masterHandle = nil
        childPID = -1
        pendingData = Data()
    }

    /// Decodes the accumulated PTY bytes into a String, keeping any trailing
    /// incomplete UTF-8 sequence for the next read. Also normalizes CRLF
    /// (PTY's OPOST turns `\n` into `\r\n`) and lone `\r` into plain `\n`,
    /// since NSTextView isn't a real terminal and would otherwise show `\r`
    /// as garbage / misaligned content.
    private func flushOutput(_ data: Data) {
        pendingData.append(data)

        // Find the longest prefix that decodes cleanly as UTF-8. We do this
        // by trimming trailing continuation bytes (0x80..0xBF) that don't
        // yet form a complete multi-byte sequence, then verifying with
        // String(data:encoding:) which returns nil for invalid UTF-8.
        var decodeEnd = pendingData.count

        // Trim incomplete trailing sequence: walk back over continuation
        // bytes to find the last leading byte, then check if its expected
        // length is fully present.
        let bytes = [UInt8](pendingData)
        if !bytes.isEmpty {
            var idx = bytes.count - 1
            // Skip continuation bytes (10xxxxxx = 0x80..0xBF)
            while idx >= 0 && bytes[idx] >= 0x80 && bytes[idx] < 0xC0 {
                idx -= 1
            }
            if idx >= 0 {
                let lead = bytes[idx]
                let expected: Int
                if lead < 0x80 { expected = 1 }
                else if lead < 0xE0 { expected = 2 }
                else if lead < 0xF0 { expected = 3 }
                else { expected = 4 }
                let have = bytes.count - idx
                if have < expected {
                    // Incomplete multi-byte char at the tail; hold it back.
                    decodeEnd = idx
                }
            }
        }

        // Verify the chosen prefix truly decodes; if not (e.g. an invalid
        // byte sequence that isn't just truncated), fall back to decoding
        // everything with lossy replacement so we don't stall forever.
        var toDecode: Data
        if decodeEnd == pendingData.count {
            toDecode = pendingData
            pendingData = Data()
        } else {
            toDecode = pendingData.prefix(decodeEnd)
            pendingData = pendingData.suffix(pendingData.count - decodeEnd)
        }

        guard !toDecode.isEmpty else { return }

        var chunk: String
        if let s = String(data: toDecode, encoding: .utf8) {
            chunk = s
        } else {
            // Lossy fallback: decode what we can (replaces bad bytes with
            // U+FFFD) and drop the buffer so we don't loop on bad data.
            chunk = String(decoding: toDecode, as: UTF8.self)
            pendingData = Data()
        }

        // Normalize PTY line endings: OPOST converts \n -> \r\n; collapse
        // \r\n back to \n so the ANSI processor sees clean line feeds.
        // Lone \r (not followed by \n) is kept as-is — it means carriage
        // return (overwrite current line) and is handled by the processor.
        chunk = chunk.replacingOccurrences(of: "\r\n", with: "\n")

        let outputCallback = self.onOutput
        DispatchQueue.main.async {
            outputCallback?(chunk)
        }
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
    /// Emulated cursor position in the rendered output (UTF-16 offset).
    private var outputCursorIndex = 0
    /// Incomplete terminal control sequence split across PTY read chunks.
    private var pendingControlSequence = ""
    private var keyEventMonitor: Any?

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

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

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
            self?.handleProcessOutput(chunk)
        }

        installInteractiveKeyMonitor()
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
        let end = (terminalView.string as NSString).length
        terminalView.setSelectedRange(NSRange(location: end, length: 0))
    }

    private func installInteractiveKeyMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard executor.isRunning else { return event }
            guard event.window === self.view.window else { return event }
            guard self.view.window?.firstResponder === self.terminalView else { return event }

            if self.handleInteractiveKeyDown(event) {
                return nil
            }
            return event
        }
    }

    private func handleInteractiveKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Keep Command shortcuts (copy/paste/select all) routed through the
        // normal key equivalent path handled by HoverPanel.
        if modifiers.contains(.command) {
            return false
        }

        if modifiers.contains(.control),
           (event.charactersIgnoringModifiers?.lowercased() ?? "") == "c" {
            executor.sendControlCharacter(0x03)
            return true
        }

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            executor.sendRaw("\r")
            return true
        case 48: // Tab
            executor.sendRaw("\t")
            return true
        case 51: // Backspace
            executor.sendControlCharacter(0x7f)
            return true
        case 117: // Forward delete
            executor.sendRaw("\u{1b}[3~")
            return true
        case 123: // Left
            executor.sendRaw("\u{1b}[D")
            return true
        case 124: // Right
            executor.sendRaw("\u{1b}[C")
            return true
        case 125: // Down
            executor.sendRaw("\u{1b}[B")
            return true
        case 126: // Up
            executor.sendRaw("\u{1b}[A")
            return true
        case 115: // Home
            executor.sendRaw("\u{1b}OH")
            return true
        case 119: // End
            executor.sendRaw("\u{1b}OF")
            return true
        case 53: // Esc
            executor.sendControlCharacter(0x1b)
            return true
        default:
            break
        }

        if let chars = event.characters, !chars.isEmpty {
            executor.sendRaw(chars)
            return true
        }

        return true
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
        outputCursorIndex = (terminalView.string as NSString).length
        terminalView.scrollToEndOfDocument(nil)
    }

    private func appendPrompt() {
        appendText(promptString(), color: promptColor)
        inputStartIndex = (terminalView.string as NSString).length
        let end = (terminalView.string as NSString).length
        terminalView.setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Handles output arriving from the running process (via the PTY).
    /// This keeps a lightweight terminal cursor model so interactive editors
    /// (python readline, vim, etc.) can move within the current line instead
    /// of being treated as append-only text.
    private func handleProcessOutput(_ chunk: String) {
        guard let textStorage = terminalView.textStorage else { return }

        let mergedChunk: String
        if pendingControlSequence.isEmpty {
            mergedChunk = chunk
        } else {
            mergedChunk = pendingControlSequence + chunk
            pendingControlSequence = ""
        }

        func documentLength() -> Int {
            (terminalView.string as NSString).length
        }

        func clampCursor() {
            outputCursorIndex = max(0, min(outputCursorIndex, documentLength()))
        }

        func withProgrammaticEdit(_ body: () -> Void) {
            isAppendingProgrammatically = true
            body()
            isAppendingProgrammatically = false
        }

        func lineStart(for location: Int, in full: NSString) -> Int {
            var idx = max(0, min(location, full.length))
            while idx > 0 {
                if full.character(at: idx - 1) == 0x0A { break }
                idx -= 1
            }
            return idx
        }

        func lineEnd(for location: Int, in full: NSString) -> Int {
            var idx = max(0, min(location, full.length))
            while idx < full.length {
                if full.character(at: idx) == 0x0A { break }
                idx += 1
            }
            return idx
        }

        func moveLeft(_ count: Int) {
            guard count > 0 else { return }
            clampCursor()
            let full = terminalView.string as NSString
            var remaining = count
            while remaining > 0, outputCursorIndex > 0 {
                let range = full.rangeOfComposedCharacterSequence(at: outputCursorIndex - 1)
                outputCursorIndex = range.location
                remaining -= 1
            }
        }

        func moveRight(_ count: Int) {
            guard count > 0 else { return }
            clampCursor()
            let full = terminalView.string as NSString
            var remaining = count
            while remaining > 0, outputCursorIndex < full.length {
                let range = full.rangeOfComposedCharacterSequence(at: outputCursorIndex)
                outputCursorIndex = range.location + range.length
                remaining -= 1
            }
        }

        func moveToLineStart() {
            clampCursor()
            let full = terminalView.string as NSString
            outputCursorIndex = lineStart(for: outputCursorIndex, in: full)
        }

        func insertLineFeed() {
            // A line feed (\n or \r\n) appends a newline at the cursor
            // position if we are at end-of-document, or moves the cursor
            // down one line (preserving column) if there is a next line.
            clampCursor()
            let full = terminalView.string as NSString
            if outputCursorIndex >= full.length {
                withProgrammaticEdit {
                    textStorage.replaceCharacters(
                        in: NSRange(location: outputCursorIndex, length: 0),
                        with: "\n")
                }
                outputCursorIndex += 1
            } else if full.character(at: outputCursorIndex) == 0x0A {
                outputCursorIndex += 1
            } else {
                withProgrammaticEdit {
                    textStorage.replaceCharacters(
                        in: NSRange(location: outputCursorIndex, length: 0),
                        with: "\n")
                }
                outputCursorIndex += 1
            }
        }

        func moveVertical(_ delta: Int) {
            guard delta != 0 else { return }
            clampCursor()
            let full = terminalView.string as NSString
            var cursor = outputCursorIndex
            let currentStart = lineStart(for: cursor, in: full)
            let currentEnd = lineEnd(for: cursor, in: full)
            let column = min(cursor - currentStart, currentEnd - currentStart)

            if delta > 0 {
                var lines = delta
                var scan = currentEnd
                while lines > 0, scan < full.length {
                    if full.character(at: scan) == 0x0A {
                        scan += 1
                        lines -= 1
                    } else {
                        scan += 1
                    }
                }
                let targetStart = min(scan, full.length)
                let targetEnd = lineEnd(for: targetStart, in: full)
                cursor = min(targetStart + column, targetEnd)
            } else {
                var lines = -delta
                var scan = currentStart
                while lines > 0, scan > 0 {
                    scan -= 1
                    if full.character(at: scan) == 0x0A {
                        lines -= 1
                    }
                }
                let targetStart = lineStart(for: scan, in: full)
                let targetEnd = lineEnd(for: targetStart, in: full)
                cursor = min(targetStart + column, targetEnd)
            }

            outputCursorIndex = max(0, min(cursor, full.length))
        }

        func putCharacter(_ char: String) {
            guard !char.isEmpty else { return }
            clampCursor()
            let full = terminalView.string as NSString
            let charLen = (char as NSString).length

            if outputCursorIndex >= full.length {
                withProgrammaticEdit {
                    textStorage.replaceCharacters(in: NSRange(location: outputCursorIndex, length: 0), with: char)
                }
                outputCursorIndex += charLen
                return
            }

            if full.character(at: outputCursorIndex) == 0x0A {
                withProgrammaticEdit {
                    textStorage.replaceCharacters(in: NSRange(location: outputCursorIndex, length: 0), with: char)
                }
                outputCursorIndex += charLen
                return
            }

            let replaceRange = full.rangeOfComposedCharacterSequence(at: outputCursorIndex)
            withProgrammaticEdit {
                textStorage.replaceCharacters(in: replaceRange, with: char)
            }
            outputCursorIndex = replaceRange.location + charLen
        }

        func insertNewline() {
            clampCursor()
            withProgrammaticEdit {
                textStorage.replaceCharacters(
                    in: NSRange(location: outputCursorIndex, length: 0),
                    with: "\n")
            }
            outputCursorIndex += 1
        }

        func eraseInLine(mode: Int) {
            clampCursor()
            let full = terminalView.string as NSString
            let start = lineStart(for: outputCursorIndex, in: full)
            let end = lineEnd(for: outputCursorIndex, in: full)
            guard end >= start else { return }

            let range: NSRange
            switch mode {
            case 1:
                let len = max(0, outputCursorIndex - start)
                range = NSRange(location: start, length: len)
            case 2:
                range = NSRange(location: start, length: end - start)
            default:
                range = NSRange(location: outputCursorIndex, length: end - outputCursorIndex)
            }

            guard range.length > 0 else { return }
            withProgrammaticEdit {
                textStorage.replaceCharacters(in: range, with: "")
            }
            if mode == 1 || mode == 2 {
                outputCursorIndex = max(start, outputCursorIndex - range.length)
            }
        }

        func deleteChars(_ count: Int) {
            guard count > 0 else { return }
            clampCursor()
            let full = terminalView.string as NSString
            let end = lineEnd(for: outputCursorIndex, in: full)
            let len = min(count, max(0, end - outputCursorIndex))
            guard len > 0 else { return }
            withProgrammaticEdit {
                textStorage.replaceCharacters(in: NSRange(location: outputCursorIndex, length: len), with: "")
            }
        }

        func moveToColumn(_ column: Int) {
            clampCursor()
            let full = terminalView.string as NSString
            let start = lineStart(for: outputCursorIndex, in: full)
            let end = lineEnd(for: outputCursorIndex, in: full)
            let zeroBased = max(0, column - 1)
            outputCursorIndex = min(start + zeroBased, end)
        }

        func clearDisplay(mode: Int) {
            let length = documentLength()
            guard length > 0 else { return }
            switch mode {
            case 2:
                withProgrammaticEdit {
                    textStorage.replaceCharacters(in: NSRange(location: 0, length: length), with: "")
                }
                outputCursorIndex = 0
            default:
                break
            }
        }

        func parseCSIParams(_ body: String) -> [Int] {
            let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            if trimmed.isEmpty { return [] }
            return trimmed.split(separator: ";").map { part in
                let digits = part.filter { $0.isNumber }
                return Int(digits) ?? 0
            }
        }

        func applyCSI(body: String, final: UnicodeScalar) {
            let params = parseCSIParams(body)
            let first = params.first ?? 0
            switch final {
            case "A":
                moveVertical(-(first == 0 ? 1 : first))
            case "B":
                moveVertical(first == 0 ? 1 : first)
            case "C":
                moveRight(first == 0 ? 1 : first)
            case "D":
                moveLeft(first == 0 ? 1 : first)
            case "G":
                moveToColumn(first == 0 ? 1 : first)
            case "K":
                eraseInLine(mode: first)
            case "P":
                deleteChars(first == 0 ? 1 : first)
            case "J":
                clearDisplay(mode: first)
            default:
                break
            }
        }

        func scalarSliceToString(_ slice: ArraySlice<UnicodeScalar>) -> String {
            String(String.UnicodeScalarView(slice))
        }

        clampCursor()

        let scalars = Array(mergedChunk.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x08:
                // Typical tty delete echo is "\b \b". Collapse it into an
                // actual delete so model text stays consistent with display.
                if index + 2 < scalars.count,
                   scalars[index + 1].value == 0x20,
                   scalars[index + 2].value == 0x08 {
                    moveLeft(1)
                    deleteChars(1)
                    index += 3
                } else {
                    // Plain backspace is cursor-left (used by readline moves).
                    moveLeft(1)
                    index += 1
                }
            case 0x0D:
                // Carriage return: move cursor to start of current line.
                // After \r\n normalization in flushOutput, lone \r means
                // "overwrite current line from column 0".
                moveToLineStart()
                index += 1
            case 0x0A:
                insertLineFeed()
                index += 1
            case 0x1B:
                guard index + 1 < scalars.count else {
                    pendingControlSequence = scalarSliceToString(scalars[index...])
                    index = scalars.count
                    continue
                }

                let next = scalars[index + 1]
                if next == "[" {
                    var end = index + 2
                    while end < scalars.count {
                        let value = scalars[end].value
                        if value >= 0x40, value <= 0x7E { break }
                        end += 1
                    }
                    if end < scalars.count {
                        let body = String(String.UnicodeScalarView(scalars[(index + 2)..<end]))
                        applyCSI(body: body, final: scalars[end])
                        index = end + 1
                    } else {
                        pendingControlSequence = scalarSliceToString(scalars[index...])
                        index = scalars.count
                    }
                } else if next == "]" {
                    // OSC: consume until BEL or ST (ESC \).
                    var end = index + 2
                    var terminated = false
                    while end < scalars.count {
                        let value = scalars[end].value
                        if value == 0x07 {
                            end += 1
                            terminated = true
                            break
                        }
                        if value == 0x1B, end + 1 < scalars.count, scalars[end + 1].value == 0x5C {
                            end += 2
                            terminated = true
                            break
                        }
                        end += 1
                    }
                    if terminated {
                        index = end
                    } else {
                        pendingControlSequence = scalarSliceToString(scalars[index...])
                        index = scalars.count
                    }
                } else {
                    // Other two-byte ESC sequences are not rendered.
                    index += 2
                }
            default:
                if scalar.value >= 0x20 || scalar.value == 0x09 {
                    putCharacter(String(scalar))
                }
                index += 1
            }
        }

        inputStartIndex = outputCursorIndex
        terminalView.setSelectedRange(NSRange(location: outputCursorIndex, length: 0))
        terminalView.scrollRangeToVisible(NSRange(location: outputCursorIndex, length: 0))
    }

    // MARK: - Command execution

    private func executeCommand(_ raw: String) {
        // If a program is already running (e.g. python3 REPL, ssh, a pager),
        // pressing Enter should feed the typed line to that program's stdin
        // via the PTY instead of being interpreted as a new shell command.
        if executor.isRunning {
            appendText("\n", color: textColor)
            executor.sendInput(raw)
            // The next line of interactive input starts right after what we
            // just "sent" (echoed by the PTY itself in most cases, but we
            // still need a local edit boundary).
            inputStartIndex = (terminalView.string as NSString).length
            return
        }

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
        guard let replacement = replacementString else { return true }

        // PTY interactive mode: a child program (python3, ssh, etc.) owns
        // the terminal. Don't insert anything into the local text view —
        // forward every byte to the PTY and let its ECHO (the kernel line
        // discipline or the program itself) render the characters back to
        // us through handleProcessOutput. This is exactly how a real
        // terminal works and eliminates the double-echo we used to get when
        // both the app and the PTY displayed the same keystroke.
        if executor.isRunning {
            if !replacement.isEmpty {
                let isAllowed = replacement.unicodeScalars.allSatisfy { scalar in
                    let value = scalar.value
                    if value == 0x09 || value == 0x0A || value == 0x0D {
                        return true
                    }
                    if value < 0x20 || value == 0x7F {
                        return false
                    }
                    if (0xF700...0xF8FF).contains(value) {
                        return false
                    }
                    return true
                }
                if isAllowed {
                    executor.sendRaw(replacement)
                }
            }
            return false
        }

        // Idle mode (shell prompt): editing is only allowed from
        // inputStartIndex onward.
        return affectedCharRange.location >= inputStartIndex
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if isUpdatingSelection { return }
        // When a process is running, the ANSI cursor model owns the caret
        // position — don't fight it by snapping back to the end.
        if executor.isRunning { return }
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
        // ---- PTY interactive mode ----
        // Forward special keys to the PTY as escape sequences / control
        // bytes. The PTY's ECHO and the child program (e.g. readline in
        // python3) handle all on-screen feedback, so we never modify the
        // local text view here.
        if executor.isRunning {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                executor.sendRaw("\n")
                return true
            case #selector(NSResponder.insertTab(_:)):
                executor.sendRaw("\t")
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                executor.sendRaw("\u{1b}[Z")  // Shift-Tab
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                executor.sendControlCharacter(0x7f)  // DEL (backspace)
                return true
            case #selector(NSResponder.deleteForward(_:)):
                executor.sendRaw("\u{1b}[3~")  // Delete key
                return true
            case #selector(NSResponder.moveUp(_:)):
                executor.sendRaw("\u{1b}[A")
                return true
            case #selector(NSResponder.moveDown(_:)):
                executor.sendRaw("\u{1b}[B")
                return true
            case #selector(NSResponder.moveLeft(_:)):
                executor.sendRaw("\u{1b}[D")
                return true
            case #selector(NSResponder.moveRight(_:)):
                executor.sendRaw("\u{1b}[C")
                return true
            case #selector(NSResponder.moveToBeginningOfLine(_:)):
                executor.sendRaw("\u{1b}OH")  // Home
                return true
            case #selector(NSResponder.moveToEndOfLine(_:)):
                executor.sendRaw("\u{1b}OF")  // End
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Ctrl+C — let the child handle SIGINT (e.g. python3 shows
                // KeyboardInterrupt). Don't force-terminate; the program
                // decides whether to exit.
                executor.sendControlCharacter(0x03)
                return true
            default:
                break
            }
            // For any other selector, swallow it so the text view doesn't
            // modify its contents locally while in PTY mode.
            return true
        }

        // ---- Idle mode (shell prompt) ----
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
            onHideRequested?()
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

    /// The screen the panel is currently displayed on (tracked so we can
    /// detect when the user moves the cursor to a *different* screen's
    /// trigger zone and needs the panel repositioned there).
    private var panelScreen: NSScreen?

    private func updatePanelVisibility() {
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen = screenContaining(mouseLocation)
        let inTriggerZone = currentScreen.map { triggerRect(on: $0).contains(mouseLocation) } ?? false

        // If the panel is visible but the mouse is in a *different* screen's
        // trigger zone, treat it as a new trigger (reposition to that screen).
        let onDifferentScreen = panel.isVisible && inTriggerZone
            && currentScreen != nil && currentScreen != panelScreen

        let insidePanel = panel.isVisible
            && !onDifferentScreen
            && panel.frame.insetBy(dx: -trackingPadding, dy: -trackingPadding).contains(mouseLocation)
        let withinHandoff = panel.isVisible
            && !onDifferentScreen
            && Date().timeIntervalSince(lastTriggerTime) < handoffDuration

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
        let screenChanged = panelScreen != screen

        if panel.frame != desiredFrame || screenChanged {
            // Moving to a different screen: hide first so the window doesn't
            // appear to slide across screens, then reposition and fade in.
            if screenChanged && panel.isVisible {
                panel.orderOut(nil)
            }
            panel.setFrame(desiredFrame, display: true)
        }

        panelScreen = screen

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
        panelScreen = nil
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
    // Keep a strong reference so the item isn't deallocated.
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the menu-bar status item before anything else so it appears
        // as early as possible. We must NOT call setActivationPolicy(.accessory)
        // before creating the status item, because on some macOS versions that
        // suppresses the status bar slot allocation.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Floating Terminal") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.title = "FT"
            }
            button.toolTip = "Floating Terminal"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Terminal", action: #selector(showPanelNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Floating Terminal", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item

        // Switch to accessory (no Dock icon) AFTER the status item is live.
        NSApp.setActivationPolicy(.accessory)

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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
