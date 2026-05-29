import Cocoa
import WebKit
import UniformTypeIdentifiers

// PDF text extractor is a self-contained binary in Resources, bundled per-arch.
func resource(_ name: String) -> String {
    return Bundle.main.resourcePath! + "/" + name
}
// Each slice of the universal app calls the extractor built for its own architecture.
#if arch(arm64)
let extractorBinary = "muni-extract-arm64"
#else
let extractorBinary = "muni-extract-x86_64"
#endif

// Turn arbitrary JSON text into a safe JS expression that evaluates to that string.
func jsStringLiteral(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
    let arr = String(data: data, encoding: .utf8)!   // -> ["....escaped...."]
    return arr + "[0]"
}

// Persists the reader's library/state JSON in Application Support (survives relaunch).
enum Store {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muni", isDirectory: true)
    }
    static var file: URL { dir.appendingPathComponent("library.json") }
    static func load() -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? "null"
    }
    static func save(_ s: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.write(to: file, atomically: true, encoding: .utf8)
    }
}

final class DragWebView: WKWebView {
    var onDropPDF: ((URL) -> Void)?
    var onDragState: ((Bool) -> Void)?

    override func awakeFromNib() {}
    func setup() { registerForDraggedTypes([.fileURL]) }

    private func pdfURL(_ s: NSDraggingInfo) -> URL? {
        guard let urls = s.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true,
                          .urlReadingContentsConformToTypes: [UTType.pdf.identifier]]) as? [URL]
        else { return nil }
        return urls.first
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        if pdfURL(s) != nil { onDragState?(true); return .copy }
        return []
    }
    override func draggingExited(_ s: NSDraggingInfo?) { onDragState?(false) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { pdfURL(s) != nil }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        onDragState?(false)
        if let u = pdfURL(s) { onDropPDF?(u); return true }
        return false
    }
    override func concludeDragOperation(_ s: NSDraggingInfo?) { onDragState?(false) }
}

final class AppController: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, URLSessionDownloadDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: DragWebView!
    var ready = false
    lazy var dlSession: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    var dlInfo = [Int: (dlId: Int, title: String, ext: String)]()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "bridge")
        cfg.userContentController = ucc

        let frame = NSRect(x: 0, y: 0, width: 1120, height: 840)
        web = DragWebView(frame: frame, configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")  // avoid white flash
        web.setup()
        web.onDropPDF = { [weak self] url in self?.openPDF(url) }
        web.onDragState = { [weak self] on in
            self?.web.evaluateJavaScript("showDrop(\(on))", completionHandler: nil)
        }

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Muni"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = AppController.color("#f3ead4")   // sepia default; theme-synced from JS
        window.minSize = NSSize(width: 720, height: 520)
        window.delegate = self
        if #available(macOS 11.0, *) { window.titlebarSeparatorStyle = .line }   // divider under the traffic-light strip
        window.center()
        window.setFrameAutosaveName("CleanReaderMain")
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let html = URL(fileURLWithPath: resource("reader.html"))
        web.loadFileURL(html, allowingReadAccessTo: URL(fileURLWithPath: Bundle.main.resourcePath!))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // Freeze the reading layout during a live window resize; reflow only once the user lets go.
    func windowWillStartLiveResize(_ n: Notification) {
        web?.evaluateJavaScript("if(window.resizeStart)resizeStart()", completionHandler: nil)
    }
    func windowDidEndLiveResize(_ n: Notification) {
        web?.evaluateJavaScript("if(window.resizeEnd)resizeEnd()", completionHandler: nil)
    }
    // If the user leaves fullscreen by gesture/menu, tell the page to drop immersive mode too.
    func windowDidExitFullScreen(_ n: Notification) {
        web?.evaluateJavaScript("if(window.exitImmersiveFromNative)exitImmersiveFromNative()", completionHandler: nil)
    }

    // Hand the saved library/state to the page; JS decides whether to resume.
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        ready = true
        wv.evaluateJavaScript("boot(\(jsStringLiteral(Store.load())))", completionHandler: nil)
    }

    // JS -> native
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "open":        presentOpenPanel()
        case "openDefault": loadDefault()
        case "openPath":    if let p = body["path"] as? String { openPDF(URL(fileURLWithPath: p)) }
        case "save":        if let st = body["state"] as? String { Store.save(st) }
        case "theme":       if let hex = body["bg"] as? String { window.backgroundColor = AppController.color(hex) }
        case "discover":    if let q = body["q"] as? String { discover(q) }
        case "fullscreen":
            let on = body["on"] as? Bool ?? true
            if on != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case "fetchDownload":
            if let dlId = body["dlId"] as? Int, let src = body["source"] as? String,
               let url = body["url"] as? String, let title = body["title"] as? String {
                fetchDownload(dlId: dlId, source: src, urlOrRef: url, title: title, ext: body["ext"] as? String ?? "")
            }
        default: break
        }
    }

    // ---- Discover: search the free catalogs ---------------------------------
    func httpGet(_ urlStr: String, _ done: @escaping (Data?) -> Void) {
        guard let url = URL(string: urlStr) else { done(nil); return }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { d, _, _ in done(d) }.resume()
    }

    func discover(_ q: String) {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var results = [[String: Any]](); let lock = NSLock(); let group = DispatchGroup()
        func add(_ a: [[String: Any]]) { lock.lock(); results += a; lock.unlock() }

        group.enter()
        httpGet("https://gutendex.com/books/?search=\(enc)") { d in
            defer { group.leave() }
            guard let d = d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rs = o["results"] as? [[String: Any]] else { return }
            var out = [[String: Any]]()
            for r in rs.prefix(7) {
                let title = r["title"] as? String ?? "Untitled"
                let auth = (r["authors"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
                guard let fmts = r["formats"] as? [String: String] else { continue }
                let epub = fmts.first { $0.key.contains("epub") }?.value
                let pdf = fmts.first { $0.key.contains("pdf") }?.value
                if let u = epub ?? pdf {
                    out.append(["source": "Gutenberg", "title": title, "author": auth,
                                "ext": epub != nil ? "epub" : "pdf", "url": u])
                }
            }
            add(out)
        }

        group.enter()
        httpGet("https://standardebooks.org/ebooks?query=\(enc)") { d in
            defer { group.leave() }
            guard let d = d, let html = String(data: d, encoding: .utf8) else { return }
            guard let rx = try? NSRegularExpression(pattern: "/ebooks/([a-z0-9-]+)/([a-z0-9-]+)\"") else { return }
            var seen = Set<String>(); var out = [[String: Any]]()
            for m in rx.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let ar = Range(m.range(at: 1), in: html), let tr = Range(m.range(at: 2), in: html) else { continue }
                let a = String(html[ar]), t = String(html[tr]); let key = a + "/" + t
                if seen.contains(key) { continue }; seen.insert(key)
                func nice(_ s: String) -> String { s.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
                out.append(["source": "Standard Ebooks", "title": nice(t), "author": nice(a), "ext": "epub",
                            "url": "https://standardebooks.org/ebooks/\(a)/\(t)/downloads/\(a)_\(t).epub?source=download"])
                if seen.count >= 6 { break }
            }
            add(out)
        }

        group.enter()
        httpGet("https://archive.org/advancedsearch.php?q=\(enc)+AND+mediatype%3Atexts+AND+NOT+collection%3A%28inlibrary+OR+printdisabled%29&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=creator&rows=8&output=json") { d in
            defer { group.leave() }
            guard let d = d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let resp = o["response"] as? [String: Any], let docs = resp["docs"] as? [[String: Any]] else { return }
            var out = [[String: Any]]()
            for doc in docs.prefix(8) {
                guard let id = doc["identifier"] as? String else { continue }
                let title = doc["title"] as? String ?? id
                let creator = (doc["creator"] as? String) ?? (doc["creator"] as? [String])?.first ?? ""
                out.append(["source": "Internet Archive", "title": title, "author": creator, "ext": "", "url": id])
            }
            add(out)
        }

        group.notify(queue: .main) {
            for i in results.indices { results[i]["rid"] = i }
            let data = (try? JSONSerialization.data(withJSONObject: results)) ?? Data("[]".utf8)
            let s = String(data: data, encoding: .utf8) ?? "[]"
            self.web.evaluateJavaScript("discoverResults(\(jsStringLiteral(s)))", completionHandler: nil)
        }
    }

    // ---- Discover: download chosen book with progress -----------------------
    func fetchDownload(dlId: Int, source: String, urlOrRef: String, title: String, ext: String) {
        if source == "Internet Archive" {
            httpGet("https://archive.org/metadata/\(urlOrRef)") { d in
                var file: String?; var fext = "pdf"
                if let d = d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let files = o["files"] as? [[String: Any]] {
                    let names = files.compactMap { $0["name"] as? String }
                    if let p = names.first(where: { $0.lowercased().hasSuffix(".pdf") }) { file = p; fext = "pdf" }
                    else if let e = names.first(where: { $0.lowercased().hasSuffix(".epub") }) { file = e; fext = "epub" }
                    else if let t = names.first(where: { $0.lowercased().hasSuffix(".txt") }) { file = t; fext = "txt" }
                }
                guard let f = file else { self.dlFail(dlId, "No downloadable PDF or EPUB in this item."); return }
                let fenc = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
                self.startDownload(dlId: dlId, url: "https://archive.org/download/\(urlOrRef)/\(fenc)", title: title, ext: fext)
            }
        } else {
            startDownload(dlId: dlId, url: urlOrRef, title: title, ext: ext.isEmpty ? "epub" : ext)
        }
    }

    func startDownload(dlId: Int, url: String, title: String, ext: String) {
        guard let u = URL(string: url) else { dlFail(dlId, "Bad download URL."); return }
        var req = URLRequest(url: u); req.timeoutInterval = 180
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let task = dlSession.downloadTask(with: req)
        dlInfo[task.taskIdentifier] = (dlId, title, ext)
        task.resume()
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite tot: Int64) {
        guard tot > 0, let info = dlInfo[t.taskIdentifier] else { return }
        let frac = Double(w) / Double(tot)
        DispatchQueue.main.async { self.web.evaluateJavaScript("dlProgress(\(info.dlId),\(frac))", completionHandler: nil) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        guard let info = dlInfo[t.taskIdentifier] else { return }
        dlInfo[t.taskIdentifier] = nil
        // Validate: server status + that it's actually a PDF/EPUB, not an HTML error page.
        if let http = t.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: loc)
            dlFail(info.dlId, "This title isn’t available as a free download (HTTP \(http.statusCode))."); return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: loc.path))?[.size] as? Int) ?? 0
        var head = Data()
        if let fh = try? FileHandle(forReadingFrom: loc) { head = fh.readData(ofLength: 4); try? fh.close() }
        let isPDF = head.starts(with: Array("%PDF".utf8))
        let isZip = head.starts(with: [0x50, 0x4B])            // EPUB is a ZIP ("PK")
        if size < 1024 || !(isPDF || isZip || info.ext == "txt") {
            try? FileManager.default.removeItem(at: loc)
            dlFail(info.dlId, "This title isn’t available as a free download."); return
        }
        let booksDir = Store.dir.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        let safe = info.title.replacingOccurrences(of: "/", with: "-").prefix(60)
        let dest = booksDir.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(6)).\(info.ext)")
        do { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: loc, to: dest) }
        catch { dlFail(info.dlId, "Could not save the downloaded file."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = NSTemporaryDirectory() + "cr_\(UUID().uuidString).json"
            let p = Process(); p.executableURL = URL(fileURLWithPath: resource(extractorBinary))
            p.arguments = [dest.path, out]
            let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
            do { try p.run(); p.waitUntilExit() } catch { self.dlFail(info.dlId, "Reader engine failed to start."); return }
            guard let txt = try? String(contentsOfFile: out, encoding: .utf8) else { self.dlFail(info.dlId, "Could not read the downloaded book."); return }
            try? FileManager.default.removeItem(atPath: out)
            DispatchQueue.main.async {
                self.web.evaluateJavaScript("dlDone(\(info.dlId),true)", completionHandler: nil)
                self.web.evaluateJavaScript("loadBook(\(jsStringLiteral(txt)), \(jsStringLiteral(dest.path)))", completionHandler: nil)
            }
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError err: Error?) {
        if let info = dlInfo[t.taskIdentifier], err != nil { dlInfo[t.taskIdentifier] = nil; dlFail(info.dlId, err!.localizedDescription) }
    }

    func dlFail(_ dlId: Int, _ msg: String) {
        DispatchQueue.main.async { self.web.evaluateJavaScript("dlDone(\(dlId),false,\(jsStringLiteral(msg)))", completionHandler: nil) }
    }

    func loadDefault() {
        let def = resource("default.json")
        if let txt = try? String(contentsOfFile: def, encoding: .utf8) {
            web.evaluateJavaScript("loadBook(\(jsStringLiteral(txt)), \(jsStringLiteral("__default__")))", completionHandler: nil)
        }
    }

    static func color(_ hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        return NSColor(red: CGFloat((v>>16)&0xff)/255, green: CGFloat((v>>8)&0xff)/255,
                       blue: CGFloat(v&0xff)/255, alpha: 1)
    }

    func presentOpenPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.message = "Choose a PDF to read"
        p.begin { [weak self] resp in
            if resp == .OK, let url = p.url { self?.openPDF(url) }
        }
    }

    func openPDF(_ url: URL) {
        web.evaluateJavaScript("showBusy()", completionHandler: nil)
        let out = NSTemporaryDirectory() + "clean_reader_\(UUID().uuidString).json"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: resource(extractorBinary))
            task.arguments = [url.path, out]
            let pipe = Pipe(); task.standardError = pipe; task.standardOutput = pipe
            do { try task.run(); task.waitUntilExit() }
            catch { self?.fail("Could not start the PDF reader engine."); return }

            guard let txt = try? String(contentsOfFile: out, encoding: .utf8) else {
                let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                self?.fail("Extraction failed.\n\(err)"); return
            }
            try? FileManager.default.removeItem(atPath: out)
            DispatchQueue.main.async {
                self?.web.evaluateJavaScript("loadBook(\(jsStringLiteral(txt)), \(jsStringLiteral(url.path)))", completionHandler: nil)
            }
        }
    }

    func fail(_ msg: String) {
        let j = "{\"error\":\"\(msg.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " "))\"}"
        DispatchQueue.main.async { [weak self] in
            self?.web.evaluateJavaScript("loadBook(\(jsStringLiteral(j)), \(jsStringLiteral("")))", completionHandler: nil)
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Muni", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Muni", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Muni", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open PDF…", action: #selector(menuOpen), keyEquivalent: "o")
        open.target = self; fileMenu.addItem(open)
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let libItem = NSMenuItem(); main.addItem(libItem)
        let lib = NSMenu(title: "Library")
        let showLib = NSMenuItem(title: "Show Library", action: #selector(menuLibrary), keyEquivalent: "l")
        showLib.target = self; lib.addItem(showLib)
        let openLib = NSMenuItem(title: "Open PDF…", action: #selector(menuOpen), keyEquivalent: "")
        openLib.target = self; lib.addItem(openLib)
        let disc = NSMenuItem(title: "Find Books Online…", action: #selector(menuDiscover), keyEquivalent: "d")
        disc.target = self; lib.addItem(disc)
        libItem.submenu = lib

        let hiItem = NSMenuItem(); main.addItem(hiItem)
        let hi = NSMenu(title: "Highlights")
        let showHi = NSMenuItem(title: "Show Highlights", action: #selector(menuHighlights), keyEquivalent: "")
        showHi.target = self; hi.addItem(showHi)
        hiItem.submenu = hi

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = NSMenuItem(title: "Find…", action: #selector(menuFind), keyEquivalent: "f")
        find.target = self; edit.addItem(find)
        editItem.submenu = edit

        NSApp.mainMenu = main
    }
    @objc func menuOpen() { presentOpenPanel() }
    @objc func menuFind() { web.evaluateJavaScript("toggleSearch(true)", completionHandler: nil) }
    @objc func menuLibrary() { web.evaluateJavaScript("openLibrary()", completionHandler: nil) }
    @objc func menuHighlights() { web.evaluateJavaScript("openHighlights()", completionHandler: nil) }
    @objc func menuDiscover() { web.evaluateJavaScript("openDiscover()", completionHandler: nil) }
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.run()
