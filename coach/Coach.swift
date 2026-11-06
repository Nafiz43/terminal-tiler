// tt-coach: AI-orb productivity coach for terminal-tiler.
// Build: swiftc -O Coach.swift -o tt-coach     Run: ./tt-coach <repo-dir>    Self-check: ./tt-coach --test
//
// Watches input with CGEventSource idle counters (no event tap), Chrome's active tab via AppleScript,
// and pops a click-through glass card with a breathing AI sparkle for: doom-scroll warnings (then closes the tab),
// 20-20-20 eye breaks, 10-minute nudges (AI news TLDRs / tech hard-work quotes / advice / starters), and greetings (deadline once a day).
import Cocoa

let home = FileManager.default.homeDirectoryForCurrentUser
let cfg = home.appendingPathComponent(".config/terminal-tiler")
var repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

// MARK: data

struct Quote: Decodable { let q: String; let a: String }
struct News: Decodable { let src: String; let title: String; let summary: String; let tldr: String? }
struct Deadline: Decodable { let name: String; let subs: [String]; let deadline: String }
struct Profile: Decodable {
    let name: String
    let advice: [String]
    let starters: [String: [String]]   // lowercase keyword in "app + window title" -> starter lines
    let blocklist: [String]            // host or host/path prefixes, e.g. "youtube.com", "linkedin.com/feed"
    let priorityConfs: [String]        // conference name prefixes you care about most
}

func load<T: Decodable>(_ name: String, _: T.Type) -> T? {
    let paths = [cfg.appendingPathComponent(name), repo.appendingPathComponent("coach/" + name.replacingOccurrences(of: ".json", with: ".example.json"))]
    for p in paths { if let d = try? Data(contentsOf: p), let v = try? JSONDecoder().decode(T.self, from: d) { return v } }
    return nil
}

func log(_ event: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + "\t" + event + "\n"
    let url = cfg.appendingPathComponent("coach.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

@discardableResult
func osa(_ src: String) -> String? {
    var err: NSDictionary?
    let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
    return err == nil ? r?.stringValue : nil
}

func isBlocked(_ url: String, _ list: [String]) -> Bool {
    var s = url.lowercased()
    for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
    if s.hasPrefix("www.") { s.removeFirst(4) }
    if s.hasPrefix("m.") { s.removeFirst(2) }
    return list.contains { s.hasPrefix($0) || s.contains("." + $0) }
}

func daysLeft(_ iso: String, from now: Date = Date()) -> Int? {
    guard let d = ISO8601DateFormatter().date(from: iso) else { return nil }
    return Int(ceil(d.timeIntervalSince(now) / 86400))
}

func deadlineLine(_ dls: [Deadline], _ priority: [String], now: Date = Date()) -> String? {
    let up = dls.filter { (daysLeft($0.deadline, from: now) ?? -1) >= 0 }
    guard let next = up.first else { return nil }
    let pri = up.first { d in priority.contains { d.name.hasPrefix($0) } }
    var s = "\(next.name) deadline in \(daysLeft(next.deadline, from: now)!) days."
    if let p = pri, p.name != next.name { s += " \(p.name): \(daysLeft(p.deadline, from: now)!) days." }
    return s
}

func starter(for context: String, _ p: Profile) -> String {
    // context is "window title | app name": a title match (sugaree, main.tex) beats an app match (terminal)
    for part in context.lowercased().components(separatedBy: " | ") {
        if let key = p.starters.keys.filter({ $0 != "default" && part.contains($0) }).max(by: { $0.count < $1.count }) {
            return p.starters[key]!.randomElement()!
        }
    }
    return p.starters["default"]?.randomElement() ?? "Pick one task. Do the smallest first step now."
}

// MARK: AI orb overlay

/// Split an icon sheet (dark glyphs on a light background, laid out in a grid) into template images.
/// Rows/columns are found from gaps in the dark-pixel projection, so any grid size works.
func sliceIconSheet(_ url: URL) -> [NSImage] {
    guard let src = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
    let w = src.width, h = src.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
    var ink = [UInt8](repeating: 0, count: w * h)  // 0 = background, 255 = glyph
    for i in 0..<(w * h) {
        let lum = (Int(px[i * 4]) * 3 + Int(px[i * 4 + 1]) * 6 + Int(px[i * 4 + 2])) / 10
        ink[i] = UInt8(min(255, max(0, (200 - lum) * 255 / 150)))
    }
    func runs(_ n: Int, _ hasInk: (Int) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = [], start: Int?, lastInk = -100
        for i in 0..<n where hasInk(i) {
            if let s = start, i - lastInk > 12 { out.append(s..<(lastInk + 1)); start = i } else if start == nil { start = i }
            lastInk = i
        }
        if let s = start { out.append(s..<(lastInk + 1)) }
        return out.filter { $0.count > 20 }
    }
    let cols = runs(w) { x in (0..<h).contains { ink[$0 * w + x] > 128 } }
    let rows = runs(h) { y in (0..<w).contains { ink[y * w + $0] > 128 } }
    var icons: [NSImage] = []
    for r in rows { for c in cols {
        var out = [UInt8](repeating: 0, count: c.count * r.count * 4)
        for y in 0..<r.count { for x in 0..<c.count {
            let a = ink[(r.lowerBound + y) * w + c.lowerBound + x], o = (y * c.count + x) * 4
            out[o] = a; out[o + 1] = a; out[o + 2] = a; out[o + 3] = a   // white, premultiplied
        } }
        guard out.contains(where: { $0 > 128 }) else { continue }
        let cg = CGContext(data: &out, width: c.count, height: r.count, bitsPerComponent: 8, bytesPerRow: c.count * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let img = NSImage(cgImage: cg, size: NSSize(width: 40, height: 40 * CGFloat(r.count) / CGFloat(c.count)))
        img.isTemplate = true
        icons.append(img)
    } }
    return icons
}

/// Icon that breathes (lights up, then dims, ~4 s) via Core Animation: no redraw timer.
final class OrbView: NSImageView {
    static let tint = NSColor(srgbRed: 0.80, green: 0.78, blue: 1.0, alpha: 1)   // light lavender
    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Rafin")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.tint])))
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = Self.tint
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOffset = .zero
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Pool from ~/.config/terminal-tiler/icons.png (any grid of glyphs); the star is the fallback.
    lazy var pool: [NSImage] = sliceIconSheet(cfg.appendingPathComponent("icons.png"))
    func shuffleIcon() {
        if let i = pool.randomElement() { image = i; frame.size = NSSize(width: 64, height: 64) }
    }

    func breathe() {
        guard let l = layer else { return }
        l.removeAllAnimations()
        for (key, from, to) in [("opacity", 0.12, 1.0), ("shadowOpacity", 0.0, 1.0), ("shadowRadius", 0.0, 18.0)] as [(String, Double, Double)] {
            let an = CABasicAnimation(keyPath: key)
            an.fromValue = from; an.toValue = to
            an.duration = 2.1; an.autoreverses = true; an.repeatCount = .infinity
            an.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(an, forKey: key)
        }
    }
}

final class Overlay: NSObject {
    let win: NSPanel
    let card = NSVisualEffectView()
    let orb = OrbView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    let title = NSTextField(labelWithString: "RAFIN")
    let body = NSTextField(wrappingLabelWithString: "")
    var queue: [(String, Double, Int?)] = [], busy = false
    // gen invalidates the timers of a card once it is dismissed; hover or pin keeps it on screen.
    private var gen = 0, until = Date(), pinned = false, leaving = false
    private lazy var closeBtn = button("xmark", #selector(dismiss), "Dismiss")
    private lazy var pinBtn = button("pin", #selector(togglePin), "Keep on screen")
    let cardW: CGFloat = 440, pad: CGFloat = 16, textX: CGFloat = 84

    override init() {
        let f = NSScreen.main!.frame
        // non-activating: clicking the card never steals focus from the app you are in
        win = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.level = .screenSaver; win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView(frame: f); v.wantsLayer = true; win.contentView = v
        card.material = .hudWindow; card.blendingMode = .behindWindow; card.state = .active
        card.appearance = NSAppearance(named: .vibrantDark)
        card.wantsLayer = true; card.layer?.cornerRadius = 18; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1; card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.alphaValue = 0
        title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = NSColor(srgbRed: 0.65, green: 0.7, blue: 1, alpha: 1)
        body.font = .systemFont(ofSize: 15, weight: .regular); body.textColor = NSColor.white.withAlphaComponent(0.92)
        body.preferredMaxLayoutWidth = cardW - textX - pad
        super.init()
        [orb, title, body, pinBtn, closeBtn].forEach(card.addSubview)
        v.addSubview(card)
    }

    private func button(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.isBordered = false; b.toolTip = tip; b.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        return b
    }

    @objc func dismiss() {
        guard busy, !leaving else { return }
        leaving = true; gen += 1; win.ignoresMouseEvents = true
        slide(in: false) { self.next() }
    }

    @objc func togglePin() {
        pinned.toggle()
        pinBtn.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Keep on screen")
        pinBtn.contentTintColor = pinned ? title.textColor : NSColor.white.withAlphaComponent(0.55)
    }

    /// urgent messages jump the queue (scroll guard).
    func say(_ text: String, seconds: Double = 12, countdown: Int? = nil, urgent: Bool = false) {
        if urgent { queue.insert((text, seconds, countdown), at: 0) } else { queue.append((text, seconds, countdown)) }
        if !busy { next() }
    }

    private func layout(_ text: String) {
        body.stringValue = text
        let tw = cardW - textX - pad
        let bh = body.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: 2000)).height
        let h = max(96, bh + 52)
        let f = NSScreen.main!.visibleFrame
        card.setFrameSize(NSSize(width: cardW, height: h))
        card.setFrameOrigin(NSPoint(x: card.frame.minX == 0 ? f.maxX - cardW - 20 : card.frame.minX, y: f.maxY - h - 16))
        orb.setFrameOrigin(NSPoint(x: 12, y: h - 64 - 14))
        title.frame = NSRect(x: textX, y: h - 30, width: tw - 52, height: 16)
        pinBtn.frame = NSRect(x: cardW - 54, y: h - 32, width: 20, height: 20)
        closeBtn.frame = NSRect(x: cardW - 30, y: h - 32, width: 20, height: 20)
        body.frame = NSRect(x: textX, y: 14, width: tw, height: bh)
    }

    private func slide(in show: Bool, then: @escaping () -> Void) {
        let f = NSScreen.main!.visibleFrame, restX = f.maxX - cardW - 20
        if show { card.setFrameOrigin(NSPoint(x: restX + 40, y: card.frame.minY)) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? 0.45 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            card.animator().alphaValue = show ? 1 : 0
            card.animator().setFrameOrigin(NSPoint(x: show ? restX : restX + 40, y: card.frame.minY))
        }, completionHandler: then)
    }

    private func next() {
        guard !queue.isEmpty else { busy = false; win.orderOut(nil); orb.layer?.removeAllAnimations(); return }
        busy = true; leaving = false
        if pinned { togglePin() }
        gen += 1; let g = gen
        let (text, secs, countdown) = queue.removeFirst()
        layout(countdown.map { "\(text)  \($0)s" } ?? text)
        win.orderFrontRegardless()
        orb.shuffleIcon(); orb.breathe()
        slide(in: true) { [self] in
            var left = countdown ?? 0
            if countdown != nil {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] tm in
                    guard g == gen else { tm.invalidate(); return }
                    left -= 1; layout(left > 0 ? "\(text)  \(left)s" : "Done. Back to work.")
                    if left <= 0 { tm.invalidate() }
                }
            }
            until = Date() + (countdown.map(Double.init) ?? secs) + (countdown == nil ? 0 : 2)
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [self] tm in
                guard g == gen else { tm.invalidate(); return }
                // ponytail: polls the mouse 5x/s instead of a tracking area; the overlay only takes clicks while hovered
                let over = win.convertToScreen(card.frame).contains(NSEvent.mouseLocation)
                win.ignoresMouseEvents = !over
                if over || pinned { until = max(until, Date() + 3) }  // stays 3s after the mouse leaves
                if Date() >= until { dismiss() }
            }
        }
    }
}

// MARK: coach brain

final class Coach {
    let ui = Overlay()
    var profile: Profile, quotes: [Quote], deadlines: [Deadline], news: [News], seenNews = Set<String>()
    var activeSecs = 0, wasAway = true, lastNudge = Date(), nudgeTurn = 0, tick = 0
    // scroll guard
    var feedTab: String?, feedStart = Date(), feedLastSeen = Date.distantPast, scrollTicks = 0, warnedAt: Date?, graceScroll = 0

    let quietApps = ["us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.apple.iWork.Keynote"]

    init() {
        profile = load("profile.json", Profile.self) ?? Profile(name: "there", advice: [], starters: [:], blocklist: ["youtube.com", "facebook.com", "instagram.com", "x.com", "twitter.com", "reddit.com"], priorityConfs: [])
        quotes = load("quotes.json", [Quote].self) ?? []
        deadlines = load("deadlines.json", [Deadline].self) ?? []
        news = load("news.json", [News].self) ?? []
        refreshIfStale()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)  // window titles for starters; falls back to app name
    }

    func refreshIfStale() {
        let f = cfg.appendingPathComponent("deadlines.json")
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 6 * 3600 else { return }  // news moves faster than deadlines
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", repo.appendingPathComponent("coach/refresh.py").path]
        p.terminationHandler = { _ in DispatchQueue.main.async {
            self.quotes = load("quotes.json", [Quote].self) ?? self.quotes
            self.deadlines = load("deadlines.json", [Deadline].self) ?? self.deadlines
            self.news = load("news.json", [News].self) ?? self.news
        } }
        try? p.run()
    }

    func idle(_ t: CGEventType) -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t) }

    func context() -> (bundle: String, text: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("", "") }
        var title = ""
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?, t: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
           AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success { title = t as? String ?? "" }
        return (app.bundleIdentifier ?? "", title + " | " + (app.localizedName ?? ""))
    }

    func step() {
        tick += 1
        let any = idle(CGEventType(rawValue: ~0)!), now = Date()
        let (bundle, ctx) = context()
        let quiet = quietApps.contains(bundle)

        // presence + 20-20-20
        if any > 300 { activeSecs = 0; if any > 1800 { wasAway = true } }
        else if any < 30 { activeSecs += 1 }
        if wasAway && any < 5 {
            wasAway = false
            let h = Calendar.current.component(.hour, from: now)
            let hi = h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
            ui.say("\(hi), \(profile.name). " + (deadlineOncePerDay().map { $0 + " " } ?? "") + "First move: " + starter(for: ctx, profile), seconds: 14)
            log("greet")
        }
        if activeSecs >= 1200 && !quiet {
            activeSecs = 0
            ui.say("Eye break: look 20 feet away.", countdown: 20); log("eyebreak")
            lastNudge = now  // an eye break counts as this slot's popup
        }

        // something every 10 min while you're at the Mac (any input in the last 2 min)
        if any < 120 && now.timeIntervalSince(lastNudge) >= 600 && !quiet {
            lastNudge = now; nudgeTurn += 1
            ui.say(nudge(ctx), seconds: 13); log("nudge")
        }

        // doom-scroll guard (Chrome only), polled every 2 s
        if tick % 2 == 0 { scrollGuard(bundle == "com.google.Chrome", scrolling: idle(.scrollWheel) < 2.1, now: now) }
        if tick % 3600 == 0 { refreshIfStale() }
    }

    /// Deadline countdown at most once per calendar day (survives restarts via a stamp file).
    func deadlineOncePerDay() -> String? {
        let stamp = cfg.appendingPathComponent("deadline_shown"), today = String(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]))
        guard (try? String(contentsOf: stamp, encoding: .utf8)) != today, let d = deadlineLine(deadlines, profile.priorityConfs) else { return nil }
        try? today.write(to: stamp, atomically: true, encoding: .utf8)
        return d
    }

    // Rotation: news, advice, news, advice (quotes fill in when news runs out).
    func nudge(_ ctx: String) -> String {
        switch nudgeTurn % 4 {
        case 0, 2:
            if let n = news.first(where: { !seenNews.contains($0.title) }) {
                seenNews.insert(n.title)
                if let t = n.tldr, !t.isEmpty { return "\(n.src) TLDR\n" + t.replacingOccurrences(of: "  \n", with: "\n") }
                return n.summary.isEmpty ? "\(n.src): \(n.title)" : "\(n.src): \(n.title). \(n.summary)"
            }
            if let q = quotes.randomElement() { return "\u{201C}\(q.q)\u{201D} - \(q.a)" }
        case 1: if let a = profile.advice.randomElement() { return a }
        default: if let a = profile.advice.randomElement() { return a }
        }
        return "Quick start: " + starter(for: ctx, profile)
    }

    func scrollGuard(_ chromeFront: Bool, scrolling: Bool, now: Date) {
        var tab: (url: String, id: String)?
        if chromeFront, let r = osa("tell application \"Google Chrome\" to return (URL of active tab of front window) & linefeed & (id of active tab of front window)") {
            let parts = r.components(separatedBy: "\n")
            if parts.count == 2 { tab = (parts[0], parts[1]) }
        }
        guard let t = tab, isBlocked(t.url, profile.blocklist) else {
            if now.timeIntervalSince(feedLastSeen) > 30 { feedTab = nil; warnedAt = nil }  // short app-switches don't reset
            return
        }
        if t.id != feedTab { feedTab = t.id; feedStart = now; scrollTicks = 0; warnedAt = nil; graceScroll = 0 }
        feedLastSeen = now
        if scrolling { scrollTicks += 1; if warnedAt != nil { graceScroll += 1 } }  // ticks are 2 s apart
        if warnedAt == nil && now.timeIntervalSince(feedStart) >= 180 && scrollTicks >= 30 {
            warnedAt = now; graceScroll = 0
            ui.say("Stop scrolling, \(profile.name). 3 minutes on this feed. Keep going and I close this tab in 60s.", seconds: 10, urgent: true)
            log("scroll-warn\t\(t.url)")
        } else if let w = warnedAt, now.timeIntervalSince(w) >= 60 {
            if graceScroll >= 3 {
                osa("tell application \"Google Chrome\"\nrepeat with w in windows\nclose (every tab of w whose id is \(t.id))\nend repeat\nend tell")
                ui.say("Tab closed. " + starter(for: "", profile), seconds: 10, urgent: true)
                log("tab-closed\t\(t.url)")
            }
            feedTab = nil; warnedAt = nil
        }
    }
}

// MARK: entry

if CommandLine.arguments.dropFirst().first == "--test" {
    let bl = ["youtube.com", "linkedin.com/feed", "x.com"]
    precondition(isBlocked("https://www.youtube.com/watch?v=1", bl))
    precondition(isBlocked("https://m.youtube.com/", bl))
    precondition(isBlocked("https://linkedin.com/feed/", bl) && !isBlocked("https://www.linkedin.com/in/me", bl))
    precondition(!isBlocked("https://arxiv.org/abs/x.com", bl) && !isBlocked("https://box.com", bl))
    let now = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!
    let dls = [Deadline(name: "FAccT 2027", subs: [], deadline: "2026-11-04T11:59:59Z"), Deadline(name: "CVPR 2027", subs: [], deadline: "2026-11-17T11:59:59Z")]
    precondition(deadlineLine(dls, ["CVPR"], now: now) == "FAccT 2027 deadline in 3 days. CVPR 2027: 16 days.", deadlineLine(dls, ["CVPR"], now: now)!)
    let p = Profile(name: "N", advice: [], starters: ["veraclip": ["V"], "sugaree": ["S"], "terminal": ["T"], "default": ["D"]], blocklist: [], priorityConfs: [])
    precondition(starter(for: "train.py - VeraCLIP | Code", p) == "V" && starter(for: " | Finder", p) == "D")
    precondition(starter(for: "nafiz@sugaree: ~ | Terminal", p) == "S" && starter(for: "zsh | Terminal", p) == "T")
    print("ok"); exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
let coach = Coach()
if CommandLine.arguments.contains("--icons") { print("icons:", sliceIconSheet(cfg.appendingPathComponent("icons.png")).count); exit(0) }
if CommandLine.arguments.contains("--demo") {
    coach.ui.say("Hi \(coach.profile.name), Rafin here. One focused block now beats three later.", seconds: 5)
    coach.ui.say(coach.nudge(""), seconds: 7)   // first nudge = latest news TLDR
}
app.run()
