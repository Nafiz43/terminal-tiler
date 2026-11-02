// tt-coach: Pac-Man productivity coach for terminal-tiler.
// Build: swiftc -O Coach.swift -o tt-coach     Run: ./tt-coach <repo-dir>    Self-check: ./tt-coach --test
//
// Watches input with CGEventSource idle counters (no event tap), Chrome's active tab via AppleScript,
// and pops a click-through Pac-Man overlay for: doom-scroll warnings (then closes the tab),
// 20-20-20 eye breaks, low-activity nudges (quotes / personal advice / starters / deadlines), and greetings.
import Cocoa

let home = FileManager.default.homeDirectoryForCurrentUser
let cfg = home.appendingPathComponent(".config/terminal-tiler")
var repo = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

// MARK: data

struct Quote: Decodable { let q: String; let a: String }
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

// MARK: Pac-Man overlay

final class PacView: NSView {
    var open: CGFloat = 0.3
    var facingLeft = false
    override func draw(_ r: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY), rad = bounds.width / 2 - 2
        let mouth = 45 * open, base: CGFloat = facingLeft ? 180 : 0
        let p = NSBezierPath()
        p.move(to: c)
        p.appendArc(withCenter: c, radius: rad, startAngle: base + mouth, endAngle: base - mouth + 360)
        p.close()
        NSColor(calibratedRed: 1, green: 0.85, blue: 0, alpha: 1).setFill(); p.fill()
        NSColor.black.setStroke(); p.lineWidth = 2; p.stroke()
        let eye = NSBezierPath(ovalIn: NSRect(x: c.x + (facingLeft ? -rad * 0.15 : rad * 0.05), y: c.y + rad * 0.45, width: rad * 0.18, height: rad * 0.18))
        NSColor.black.setFill(); eye.fill()
    }
}

final class Overlay {
    let win: NSWindow, pac = PacView(frame: NSRect(x: -120, y: 0, width: 96, height: 96))
    let bubble = NSTextField(wrappingLabelWithString: "")
    var queue: [(String, Double, Int?)] = [], busy = false, chomp: Timer?

    init() {
        let f = NSScreen.main!.frame
        win = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.level = .screenSaver; win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView(frame: f); v.wantsLayer = true; win.contentView = v
        pac.wantsLayer = true; v.addSubview(pac)
        bubble.font = .systemFont(ofSize: 17, weight: .medium)
        bubble.textColor = .white; bubble.drawsBackground = true
        bubble.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92)
        bubble.wantsLayer = true; bubble.layer?.cornerRadius = 12; bubble.isHidden = true
        bubble.preferredMaxLayoutWidth = 470
        v.addSubview(bubble)
    }

    /// urgent messages jump the queue (scroll guard).
    func say(_ text: String, seconds: Double = 12, countdown: Int? = nil, urgent: Bool = false) {
        if urgent { queue.insert((text, seconds, countdown), at: 0) } else { queue.append((text, seconds, countdown)) }
        if !busy { next() }
    }

    private func move(to x: CGFloat, _ dur: Double, then: @escaping () -> Void) {
        pac.facingLeft = x < pac.frame.minX
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = dur; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pac.animator().setFrameOrigin(NSPoint(x: x, y: pac.frame.minY))
        }, completionHandler: then)
    }

    private func next() {
        guard !queue.isEmpty else { busy = false; win.orderOut(nil); chomp?.invalidate(); return }
        busy = true
        let (text, secs, countdown) = queue.removeFirst()
        let f = NSScreen.main!.visibleFrame
        pac.setFrameOrigin(NSPoint(x: f.minX - 120, y: f.maxY - 220))
        win.orderFrontRegardless()
        var t: CGFloat = 0
        chomp?.invalidate()
        chomp = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            t += 0.35; self?.pac.open = 0.15 + 0.85 * abs(sin(t)); self?.pac.needsDisplay = true
        }
        move(to: f.midX - 260, 1.4) { [self] in
            func show(_ s: String) {
                bubble.stringValue = "  " + s + "  "
                let w: CGFloat = 470, h = bubble.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 2000)).height + 16
                bubble.frame = NSRect(x: pac.frame.maxX + 14, y: pac.frame.maxY - h, width: w, height: h)
            }
            show(countdown.map { "\(text)  \($0)s" } ?? text)
            bubble.isHidden = false
            var left = countdown ?? 0
            let total = countdown.map(Double.init) ?? secs
            if countdown != nil {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { tm in
                    left -= 1; show(left > 0 ? "\(text)  \(left)s" : "Done. Back to work.")
                    if left <= 0 { tm.invalidate() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + total + (countdown == nil ? 0 : 2)) { [self] in
                bubble.isHidden = true
                move(to: f.maxX + 120, 1.6) { self.next() }
            }
        }
    }
}

// MARK: coach brain

final class Coach {
    let ui = Overlay()
    var profile: Profile, quotes: [Quote], deadlines: [Deadline]
    var activeSecs = 0, wasAway = true, lastNudge = Date.distantPast, nudgeTurn = 0, tick = 0
    // scroll guard
    var feedTab: String?, feedStart = Date(), feedLastSeen = Date.distantPast, scrollTicks = 0, warnedAt: Date?, graceScroll = 0

    let quietApps = ["us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "com.apple.iWork.Keynote"]

    init() {
        profile = load("profile.json", Profile.self) ?? Profile(name: "there", advice: [], starters: [:], blocklist: ["youtube.com", "facebook.com", "instagram.com", "x.com", "twitter.com", "reddit.com"], priorityConfs: [])
        quotes = load("quotes.json", [Quote].self) ?? []
        deadlines = load("deadlines.json", [Deadline].self) ?? []
        refreshIfStale()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)  // window titles for starters; falls back to app name
    }

    func refreshIfStale() {
        let f = cfg.appendingPathComponent("deadlines.json")
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 86400 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", repo.appendingPathComponent("coach/refresh.py").path]
        p.terminationHandler = { _ in DispatchQueue.main.async {
            self.quotes = load("quotes.json", [Quote].self) ?? self.quotes
            self.deadlines = load("deadlines.json", [Deadline].self) ?? self.deadlines
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
            ui.say("\(hi), \(profile.name). " + (deadlineLine(deadlines, profile.priorityConfs).map { $0 + " " } ?? "") + "First move: " + starter(for: ctx, profile), seconds: 14)
            log("greet")
        }
        if activeSecs >= 1200 && !quiet {
            activeSecs = 0
            ui.say("Eye break: look 20 feet away.", countdown: 20); log("eyebreak")
        }

        // low activity: present (mouse/scroll in last minute) but no typing for 5 min
        if idle(.keyDown) > 300 && any < 60 && now.timeIntervalSince(lastNudge) > 600 && !quiet {
            lastNudge = now; nudgeTurn += 1
            ui.say(nudge(ctx), seconds: 13); log("nudge")
        }

        // doom-scroll guard (Chrome only), polled every 2 s
        if tick % 2 == 0 { scrollGuard(bundle == "com.google.Chrome", scrolling: idle(.scrollWheel) < 2.1, now: now) }
        if tick % 3600 == 0 { refreshIfStale() }
    }

    func nudge(_ ctx: String) -> String {
        switch nudgeTurn % 4 {
        case 0: if let q = quotes.randomElement() { return "\u{201C}\(q.q)\u{201D} - \(q.a)" }
        case 1: if let a = profile.advice.randomElement() { return a }
        case 2: if let d = deadlineLine(deadlines, profile.priorityConfs) { return d + " Make today count." }
        default: break
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
            ui.say("Stop scrolling, \(profile.name). 3 minutes on this feed. Keep going and I eat this tab in 60s.", seconds: 10, urgent: true)
            log("scroll-warn\t\(t.url)")
        } else if let w = warnedAt, now.timeIntervalSince(w) >= 60 {
            if graceScroll >= 3 {
                osa("tell application \"Google Chrome\"\nrepeat with w in windows\nclose (every tab of w whose id is \(t.id))\nend repeat\nend tell")
                ui.say("Chomp. Tab gone. " + starter(for: "", profile), seconds: 10, urgent: true)
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
if CommandLine.arguments.contains("--demo") { coach.ui.say("Hi \(coach.profile.name), Pac-Man coach is on duty.", seconds: 6) }
app.run()
