import AppKit

let maxTextLength = 500
let iconSide: CGFloat = 16
let iconRadius: CGFloat = iconSide * 0.3

func formatTitle(name: String?, artistName: String?) -> String {
    guard let name, let artistName, !name.isEmpty, !artistName.isEmpty else { return "" }
    let title = "\(name) · \(artistName)"
    if title.count <= maxTextLength { return title }
    return title.prefix(maxTextLength).trimmingCharacters(in: .whitespaces) + "…"
}

func menuBarIcon(from data: Data) -> NSImage? {
    guard let source = NSImage(data: data) else { return nil }
    return NSImage(size: NSSize(width: iconSide, height: iconSide), flipped: false) { rect in
        NSBezierPath(roundedRect: rect, xRadius: iconRadius, yRadius: iconRadius).addClip()
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
}

struct AdapterLocation {
    let script: URL
    let framework: URL

    static func locate() -> AdapterLocation? {
        var candidates: [AdapterLocation] = []

        if let dir = ProcessInfo.processInfo.environment["NOW_PLAYING_BAR_ADAPTER_DIR"], !dir.isEmpty {
            candidates.append(AdapterLocation(directory: URL(fileURLWithPath: dir)))
        }

        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() { // Homebrew: bin/ beside libexec/
            let libexec = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec")
            candidates.append(AdapterLocation(directory: libexec))
        }

        let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("mediaremote-adapter")
        candidates.append(AdapterLocation(script: checkout.appendingPathComponent("bin/mediaremote-adapter.pl"),
                                          framework: checkout.appendingPathComponent("build/MediaRemoteAdapter.framework")))

        return candidates.first(where: \.exists)
    }

    private init(directory: URL) {
        self.init(script: directory.appendingPathComponent("mediaremote-adapter.pl"),
                  framework: directory.appendingPathComponent("MediaRemoteAdapter.framework"))
    }

    private init(script: URL, framework: URL) {
        self.script = script
        self.framework = framework
    }

    private var exists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: script.path) && fm.fileExists(atPath: framework.path)
    }
}

/// Empty payload: nothing is playing.
struct AdapterMessage {
    let payload: [String: Any]
    let diff: Bool
}

/// Messages are delivered on the main queue.
final class AdapterStream {
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private static let restartDelay: TimeInterval = 3

    private let location: AdapterLocation
    private let onMessage: (AdapterMessage) -> Void
    private var process: Process?
    private var buffer = Data()

    init(location: AdapterLocation, onMessage: @escaping (AdapterMessage) -> Void) {
        self.location = location
        self.onMessage = onMessage
    }

    func start() {
        buffer.removeAll()

        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [location.script.path, location.framework.path, "stream", "--debounce=250"]
        // stderr is inherited deliberately.
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil // EOF: handler would otherwise spin
                return
            }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in self?.scheduleRestart() }

        do {
            try process.run()
        } catch {
            warn("failed to launch \(Self.perl.path): \(error.localizedDescription)")
            scheduleRestart()
            return
        }
        self.process = process
    }

    func stop() {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    private func scheduleRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartDelay) { [weak self] in self?.start() }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "data" else { continue }
            onMessage(AdapterMessage(payload: object["payload"] as? [String: Any] ?? [:],
                                     diff: object["diff"] as? Bool ?? false))
        }
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("now-playing-bar: \(message)\n".utf8))
}

final class NowPlaying {
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var artwork: NSImage?

    func clear() {
        title = nil
        artist = nil
        artwork = nil
    }

    /// In a diff, null clears a field.
    func apply(_ payload: [String: Any], diff: Bool) {
        if !diff { clear() }

        // nil: absent. .some(nil): null.
        func string(_ key: String) -> String?? {
            guard let raw = payload[key] else { return nil }
            return raw is NSNull ? .some(nil) : .some(raw as? String)
        }

        if let v = string("title") { title = v }
        if let v = string("artist") { artist = v }
        if let v = string("artworkData") { artwork = v.flatMap { Data(base64Encoded: $0) }.flatMap(menuBarIcon) }
    }
}

/// Smooths transient gaps between tracks.
struct Hold<Value> {
    private(set) var value: Value?
    private(set) var expiry: Date?

    mutating func resolve(_ fresh: Value?, now: Date, window: TimeInterval) -> Value? {
        if let fresh {
            value = fresh
            expiry = nil
            return fresh
        }
        guard let value else { return nil }
        let deadline = expiry ?? now.addingTimeInterval(window)
        guard now < deadline else {
            clear()
            return nil
        }
        expiry = deadline
        return value
    }

    mutating func clear() {
        value = nil
        expiry = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let holdWindow: TimeInterval = 10
    private static let minTimerDelay: TimeInterval = 0.05

    /// Reserves the image slot so width doesn't jump.
    private static let placeholderIcon: NSImage = {
        let image = NSImage(size: NSSize(width: iconSide, height: iconSide), flipped: false) { _ in true }
        image.isTemplate = true
        return image
    }()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state = NowPlaying()
    private var stream: AdapterStream?
    private var titleHold = Hold<String>()
    private var artworkHold = Hold<NSImage>()
    private var holdTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        trapTerminationSignals()
        render()

        guard let location = AdapterLocation.locate() else {
            warn("mediaremote-adapter not found; set NOW_PLAYING_BAR_ADAPTER_DIR")
            statusItem.button?.toolTip = "mediaremote-adapter not found"
            return
        }
        stream = AdapterStream(location: location) { [weak self] in self?.receive($0) }
        stream?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stream?.stop()
    }

    private func trapTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func receive(_ message: AdapterMessage) {
        if message.payload.isEmpty {
            // Explicit "nothing playing" skips the holds.
            state.clear()
            titleHold.clear()
            artworkHold.clear()
        } else {
            state.apply(message.payload, diff: message.diff)
        }
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let now = Date()

        let fresh = formatTitle(name: state.title, artistName: state.artist)
        let title = titleHold.resolve(fresh.isEmpty ? nil : fresh, now: now, window: Self.holdWindow) ?? ""
        let cover = artworkHold.resolve(state.artwork, now: now, window: Self.holdWindow)

        button.image = cover ?? Self.placeholderIcon
        button.title = title.isEmpty ? "" : " " + title // pads gap after icon
        button.toolTip = title.isEmpty ? "Nothing is playing right now" : title

        scheduleHoldExpiry(now: now)
    }

    private func scheduleHoldExpiry(now: Date) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let next = [titleHold.expiry, artworkHold.expiry].compactMap({ $0 }).min() else { return }
        let delay = max(next.timeIntervalSince(now), Self.minTimerDelay)
        holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.render()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
