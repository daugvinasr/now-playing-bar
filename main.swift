import AppKit

let maxTextLength = 500

func formatTitle(name: String?, artistName: String?) -> String {
    guard let name, let artistName, !name.isEmpty, !artistName.isEmpty else { return "" }
    let title = "\(name) · \(artistName)"
    if title.count <= maxTextLength { return title }
    return title.prefix(maxTextLength).trimmingCharacters(in: .whitespaces) + "…"
}

final class NowPlaying {
    var title: String?
    var artist: String?
    var artworkData: Data?

    func clear() {
        title = nil
        artist = nil
        artworkData = nil
    }

    /// Applies a full payload, or a diff in which nulls clear a field.
    func apply(_ payload: [String: Any], diff: Bool) {
        if !diff { clear() }

        func string(_ key: String) -> String?? {
            guard let raw = payload[key] else { return nil }
            return raw is NSNull ? .some(nil) : .some(raw as? String)
        }

        if let v = string("title") { title = v }
        if let v = string("artist") { artist = v }
        if let v = string("artworkData") { artworkData = v.flatMap { Data(base64Encoded: $0) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state = NowPlaying()

    private var task: Process?
    private var buffer = Data()

    private let perl = "/usr/bin/perl"
    private let script: String
    private let framework: String

    private static let iconSide: CGFloat = 16
    private static let iconRadius: CGFloat = iconSide * 0.3

    private static let holdWindow: TimeInterval = 10

    private var heldTitle: String?
    private var heldArtwork: Data?
    private var titleHoldExpiry: Date?
    private var artworkHoldExpiry: Date?
    private var holdTimer: Timer?

    override init() {
        (script, framework) = Self.locateAdapter()
    }

    /// Finds mediaremote-adapter.pl and MediaRemoteAdapter.framework, in order:
    /// 1. $NOW_PLAYING_BAR_ADAPTER_DIR containing both files
    /// 2. <prefix>/libexec next to <prefix>/bin/now-playing-bar (Homebrew layout)
    /// 3. a mediaremote-adapter checkout beside the app or in the working directory
    private static func locateAdapter() -> (script: String, framework: String) {
        var candidates: [(String, String)] = []

        if let dir = ProcessInfo.processInfo.environment["NOW_PLAYING_BAR_ADAPTER_DIR"], !dir.isEmpty {
            candidates.append((dir + "/mediaremote-adapter.pl", dir + "/MediaRemoteAdapter.framework"))
        }

        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let libexec = exe.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("libexec").path
            candidates.append((libexec + "/mediaremote-adapter.pl", libexec + "/MediaRemoteAdapter.framework"))
        }

        let root = Bundle.main.bundlePath.hasSuffix(".app")
            ? URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
            : FileManager.default.currentDirectoryPath
        candidates.append((root + "/mediaremote-adapter/bin/mediaremote-adapter.pl",
                           root + "/mediaremote-adapter/build/MediaRemoteAdapter.framework"))

        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0.0) && fm.fileExists(atPath: $0.1) } ?? candidates.last!
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        render()
        startStream()
        trapTerminationSignals()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStream()
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// Quit cleanly (and take the adapter child down) on SIGTERM/SIGINT, e.g. from launchd or Ctrl-C.
    private func trapTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func stopStream() {
        guard let task else { return }
        task.terminationHandler = nil
        if task.isRunning { task.terminate() }
        self.task = nil
    }


    private func startStream() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: perl)
        task.arguments = [script, framework, "stream", "--debounce=250"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.startStream() }
        }
        do { try task.run() } catch { return }
        self.task = task
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "data" else { continue }
            let payload = object["payload"] as? [String: Any] ?? [:]
            if payload.isEmpty {
                state.clear()
                clearHolds()
            } else {
                state.apply(payload, diff: object["diff"] as? Bool ?? false)
            }
            render()
        }
    }


    private func render() {
        guard let button = statusItem.button else { return }
        let now = Date()

        let fresh = formatTitle(name: state.title, artistName: state.artist)
        let title = hold(fresh.isEmpty ? nil : fresh, held: &heldTitle, expiry: &titleHoldExpiry, now: now) ?? ""

        let cover = hold(state.artworkData, held: &heldArtwork, expiry: &artworkHoldExpiry, now: now).flatMap(coverImage)

        button.image = cover ?? placeholderIcon()
        button.title = title.isEmpty ? "" : " " + title
        button.toolTip = title.isEmpty ? "Nothing is playing right now" : title

        scheduleHoldExpiry(now: now)
    }

    private func hold<T>(_ fresh: T?, held: inout T?, expiry: inout Date?, now: Date) -> T? {
        if let fresh {
            held = fresh
            expiry = nil
            return fresh
        }
        guard let previous = held else { return nil }
        let deadline = expiry ?? now.addingTimeInterval(Self.holdWindow)
        guard now < deadline else {
            held = nil
            expiry = nil
            return nil
        }
        expiry = deadline
        return previous
    }

    private func scheduleHoldExpiry(now: Date) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let next = [titleHoldExpiry, artworkHoldExpiry].compactMap({ $0 }).min() else { return }
        let delay = max(next.timeIntervalSince(now), 0.05)
        holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.render()
        }
    }

    private func clearHolds() {
        heldTitle = nil
        heldArtwork = nil
        titleHoldExpiry = nil
        artworkHoldExpiry = nil
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func coverImage(from data: Data) -> NSImage? {
        guard let source = NSImage(data: data) else { return nil }
        let side = Self.iconSide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: Self.iconRadius, yRadius: Self.iconRadius).addClip()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private func placeholderIcon() -> NSImage {
        let side = Self.iconSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true }
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
