import AppKit

/// Best-effort, read-only reuse of the installed Rex catalog. Rex's bundle/key names
/// are not a public asset contract; every unavailable image uses a terminal symbol.
@MainActor
final class RexIconProvider {
    static let shared = RexIconProvider()
    static let didUpdate = Notification.Name("RexIconProviderDidUpdate")

    private let fallback = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
    private let queue = DispatchQueue(label: "PaneSwitch.RexArtwork", qos: .utility)
    private let loader = RexArtworkLoader()
    private var images: [String: NSImage] = [:]
    private var commands: Set<String> = ["bash", "zsh", "omp", "pi", "docker", "nvim", "neovim"]
    private var refreshInFlight = false
    private var refreshAgain = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.superlogical.rex" else { return }
                Task { @MainActor in self?.refresh() }
            })
        }
        // Also bounds refresh for same-path updates and LSUIElement apps, which may
        // not generate workspace launch notifications. Never checked by a row lookup.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Called when cached inventory changes, not while configuring or switching rows.
    func preload(commands newCommands: [String]) {
        let previousCount = commands.count
        commands.formUnion(newCommands.filter { !$0.isEmpty })
        if commands.count != previousCount { refresh() }
    }

    /// Cache-only: no discovery, catalog lookup, decoding, or file access.
    func image(forCommand command: String) -> NSImage {
        images[command] ?? fallback
    }

    private func refresh() {
        guard !refreshInFlight else {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        let requested = commands
        let runningURLs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex")
            .compactMap(\.bundleURL)
        let loader = loader
        queue.async { [weak self] in
            let snapshot = loader.load(commands: requested, runningURLs: runningURLs)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let changed = self.images.count != snapshot.count || snapshot.contains { self.images[$0.key] !== $0.value }
                self.images = snapshot
                self.refreshInFlight = false
                if changed { NotificationCenter.default.post(name: Self.didUpdate, object: self) }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }
}

/// Confined to the provider's utility queue. Images are fully prepared before being
/// published to AppKit; both successful and missing catalog keys are retained here.
private final class RexArtworkLoader: @unchecked Sendable {
    private struct Generation: Equatable {
        let version: String
        let build: String
        let modified: Date
        let size: UInt64
        let fileNumber: UInt64
    }

    private struct Source {
        let url: URL
        let generation: Generation
        let bundle: Bundle
    }

    private var source: Source?
    private var observed: [URL: Generation] = [:]
    private var restartRequired = Set<URL>()
    private var images: [String: NSImage] = [:]
    private var attempted = Set<String>()

    func load(commands: Set<String>, runningURLs: [URL]) -> [String: NSImage] {
        // Prefer a running instance deterministically; Launch Services is only the
        // fallback when Rex is not running. No hardcoded app installation pathname.
        let appURL = runningURLs.sorted { $0.path < $1.path }.first
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex")
        let next = appURL.flatMap(findSource)
        if source?.url != next?.url || source?.generation != next?.generation {
            images.removeAll()
            attempted.removeAll()
            source = next
        }
        guard let source else { return [:] }
        if let previous = observed[source.url], previous != source.generation {
            // Bundle/AppKit do not promise same-path catalog hot reload. Discard
            // our cache and use generic icons until this process is restarted.
            restartRequired.insert(source.url)
        }
        observed[source.url] = source.generation
        guard !restartRequired.contains(source.url) else { return [:] }

        var result: [String: NSImage] = [:]
        for command in commands {
            guard let key = Self.assetKey(for: command) else { continue }
            if attempted.insert(key).inserted,
               let loaded = source.bundle.image(forResource: NSImage.Name("block-glyph-\(key)")),
               let image = Self.preparedGlyph(loaded) {
                images[key] = image
            }
            if let image = images[key] { result[command] = image }
        }
        return result
    }

    private static func assetKey(for command: String) -> String? {
        let name = command.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        guard !name.isEmpty, name.utf8.count <= 128,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 43].contains($0) }) else { return nil }
        if ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"].contains(name) { return "terminal" }
        if name == "nvim" { return "neovim" }
        if name == "view" || name == "rvim" || name.hasPrefix("vim.") { return "vim" }
        return name
    }

    private static func preparedGlyph(_ source: NSImage) -> NSImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        let scale = min(size.width / source.size.width, size.height / source.size.height)
        let fitted = NSRect(x: (size.width - source.size.width * scale) / 2,
                            y: (size.height - source.size.height * scale) / 2,
                            width: source.size.width * scale, height: source.size.height * scale)
        // Rasterize here so drawing a row never lazily opens or decodes the
        // external catalog. Retain native and Retina representations.
        for pixels in [24, 48] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                               bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(pixels) / size.width, y: CGFloat(pixels) / size.height)
            context.cgContext.clear(CGRect(origin: .zero, size: size))
            context.imageInterpolation = .high
            source.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        // OMP's actual π and the other glyphs are monochrome, but the external
        // catalog does not consistently mark them as templates.
        image.isTemplate = true
        return image
    }

    private func findSource(at appURL: URL) -> Source? {
        let url = appURL.standardizedFileURL.resolvingSymlinksInPath()
        // Read metadata afresh instead of trusting a retained Bundle.infoDictionary.
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.superlogical.rex",
              let app = Bundle(url: url), let resources = app.resourceURL,
              let bundle = Bundle(url: resources.appendingPathComponent("SuperBlockIcons_SuperBlockIcons.bundle")),
              let catalog = bundle.resourceURL?.appendingPathComponent("Assets.car"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: catalog.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let generation = Generation(version: info["CFBundleShortVersionString"] as? String ?? "",
                                    build: info["CFBundleVersion"] as? String ?? "",
                                    modified: modified, size: size.uint64Value, fileNumber: fileNumber.uint64Value)
        return Source(url: url, generation: generation, bundle: bundle)
    }
}
