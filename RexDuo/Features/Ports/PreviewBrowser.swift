import UIKit
import WebKit

/// What the preview browser opens: the address it loads, and the address it shows.
struct PreviewPage: Equatable {
    /// What loads: the page on the phone's own listener, or the address the computer shares.
    var load: URL
    /// The address as the user knows it from the computer (`localhost:3000`, or a tapped link's
    /// own host and port). The chrome shows this and never `load`.
    var shown: String
    /// The scheme of the address as the user knows it.
    var scheme = "http"
    /// Which computer's port this is (`PortActions.source`), for an address typed later.
    var source: String?
}

/// What the preview browser shows and copies for a page. Pure, so it is tested
/// (docs/terminal.md, Ports).
enum PreviewAddress {
    /// The page on screen is the opened server's own: the same scheme, host and port as what
    /// was loaded. A link that led to another site is not.
    static func isOwn(_ current: URL?, _ page: PreviewPage) -> Bool {
        guard let current else { return true }
        return origin(current) == origin(page.load)
    }

    /// The host line: the computer's address for the server's own pages, whatever loads
    /// underneath; another site's own host for a link that left the server.
    static func display(_ current: URL?, _ page: PreviewPage) -> String {
        guard let current, !isOwn(current, page), let host = current.host else { return page.shown }
        return current.port.map { "\(host):\($0)" } ?? host
    }

    /// Copy Link and Share: the address as shown, with the path of the page on screen. It is
    /// the address that works on the computer.
    static func link(_ current: URL?, _ page: PreviewPage) -> String {
        guard isOwn(current, page) else { return current?.absoluteString ?? "" }
        return "\(page.scheme)://\(page.shown)\(current.map(rest) ?? "/")"
    }

    /// The address line's text while it is edited: the address as shown and the path on screen.
    static func editing(_ current: URL?, _ page: PreviewPage) -> String {
        guard isOwn(current, page) else { return current?.absoluteString ?? "" }
        let r = current.map(rest) ?? "/"
        return page.shown + (r == "/" ? "" : r)
    }

    /// Where the same server's page at another path loads: the listener that is open, never
    /// the address typed.
    static func load(_ rest: String, _ page: PreviewPage) -> URL? {
        guard var c = URLComponents(url: page.load, resolvingAgainstBaseURL: false) else { return nil }
        c.percentEncodedPath = ""
        c.percentEncodedQuery = nil
        c.fragment = nil
        return c.url.flatMap { URL(string: $0.absoluteString + (rest.hasPrefix("/") ? rest : "/" + rest)) }
    }

    static func errorTitle(_ current: URL?, _ page: PreviewPage) -> String {
        "Couldn't load \(display(current, page))"
    }

    /// A failed load shows the error page, except one the user or a download ended.
    static func showsError(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return false }
        // "Frame load interrupted": the response became a download.
        if e.domain == "WebKitErrorDomain", e.code == 102 { return false }
        return true
    }

    /// A response is handed to the share sheet when the page can't show it or the server says
    /// it is an attachment.
    static func isDownload(canShow: Bool, disposition: String?) -> Bool {
        if !canShow { return true }
        return disposition?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") ?? false
    }

    /// Schemes a page may navigate to inside the view.
    static func loads(_ url: URL?) -> Bool {
        ["http", "https", "about", "blob", "data"].contains(url?.scheme?.lowercased() ?? "")
    }

    private static func origin(_ u: URL) -> String {
        let scheme = u.scheme?.lowercased() ?? ""
        return "\(scheme)://\(u.host?.lowercased() ?? ""):\(u.port ?? (scheme == "https" ? 443 : 80))"
    }

    private static func rest(_ u: URL) -> String {
        guard let c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return "/" }
        var r = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { r += "?" + q }
        if let f = c.percentEncodedFragment { r += "#" + f }
        return r
    }
}

/// The app's own browser for a computer's dev server: one `WKWebView`, made when the page opens
/// and let go when it closes, under a small bar: Done, the page's title over the computer's
/// address, a menu (Copy Link, Share), and back, forward and reload. A tap on the address edits
/// it, as in Safari: Go opens the dev server typed, on whichever computer runs it.
///
/// It has no button that leaves for an address only this app can reach. Downloads go to the
/// share sheet, a link for a new window opens here, a sign-in a server asks for gets a small
/// form, and a load that fails shows "Couldn't load localhost:3000" with Retry. Done or a swipe
/// down closes it, and the pane that had the keyboard gets it back.
@MainActor
final class PreviewBrowser: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
    UIAdaptivePresentationControllerDelegate, UITextFieldDelegate {
    private(set) var page: PreviewPage
    private let onClose: () -> Void
    /// Go in the address line, with the text typed.
    private let onAddress: (@MainActor (String, PreviewBrowser) -> Void)?
    private var titleStack: UIStackView?
    private var addressField: UITextField?
    private var closed = false
    private(set) var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    /// The pane's view that held the keyboard when the page came up.
    private weak var keyboardHolder: UIResponder?
    /// The load that failed, for Retry.
    private var failed: URL?
    private var downloads: [ObjectIdentifier: URL] = [:]

    private let titleLabel = UILabel()
    private let hostLabel = UILabel()
    /// The error page, put together the first time a load fails.
    private let errorView = UIView()
    private let errorTitle = UILabel()
    private let errorDetail = UILabel()
    private var errorBuilt = false
    /// The bars are up with the menu and the arrows in them (`buildItems`).
    private var itemsBuilt = false
    /// The sheet began to appear, and the bars were asked for.
    private var barsAsked = false
    /// What the web view loads once it exists: the page, or a path typed before it did.
    private var firstLoad: URL?
    private lazy var backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in self?.webView?.goBack() })
    private lazy var forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), primaryAction: UIAction { [weak self] _ in self?.webView?.goForward() })
    private lazy var reloadItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in self?.reload() })
    #if DEBUG
    /// Called after the chrome, the error page or what is shown over the page changed, and
    /// `gone` when the browser is released: tests wait on these, not on the clock. Debug builds
    /// only; the shipped class has neither.
    var onChange: (() -> Void)?
    var gone: (@Sendable () -> Void)?
    #endif
    /// Where pages keep their cookies and storage: the app's one store, so a login on a dev
    /// server is still there the next time its page opens.
    static var siteData: @MainActor () -> WKWebsiteDataStore = { .default() }
    /// Copies a link. Tests put their own here.
    var copy: (String) -> Void = { UIPasteboard.general.string = $0 }

    /// The one shown now; it keeps itself alive while up.
    private static var current: PreviewBrowser?

    init(page: PreviewPage, onAddress: (@MainActor (String, PreviewBrowser) -> Void)? = nil, onClose: @escaping () -> Void) {
        self.page = page
        self.onAddress = onAddress
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the page over `view`'s window. False when there is no window to present from.
    @discardableResult
    static func present(_ page: PreviewPage, over view: UIView?, onAddress: (@MainActor (String, PreviewBrowser) -> Void)? = nil,
                        onClose: @escaping () -> Void) -> Bool {
        guard var top = view?.window?.rootViewController else { return false }
        let trace = PreviewTrace.begin("present")
        defer { PreviewTrace.end(trace) }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let browser = PreviewBrowser(page: page, onAddress: onAddress, onClose: onClose)
        if let view, let holder = UIResponder.rexCurrentFirstResponder() as? UIView, holder.isDescendant(of: view) {
            browser.keyboardHolder = holder
        }
        let nav = UINavigationController(rootViewController: browser)
        // The bars are shown one turn after the sheet (`buildItems`).
        nav.setNavigationBarHidden(true, animated: false)
        // Opaque bars with the page between them: a page is any color, and the bars' text
        // must read over none of it.
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        nav.navigationBar.standardAppearance = bar
        nav.navigationBar.scrollEdgeAppearance = bar
        nav.navigationBar.compactAppearance = bar
        let tools = UIToolbarAppearance()
        tools.configureWithOpaqueBackground()
        nav.toolbar.standardAppearance = tools
        nav.toolbar.scrollEdgeAppearance = tools
        nav.toolbar.compactAppearance = tools
        current = browser
        top.present(nav, animated: true)
        nav.presentationController?.delegate = browser
        return true
    }

    // MARK: View

    /// The sheet's first frame is the sheet alone. Its bars, with the title, the address, Done,
    /// the menu and the arrows, are shown on the turn after, while the sheet has only begun to
    /// rise: laying out bars is most of what a sheet with bars costs over an empty one, and in
    /// the sheet's own first turn it would hold the main thread for both. The web view is the
    /// one costly thing to make, and WebKit makes it on the main thread only, so it is made on
    /// a turn of its own after that, its load starts at once, and it joins the view on the turn
    /// after: the main thread is never held for all of them together. Nothing is made before a
    /// page opens.
    override func viewDidLoad() {
        super.viewDidLoad()
        let trace = PreviewTrace.begin("viewDidLoad")
        defer { PreviewTrace.end(trace) }
        view.backgroundColor = .systemBackground
        errorView.isHidden = true
        PreviewTrace.measure("buildChrome") { buildChrome() }
        refresh()
    }

    /// The turn in which the sheet starts to rise is UIKit's own and the longest of an open, so
    /// nothing of ours is in it: what the bars hold is asked for from inside that turn and made
    /// on the one after.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !barsAsked else { return }
        barsAsked = true
        DispatchQueue.main.async { [weak self] in self?.buildItems() }
    }

    #if DEBUG || BENCH
    private var transitionTrace: PreviewTrace.Interval?
    private var laidOut = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Once: the view appears again each time something shown over it goes.
        if !laidOut { transitionTrace = PreviewTrace.begin("transition") }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PreviewTrace.end(transitionTrace)
        transitionTrace = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !laidOut {
            laidOut = true
            PreviewTrace.event("firstLayout")
        }
    }
    #endif

    private func makeWebView() {
        guard !closed, webView == nil else { return }
        let trace = PreviewTrace.begin("makeWebView")
        defer { PreviewTrace.end(trace) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.siteData()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: view.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        web.load(URLRequest(url: firstLoad ?? page.load))
        firstLoad = nil
        DispatchQueue.main.async { [weak self, weak web] in
            if let self, let web { self.attach(web) }
        }
    }

    private func attach(_ web: WKWebView) {
        guard !closed, webView === web else { return }
        let trace = PreviewTrace.begin("attach")
        defer { PreviewTrace.end(trace) }
        web.translatesAutoresizingMaskIntoConstraints = false
        web.allowsBackForwardNavigationGestures = true
        view.insertSubview(web, at: 0)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        observers = [
            web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } },
            web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } },
            web.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } },
            web.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.refresh() } },
        ]
        refresh()
    }

    private func buildChrome() {
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        hostLabel.font = .preferredFont(forTextStyle: .caption2)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.textColor = .secondaryLabel
        hostLabel.textAlignment = .center
        hostLabel.lineBreakMode = .byTruncatingMiddle
        let stack = UIStackView(arrangedSubviews: [titleLabel, hostLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.isAccessibilityElement = true
        if onAddress != nil {
            stack.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(editAddress)))
            stack.accessibilityHint = "Edits the address"
            stack.accessibilityTraits = .button
        }
        titleStack = stack
        navigationItem.titleView = stack
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.done() })
    }

    /// The bars and what they hold, one turn after the sheet: the menu and the arrows are made
    /// here, and both bars are shown with everything in them at once.
    private func buildItems() {
        guard !closed, !itemsBuilt else { return }
        PreviewTrace.measure("buildItems") {
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu())
            more.accessibilityLabel = "More"
            navigationItem.rightBarButtonItem = more
            backItem.accessibilityLabel = "Back"
            forwardItem.accessibilityLabel = "Forward"
            reloadItem.accessibilityLabel = "Reload"
            let gap = UIBarButtonItem(systemItem: .fixedSpace)
            gap.width = 28
            toolbarItems = [backItem, gap, forwardItem, UIBarButtonItem(systemItem: .flexibleSpace), reloadItem]
            itemsBuilt = true
            navigationController?.setNavigationBarHidden(false, animated: false)
            navigationController?.setToolbarHidden(false, animated: false)
        }
        refresh()
        DispatchQueue.main.async { [weak self] in self?.makeWebView() }
    }

    private func makeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { [weak self] _ in self?.copyLink() },
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() },
        ])
    }

    private func buildErrorView() {
        guard !errorBuilt else { return }
        errorBuilt = true
        errorView.backgroundColor = .systemBackground
        errorView.frame = view.bounds
        errorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        errorTitle.font = .preferredFont(forTextStyle: .headline)
        errorTitle.adjustsFontForContentSizeCategory = true
        errorTitle.textAlignment = .center
        errorTitle.numberOfLines = 0
        errorDetail.font = .preferredFont(forTextStyle: .subheadline)
        errorDetail.adjustsFontForContentSizeCategory = true
        errorDetail.textColor = .secondaryLabel
        errorDetail.textAlignment = .center
        errorDetail.numberOfLines = 0
        var style = UIButton.Configuration.tinted()
        style.title = "Retry"
        style.cornerStyle = .capsule
        let retry = UIButton(configuration: style, primaryAction: UIAction { [weak self] _ in self?.retry() })
        let stack = UIStackView(arrangedSubviews: [errorTitle, errorDetail, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.setCustomSpacing(18, after: errorDetail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: errorView.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: errorView.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    /// The title, the address and the arrows, from the page on screen. WebKit reports its
    /// title, address and history several times a load; only what changed is touched.
    private func refresh() {
        let current = failed ?? webView?.url
        let host = PreviewAddress.display(current, page)
        // A failed load has no title of its own: the page before it must not name it.
        let title = failed == nil ? (webView?.title.flatMap { $0.isEmpty ? nil : $0 } ?? host) : host
        if titleLabel.text != title || hostLabel.text != host {
            titleLabel.text = title
            hostLabel.text = host
            hostLabel.isHidden = title == host
            navigationItem.titleView?.accessibilityLabel = "\(title), \(host)"
            (navigationItem.titleView as? UIStackView)?.sizeToFit()
        }
        if itemsBuilt {
            let back = webView?.canGoBack ?? false, forward = webView?.canGoForward ?? false
            if backItem.isEnabled != back { backItem.isEnabled = back }
            if forwardItem.isEnabled != forward { forwardItem.isEnabled = forward }
        }
        #if DEBUG
        onChange?()
        #endif
    }

    #if DEBUG
    deinit { gone?() }
    #endif

    // MARK: The address line

    /// The title becomes a field holding the address as shown. Go hands the text on; leaving
    /// the field any other way puts the title back.
    @objc func editAddress() {
        guard onAddress != nil, addressField == nil else { return }
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: max(200, view.bounds.width - 150), height: 36))
        field.text = PreviewAddress.editing(failed ?? webView?.url, page)
        field.font = .preferredFont(forTextStyle: .subheadline)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .roundedRect
        field.keyboardType = .URL
        field.returnKeyType = .go
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = "Address"
        field.delegate = self
        addressField = field
        navigationItem.titleView = field
        field.becomeFirstResponder()
    }

    /// The whole address is selected, so typing replaces it, as in Safari. On the next turn:
    /// a selection made while the field takes the keyboard doesn't hold.
    func textFieldDidBeginEditing(_ textField: UITextField) {
        DispatchQueue.main.async { [weak textField] in
            guard let f = textField, f.isFirstResponder else { return }
            f.selectedTextRange = f.textRange(from: f.beginningOfDocument, to: f.endOfDocument)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        textField.resignFirstResponder()
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { onAddress?(text, self) }
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard addressField === textField else { return }
        addressField = nil
        navigationItem.titleView = titleStack
        refresh()
    }

    /// What `say` showed, newest last (tests read it).
    private(set) var said: [String] = []
    private weak var sayLabel: UIView?

    /// One quiet line over the page for a few seconds: why what was typed opened nothing. The
    /// app's own notices sit under this sheet, where nobody would see them.
    func say(_ text: String) {
        said.append(text)
        guard isViewLoaded else { return }
        sayLabel?.removeFromSuperview()
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        pill.layer.cornerRadius = 14
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.contentView.addSubview(label)
        view.addSubview(pill)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -14),
            pill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        sayLabel = pill
        pill.alpha = 0
        UIView.animate(withDuration: 0.2) { pill.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak pill] in
            UIView.animate(withDuration: 0.3, animations: { pill?.alpha = 0 }, completion: { _ in pill?.removeFromSuperview() })
        }
    }

    /// The same server's page at another path, shown under the address as typed.
    func move(to address: PortAddress) {
        page.shown = address.shown
        page.scheme = address.scheme
        failed = nil
        errorView.isHidden = true
        if let url = PreviewAddress.load(address.rest, page) {
            if let webView { webView.load(URLRequest(url: url)) } else { firstLoad = url }
        }
        refresh()
    }

    // MARK: What the chrome shows (tests read these)

    var shownTitle: String? { titleLabel.text }
    var shownHost: String? { hostLabel.text }
    var shownError: String? { errorView.isHidden ? nil : errorTitle.text }
    var editedText: String? { addressField?.text }

    // MARK: Actions

    private func reload() {
        if failed != nil { retry() } else { webView?.reload() }
    }

    private func retry() {
        let url = failed ?? webView?.url ?? page.load
        failed = nil
        errorView.isHidden = true
        webView?.load(URLRequest(url: url))
    }

    func copyLink() {
        copy(PreviewAddress.link(failed ?? webView?.url, page))
    }

    private func share() {
        guard let url = URL(string: PreviewAddress.link(failed ?? webView?.url, page)) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    private func done(then: (() -> Void)? = nil) {
        (navigationController ?? self).dismiss(animated: true, completion: then)
        finish()
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { finish() }
    }

    /// Closes the page as Done does, for a caller that isn't a tap. `then` runs once it is gone.
    func close(then: (() -> Void)? = nil) { done(then: then) }

    /// The page is gone: the web view is let go, so its process can end, and the forward closes.
    private func finish() {
        guard !closed else { return }
        closed = true
        observers = []
        if let web = webView {
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.removeFromSuperview()
        }
        webView = nil
        for file in downloads.values { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        downloads = [:]
        onClose()
        if Self.current === self { Self.current = nil }
        if let holder = keyboardHolder { Self.giveKeyboardBack(to: holder, tries: 20) }
    }

    /// Once the page is gone (Done calls `finish` before the page slides away), the pane takes
    /// the keyboard again, unless something else took it or the pane left the screen meanwhile.
    private static func giveKeyboardBack(to holder: UIResponder, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak holder] in
            guard let view = holder as? UIView, let window = view.window, !view.isFirstResponder,
                  UIResponder.rexCurrentFirstResponder() == nil else { return }
            if window.rootViewController?.presentedViewController != nil {
                if tries > 0 { giveKeyboardBack(to: view, tries: tries - 1) }
                return
            }
            _ = view.becomeFirstResponder()
        }
    }

    // MARK: Loads

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failed = nil
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        show(error)
    }

    /// The error page, in the app's own words: the address as the user knows it, never the one
    /// that loads underneath.
    private func show(_ error: Error) {
        guard PreviewAddress.showsError(error) else { return }
        let e = error as NSError
        failed = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView?.url ?? page.load
        buildErrorView()
        errorTitle.text = PreviewAddress.errorTitle(failed, page)
        errorDetail.text = Self.reason(e)
        errorView.isHidden = false
        refresh()
    }

    /// Why a load failed, in a few words that name no address.
    static func reason(_ e: NSError) -> String {
        guard e.domain == NSURLErrorDomain else { return "The page didn't load." }
        switch e.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return "Nothing answered there. Is the server still running?"
        case NSURLErrorTimedOut: return "It took too long to answer."
        case NSURLErrorNotConnectedToInternet: return "The phone is offline."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return "Its secure connection couldn't be trusted."
        default: return "The page didn't load."
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        return PreviewAddress.loads(action.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        guard response.isForMainFrame else { return .allow }
        return PreviewAddress.isDownload(canShow: response.canShowMIMEType, disposition: disposition) ? .download : .allow
    }

    /// A link for a new window or tab opens here: there is one view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, PreviewAddress.loads(action.request.url) { webView.load(action.request) }
        return nil
    }

    // MARK: Sign-in

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount < 3 else { return (.performDefaultHandling, nil) }
        let host = PreviewAddress.display(webView.url, page)
        return await withCheckedContinuation { answer in
            let alert = UIAlertController(title: "Sign in to \(host)", message: challenge.protectionSpace.realm, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Name"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.textContentType = .username }
            alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true; $0.textContentType = .password }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer.resume(returning: (.cancelAuthenticationChallenge, nil)) })
            alert.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak alert] _ in
                let user = alert?.textFields?.first?.text ?? "", password = alert?.textFields?.last?.text ?? ""
                answer.resume(returning: (.useCredential, URLCredential(user: user, password: password, persistence: .forSession)))
            })
            present(alert, animated: true)
            #if DEBUG
            onChange?()
            #endif
        }
    }

    // MARK: Page dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume() })
            present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
            present(alert, animated: true)
        }
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let name = (suggestedFilename as NSString).lastPathComponent
        let file = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        downloads[ObjectIdentifier(download)] = file
        return file
    }

    /// The file goes to the share sheet, and leaves the phone's temporary folder with it.
    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        guard !closed, presentedViewController == nil else {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            return
        }
        present(sheet, animated: true)
        #if DEBUG
        onChange?()
        #endif
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        Notice.shared.show("Couldn't download that file.", style: .neutral)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
