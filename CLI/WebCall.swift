//
//  WebCall.swift
//  fernsprecher-ki-modus-an
//
//  Hosts the FaceTime web client in an off-screen WKWebView. No FaceTime.app, no virtual audio device.
//

import AppKit
import WebKit

final class WebCall: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    // The web client only lets non-Apple browsers in; WebKit itself has every API it needs.
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    var onAudio: (([Int16]) -> Void)?
    var onEvent: (([String: Any]) -> Void)?

    private let url: URL
    private var window: NSWindow!
    private var webView: WKWebView!
    private var activity: NSObjectProtocol?

    init(url: URL, name: String, language: String, avatar: String, brand: String, monitor: Bool, video: Bool, verbose: Bool) {
        // `grep` is the web client's own flag (read from query or fragment) that turns its log on in the console.
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if verbose { c.query = "grep=." }
        self.url = c.url ?? url
        super.init()
        // WebKit derives Accept-Language from this; English labels keep the autopilot independent of the Mac's language.
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["en-US", "en"]], forName: UserDefaults.argumentDomain)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.inactiveSchedulingPolicy = .none
        cfg.userContentController.add(self, name: "ftk")
        cfg.userContentController.addUserScript(WKUserScript(
            source: BridgeJS.source(name: name, language: language, avatar: avatar, brand: brand, monitor: monitor, video: video, verbose: verbose),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // Ordered in but placed far off-screen so WebKit keeps the page fully active.
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1280, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        webView.customUserAgent = WebCall.userAgent
        webView.isInspectable = verbose
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView!.addSubview(webView)
        window.orderBack(nil)

        // An off-screen window counts as occluded, and WebKit then throttles the page (timers, audio callbacks)
        // until the incoming audio stutters. Keep the page treated as visible and keep App Nap away.
        WebCall.keepActive(webView)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "FaceTime call")
    }

    /// Treat the web view as visible even though its window is off-screen (otherwise WebKit throttles it).
    static func keepActive(_ webView: WKWebView) {
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion), let imp = webView.method(for: occlusion) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(imp, to: SetBool.self)(webView, occlusion, false)
        }
    }

    func start() {
        webView.load(URLRequest(url: url))
    }

    func play(pcm: Data, sampleRate: Double, id: Int, completion: @escaping (Double?) -> Void) {
        let js = "return window.__ftk ? window.__ftk.play(data, id, rate) : null"
        webView.callAsyncJavaScript(js, arguments: ["data": pcm.base64EncodedString(), "id": id, "rate": sampleRate],
                                    in: nil, in: .page) { result in
            completion((try? result.get()) as? Double)
        }
    }

    func evaluate(_ body: String, arguments: [String: Any] = [:], completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            switch result {
            case .success(let v): completion(v)
            case .failure(let e): completion("error: \(e.localizedDescription)")
            }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "audio" {
            guard let b64 = body["pcm"] as? String, let data = Data(base64Encoded: b64) else { return }
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            onAudio?(samples)
        } else {
            onEvent?(body)
        }
    }

    // MARK: WebCrypto master key
    // FaceTime's end-to-end encryption needs WebCrypto, and WebKit by default keeps its master key in the login
    // keychain, which pops a password prompt for this tool (and denying it drops the call). The website data
    // store is non-persistent anyway, so a fresh in-memory key per run is enough (WKNavigationDelegatePrivate SPI).

    private static let cryptoKey: Data = {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }()

    @objc(_webCryptoMasterKeyForWebView:completionHandler:)
    func webCryptoMasterKey(for webView: WKWebView, completionHandler: @escaping (Data?) -> Void) {
        onEvent?(["type": "log", "text": "WebCrypto master key supplied (async)"])
        completionHandler(WebCall.cryptoKey)
    }

    @objc(_webCryptoMasterKeyForWebView:)
    func webCryptoMasterKey(for webView: WKWebView) -> Data? {
        onEvent?(["type": "log", "text": "WebCrypto master key supplied"])
        return WebCall.cryptoKey
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onEvent?(["type": "log", "text": "loaded \(webView.url?.host ?? "")"])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onEvent?(["type": "error", "text": "cannot load FaceTime: \(error.localizedDescription)"])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEvent?(["type": "error", "text": "web content process terminated"])
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)   // our getUserMedia replacement never touches the real microphone or camera
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
