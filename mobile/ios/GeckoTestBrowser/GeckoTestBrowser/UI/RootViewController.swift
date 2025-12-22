// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import GeckoView
import UIKit

// Holds toolbar, search bar, search and browser VCs
class RootViewController: UIViewController {
    private lazy var toolbar: BrowserToolbar = .build { _ in }
    private lazy var searchBar: BrowserSearchBar = .build { _ in }
    private lazy var statusBarFiller: UIView = .build { view in
        view.backgroundColor = .white
    }
    private lazy var progress: UIProgressView = .build { _ in }
    private lazy var geckoview: GeckoView = .build { _ in }

    // Be lenient about what is classified as potentially a URL.
    // (\w+-+)*[\w\[]+(://[/]*|:|\.)(\w+-+)*[\w\[:]+([\S&&[^\w-]]\S*)?
    // --------                     --------
    // 0 or more pairs of consecutive word letters or dashes
    //         -------                      --------
    // followed by at least a single word letter or [ipv6::] character.
    // ---------------              ----------------
    // Combined, that means "w", "w-w", "w-w-w", etc match, but "w-", "w-w-", "w-w-w-" do not.
    //                --------------
    // That surrounds :, :// or .
    //                                                               -
    // At the end, there may be an optional
    //                                               ------------
    // non-word, non-- but still non-space character (e.g., ':', '/', '.', '?' but not 'a', '-', '\t')
    //                                                           ---
    // and 0 or more non-space characters.
    //
    // These are some (odd) examples of valid urls according to this pattern:
    // c-c.com
    // c-c-c-c.c-c-c
    // c-http://c.com
    // about-mozilla:mozilla
    // c-http.d-x
    // www.c-
    // 3-3.3
    // www.c-c.-
    //
    // There are some examples of non-URLs according to this pattern:
    // -://x.com
    // -x.com
    // http://www-.com
    // www.c-c-
    // 3-3
    private lazy var isURLLenient =
        try! Regex("^\\s*(\\w+-+)*[\\w\\[]+(://[/]*|:|\\.)(\\w+-+)*[\\w\\[:]+([\\S&&[^\\w-]]\\S*)?\\s*$")

    // Note: For easier debugging, we might need to load
    // same URL again and for this use the following homepage url
    private var homepage = ""
    
    private let tabManager = TabManager()
    private lazy var backgroundView = AppBackgroundView()

    // MARK: - Init

    init() {
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = Theme.background
        tabManager.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Life cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundView)
        view.sendSubviewToBack(backgroundView)
        
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureProgress()
        configureBrowserView()
        configureSearchbar()
        configureToolbar()

        tabManager.createNewTab()

        if !homepage.isEmpty {
            browse(to: homepage)
        }
    }

    private func configureBrowserView() {
        geckoview.backgroundColor = .clear
        geckoview.isOpaque = false
        view.addSubview(geckoview)

        NSLayoutConstraint.activate([
            geckoview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            geckoview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            geckoview.topAnchor.constraint(equalTo: progress.bottomAnchor),
        ])
    }

    private func configureProgress() {
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 3),
        ])

        progress.progressTintColor = Theme.secondary
    }

    private func configureSearchbar() {
        statusBarFiller.backgroundColor = Theme.surface
        view.addSubview(statusBarFiller)
        view.addSubview(searchBar)
        
        searchBar.backgroundColor = Theme.surface.withAlphaComponent(0.9)

        NSLayoutConstraint.activate([
            statusBarFiller.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarFiller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarFiller.bottomAnchor.constraint(equalTo: searchBar.topAnchor),
            statusBarFiller.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.bottomAnchor.constraint(equalTo: progress.topAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        searchBar.configure(browserDelegate: self)
        searchBar.becomeFirstResponder()
    }

    private func configureToolbar() {
        view.addSubview(toolbar)
        
        toolbar.barTintColor = Theme.surface
        toolbar.tintColor = Theme.primary
        toolbar.isTranslucent = true
        toolbar.backgroundColor = .clear
        toolbar.setBackgroundImage(UIImage(), forToolbarPosition: .any, barMetrics: .default)
        toolbar.setShadowImage(UIImage(), forToolbarPosition: .any)
        
        // Add blur to toolbar
        let blurEffect = UIBlurEffect(style: .dark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = toolbar.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.isUserInteractionEnabled = false
        toolbar.insertSubview(blurView, at: 0)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: geckoview.bottomAnchor),
        ])

        toolbar.toolbarDelegate = self
    }

    private func browse(to term: String) {
        searchBar.resignFirstResponder()

        let trimmedValue = term.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedValue.isEmpty else { return }

        if (try? isURLLenient.wholeMatch(in: term)) != nil {
            geckoview.session?.load(term)
        } else {
            // If not a valid URL, create a search URL
            let encodedValue =
                trimmedValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            geckoview.session?.load("https://www.google.com/search?q=\(encodedValue)")
        }
    }
}

// MARK: - BrowserToolbarDelegate
extension RootViewController: BrowserToolbarDelegate {
    func backButtonClicked() {
        geckoview.session?.goBack()
    }

    func forwardButtonClicked() {
        geckoview.session?.goForward()
    }

    func reloadButtonClicked() {
        geckoview.session?.reload()
    }

    func stopButtonClicked() {
        geckoview.session?.stop()
    }

    func tabsButtonClicked() {
        if let activeTab = tabManager.activeTab {
            updateSnapshot(for: activeTab)
        }

        let tabListVC = TabListViewController()
        tabListVC.tabs = tabManager.tabs
        tabListVC.delegate = self
        tabListVC.modalPresentationStyle = .overFullScreen
        present(tabListVC, animated: true, completion: nil)
    }

    private func updateSnapshot(for tab: Tab) {
        let renderer = UIGraphicsImageRenderer(bounds: geckoview.bounds)
        let image = renderer.image { _ in
            geckoview.drawHierarchy(in: geckoview.bounds, afterScreenUpdates: false)
        }
        tab.snapshot = image
    }
}

// MARK: - BrowserSearchBarDelegate
extension RootViewController: BrowserSearchBarDelegate {
    func openBrowser(searchTerm: String) {
        guard let searchText = searchBar.getSearchBarText(), !searchText.isEmpty else { return }
        browse(to: searchText)
    }
}

// MARK: - ContentDelegate
extension RootViewController: ContentDelegate {
    func onTitleChange(session: GeckoSession, title: String) {
        if let tab = tabManager.tabs.first(where: { $0.session === session }) {
            tab.title = title
        }
    }

    func onPreviewImage(session: GeckoSession, previewImageUrl: String) {}

    func onFocusRequest(session: GeckoSession) {}

    func onCloseRequest(session: GeckoSession) {}

    func onFullScreen(session: GeckoSession, fullScreen: Bool) {}

    func onMetaViewportFitChange(session: GeckoSession, viewportFit: String) {}

    func onProductUrl(session: GeckoSession) {}

    func onContextMenu(
        session: GeckoSession, screenX: Int, screenY: Int, element: ContextElement
    ) {}

    func onCrash(session: GeckoSession) {}

    func onKill(session: GeckoSession) {}

    func onFirstComposite(session: GeckoSession) {}

    func onFirstContentfulPaint(session: GeckoSession) {}

    func onPaintStatusReset(session: GeckoSession) {}

    func onWebAppManifest(session: GeckoSession, manifest: Any) {}

    func onSlowScript(session: GeckoSession, scriptFileName: String) async
        -> SlowScriptResponse
    { .halt }

    func onShowDynamicToolbar(session: GeckoSession) {}

    func onCookieBannerDetected(session: GeckoSession) {}

    func onCookieBannerHandled(session: GeckoSession) {}
}

// MARK: - NavigationDelegate
extension RootViewController: NavigationDelegate {
    func onLocationChange(
        session: GeckoSession, url: String?, permissions: [ContentPermission]
    ) {}

    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        self.toolbar.updateBackButton(canGoBack: canGoBack)
    }

    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        self.toolbar.updateForwardButton(canGoForward: canGoForward)
    }

    func onLoadRequest(session: GeckoSession, request: LoadRequest) -> AllowOrDeny { .allow }

    func onSubframeLoadRequest(session: GeckoSession, request: LoadRequest) -> AllowOrDeny {
        .allow
    }

    func onNewSession(session: GeckoSession, uri: String) -> GeckoSession? { nil }
}

// MARK: - ProgressDelegate
extension RootViewController: ProgressDelegate {
    func onPageStart(session: GeckoSession, url: String) {
        self.progress.isHidden = false
        toolbar.updateReloadStopButton(isLoading: true)
    }

    func onPageStop(session: GeckoSession, success: Bool) {
        toolbar.updateReloadStopButton(isLoading: false)
        self.progress.isHidden = true
    }

    func onProgressChange(session: GeckoSession, progress: Int) {
        self.progress.progress = Float(progress) / 100
    }
}

// MARK: - TabManagerDelegate
extension RootViewController: TabManagerDelegate {
    func didUpdateActiveTab(_ tab: Tab) {
        tab.session.contentDelegate = self
        tab.session.progressDelegate = self
        tab.session.navigationDelegate = self

        geckoview.session = tab.session

        // Reset UI state for new tab
        toolbar.updateBackButton(canGoBack: false) // Ideally query session
        toolbar.updateForwardButton(canGoForward: false)
        toolbar.updateReloadStopButton(isLoading: false)
        searchBar.setSearchBarText("") // Or current URL
    }

    func didAddTab(_ tab: Tab) {
        // Optional: Show some indication
    }

    func didRemoveTab(_ tab: Tab) {
        // Optional: Show some indication
    }
}

// MARK: - TabListViewControllerDelegate
extension RootViewController: TabListViewControllerDelegate {
    func didSelectTab(_ tab: Tab) {
        tabManager.selectTab(tab)
        dismiss(animated: true, completion: nil)
    }
    
    func didRequestNewTab() {
        tabManager.createNewTab()
        dismiss(animated: true, completion: nil)
    }
    
    func didCloseTab(_ tab: Tab) {
        tabManager.removeTab(tab)
        if let tabListVC = presentedViewController as? TabListViewController {
            tabListVC.tabs = tabManager.tabs
        }
    }
}

// MARK: - Models & UI

struct Theme {
    static let background = UIColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 1.0) // Very Dark Blue
    static let surface = UIColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1.0) // Dark Blue Surface
    static let primary = UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0) // Blue
    static let secondary = UIColor(red: 0.4, green: 0.7, blue: 0.9, alpha: 1.0) // Light Blue
    static let accent = UIColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0) // Purple Accent
    static let text = UIColor(white: 0.95, alpha: 1.0)
    static let textSecondary = UIColor(white: 0.7, alpha: 1.0)
}

class AppBackgroundView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.background
        isUserInteractionEnabled = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        // Grid Pattern
        drawGrid(in: rect, context: context)
        
        // Hexagons (Top Right)
        drawHexagons(in: rect, context: context)
        
        // Triangles (Bottom Left)
        drawTriangles(in: rect, context: context)
        
        // Circles/Squares (Bottom Right)
        drawCircles(in: rect, context: context)
        
        // Rotated Squares (Top Left)
        drawRotatedSquares(in: rect, context: context)
        
        // Dots (Center Left)
        drawDots(in: rect, context: context)
    }
    
    private func drawGrid(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(Theme.primary.withAlphaComponent(0.03).cgColor)
        context.setLineWidth(1)
        
        let gridSize: CGFloat = 40
        
        for x in stride(from: 0, to: rect.width, by: gridSize) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: rect.height))
        }
        
        for y in stride(from: 0, to: rect.height, by: gridSize) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: rect.width, y: y))
        }
        
        context.strokePath()
        context.restoreGState()
    }
    
    private func drawHexagons(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.width + 20, y: -20)
        context.setStrokeColor(Theme.primary.withAlphaComponent(0.07).cgColor)
        context.setLineWidth(1)
        
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 12, y: 2))
        path.addLine(to: CGPoint(x: 2, y: 7.5))
        path.addLine(to: CGPoint(x: 2, y: 16.5))
        path.addLine(to: CGPoint(x: 12, y: 22))
        path.addLine(to: CGPoint(x: 22, y: 16.5))
        path.addLine(to: CGPoint(x: 22, y: 7.5))
        path.close()
        
        for i in 0..<24 {
            context.saveGState()
            context.rotate(by: CGFloat(i) * 15 * .pi / 180)
            context.translateBy(x: 0, y: -120)
            
            let scaleX: CGFloat = 40/24.0
            let scaleY: CGFloat = 35/24.0
            context.scaleBy(x: scaleX, y: scaleY)
            
            context.addPath(path.cgPath)
            context.strokePath()
            context.restoreGState()
        }
        context.restoreGState()
    }
    
    private func drawTriangles(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: -10, y: rect.height * 0.75)
        context.setFillColor(Theme.secondary.withAlphaComponent(0.06).cgColor)
        
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 1, y: 21))
        path.addLine(to: CGPoint(x: 23, y: 21))
        path.addLine(to: CGPoint(x: 12, y: 2))
        path.close()
        
        let size: CGFloat = 40
        let gap: CGFloat = 24
        
        for i in 0..<25 {
            let col = i % 5
            let row = i / 5
            let x = CGFloat(col) * (size + gap)
            let y = CGFloat(row) * (size + gap)
            
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.scaleBy(x: size/24.0, y: size/24.0)
            
            if i % 2 != 0 {
                context.translateBy(x: 12, y: 12)
                context.rotate(by: .pi)
                context.translateBy(x: -12, y: -12)
            }
            
            context.addPath(path.cgPath)
            context.fillPath()
            context.restoreGState()
        }
        context.restoreGState()
    }
    
    private func drawCircles(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.width * 0.75, y: rect.height + 20)
        
        let size: CGFloat = 32
        let gap: CGFloat = 16
        
        for i in 0..<16 {
            let col = i % 4
            let row = i / 4
            let x = CGFloat(col) * (size + gap)
            let y = CGFloat(row) * (size + gap)
            
            let circleRect = CGRect(x: x, y: y, width: size, height: size)
            
            context.setStrokeColor(Theme.accent.withAlphaComponent(0.06).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: circleRect)
            
            if i % 3 == 0 {
                context.setFillColor(Theme.accent.withAlphaComponent(0.012).cgColor)
                context.fillEllipse(in: circleRect)
            }
        }
        context.restoreGState()
    }
    
    private func drawRotatedSquares(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.height / 3)
        context.setStrokeColor(Theme.primary.withAlphaComponent(0.05).cgColor)
        context.setLineWidth(1)
        
        let size: CGFloat = 48
        let gap: CGFloat = 8
        
        for i in 0..<9 {
            let col = i % 3
            let row = i / 3
            let x = CGFloat(col) * (size + gap)
            let y = CGFloat(row) * (size + gap)
            
            context.saveGState()
            context.translateBy(x: x + size/2, y: y + size/2)
            if i % 2 == 0 {
                context.rotate(by: .pi / 4)
            }
            context.stroke(CGRect(x: -size/2, y: -size/2, width: size, height: size))
            context.restoreGState()
        }
        context.restoreGState()
    }
    
    private func drawDots(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.width / 4, y: rect.height / 2)
        
        let size: CGFloat = 4
        let gap: CGFloat = 12
        
        for i in 0..<100 {
            let col = i % 10
            let row = i / 10
            let x = CGFloat(col) * (size + gap)
            let y = CGFloat(row) * (size + gap)
            
            let dotRect = CGRect(x: x, y: y, width: size, height: size)
            
            if i % 5 == 0 {
                context.setFillColor(Theme.primary.withAlphaComponent(0.08).cgColor)
            } else if i % 3 == 0 {
                context.setFillColor(Theme.secondary.withAlphaComponent(0.08).cgColor)
            } else {
                context.setFillColor(Theme.accent.withAlphaComponent(0.08).cgColor)
            }
            context.fillEllipse(in: dotRect)
        }
        context.restoreGState()
    }
}

class Tab {
    let id: String
    var session: GeckoSession
    var title: String = "New Tab"
    var snapshot: UIImage?
    
    init(session: GeckoSession) {
        self.id = UUID().uuidString
        self.session = session
    }
}

protocol TabManagerDelegate: AnyObject {
    func didUpdateActiveTab(_ tab: Tab)
    func didAddTab(_ tab: Tab)
    func didRemoveTab(_ tab: Tab)
}

class TabManager {
    private(set) var tabs: [Tab] = []
    private(set) var activeTab: Tab?
    
    weak var delegate: TabManagerDelegate?
    
    func addTab(session: GeckoSession) {
        let tab = Tab(session: session)
        tabs.append(tab)
        delegate?.didAddTab(tab)
        selectTab(tab)
    }
    
    func selectTab(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        activeTab = tab
        delegate?.didUpdateActiveTab(tab)
    }
    
    func removeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        delegate?.didRemoveTab(tab)
        
        if activeTab?.id == tab.id {
            if let nextTab = tabs.last {
                 selectTab(nextTab)
            } else {
                activeTab = nil
                createNewTab()
            }
        }
    }
    
    @discardableResult
    func createNewTab() -> Tab {
        let session = GeckoSession()
        session.open()
        let tab = Tab(session: session)
        tabs.append(tab)
        delegate?.didAddTab(tab)
        selectTab(tab)
        return tab
    }
}

protocol TabListViewControllerDelegate: AnyObject {
    func didSelectTab(_ tab: Tab)
    func didRequestNewTab()
    func didCloseTab(_ tab: Tab)
}

class TabCell: UICollectionViewCell {
    static let identifier = "TabCell"
    
    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = Theme.surface
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1
        view.layer.borderColor = Theme.primary.withAlphaComponent(0.3).cgColor
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = Theme.background
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()
    
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.text
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let closeButton: UIButton = {
        let btn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        btn.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        btn.tintColor = Theme.secondary
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()
    
    var closeHandler: (() -> Void)?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        contentView.addSubview(containerView)
        containerView.addSubview(imageView)
        containerView.addSubview(titleLabel)
        contentView.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: containerView.heightAnchor, multiplier: 0.8),
            
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            
            closeButton.topAnchor.constraint(equalTo: containerView.topAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func configure(with tab: Tab) {
        titleLabel.text = tab.title
        imageView.image = tab.snapshot
    }
    
    @objc private func didTapClose() {
        closeHandler?()
    }
}

class TabListViewController: UIViewController {
    weak var delegate: TabListViewControllerDelegate?
    var tabs: [Tab] = [] {
        didSet {
            if isViewLoaded {
                collectionView.reloadData()
            }
        }
    }
    
    private lazy var backgroundView = AppBackgroundView()
    
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        let width = (UIScreen.main.bounds.width - 48) / 2
        layout.itemSize = CGSize(width: width, height: width * 1.4)
        layout.sectionInset = UIEdgeInsets(top: 20, left: 16, bottom: 80, right: 16)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 24
        
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.register(TabCell.self, forCellWithReuseIdentifier: TabCell.identifier)
        cv.dataSource = self
        cv.delegate = self
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()
    
    private lazy var bottomBar: UIView = {
        let view = UIView()
        let blurEffect = UIBlurEffect(style: .dark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blurView)
        
        view.backgroundColor = Theme.surface.withAlphaComponent(0.7)
        view.layer.borderWidth = 1
        view.layer.borderColor = Theme.primary.withAlphaComponent(0.2).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let newTabButton = UIButton(type: .system)
        let plusConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: plusConfig), for: .normal)
        newTabButton.tintColor = Theme.accent
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.addTarget(self, action: #selector(didTapNewTab), for: .touchUpInside)
        
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        doneButton.tintColor = Theme.primary
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(didTapDone), for: .touchUpInside)
        
        view.addSubview(newTabButton)
        view.addSubview(doneButton)
        
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: view.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            newTabButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newTabButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -10),
            
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            doneButton.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            
            view.heightAnchor.constraint(equalToConstant: 80)
        ])
        
        return view
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundView)
        view.addSubview(collectionView)
        view.addSubview(bottomBar)
        
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    @objc private func didTapNewTab() {
        delegate?.didRequestNewTab()
    }
    
    @objc private func didTapDone() {
        dismiss(animated: true, completion: nil)
    }
}

extension TabListViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return tabs.count
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabCell.identifier, for: indexPath) as? TabCell else {
            return UICollectionViewCell()
        }
        
        let tab = tabs[indexPath.item]
        cell.configure(with: tab)
        cell.closeHandler = { [weak self] in
            self?.delegate?.didCloseTab(tab)
        }
        
        return cell
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let tab = tabs[indexPath.item]
        delegate?.didSelectTab(tab)
    }
}
