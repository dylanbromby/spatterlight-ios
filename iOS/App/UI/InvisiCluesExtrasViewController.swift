import UIKit

/// Box feelies and InvisiClues map scans for one game.
final class GameAssetsViewController: UITableViewController {
    private let game: GameRecord
    private let fetcher = InvisiCluesAssetFetcher.shared
    private var manifest: InvisiCluesAssetFetcher.Manifest?
    private var isLoading = false
    private var statusMessage: String?

    init(game: GameRecord) {
        self.game = game
        self.manifest = fetcher.manifest(for: game)
        super.init(style: .insetGrouped)
        title = "Game assets"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Refresh", primaryAction: UIAction { [weak self] _ in
            self?.startInstall()
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if manifest == nil, !isLoading { startInstall() }
    }

    private func startInstall() {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = "Copying bundled assets…"
        navigationItem.leftBarButtonItem?.isEnabled = false
        tableView.reloadData()
        fetcher.installNow(gameID: game.id) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            self.navigationItem.leftBarButtonItem?.isEnabled = true
            switch result {
            case .success(let manifest):
                self.manifest = manifest
                self.statusMessage = nil
            case .failure(let error):
                self.statusMessage = error.localizedDescription
            }
            self.tableView.reloadData()
        }
    }

    private struct Section {
        var title: String
        var assets: [InvisiCluesAssetFetcher.Manifest.Asset]
    }

    private var sections: [Section] {
        guard let manifest else { return [] }
        var list: [Section] = []
        if !manifest.inTheBox.isEmpty { list.append(Section(title: "In the box", assets: manifest.inTheBox)) }
        if !manifest.maps.isEmpty { list.append(Section(title: "Maps", assets: manifest.maps)) }
        return list
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.isEmpty ? 1 : sections.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !sections.isEmpty else { return nil }
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if sections.isEmpty { return 1 }
        return sections[section].assets.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if sections.isEmpty {
            var content = cell.defaultContentConfiguration()
            if isLoading {
                content.text = "Loading…"
                content.secondaryText = statusMessage
            } else {
                content.text = "No assets yet"
                content.secondaryText = statusMessage ?? "Bundled Infocom box art and maps install automatically for matching titles."
            }
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }
        let asset = sections[indexPath.section].assets[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = asset.title
        content.secondaryText = (asset.fileName as NSString).lastPathComponent
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = thumbnail(for: asset)
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.cornerRadius = 6
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !sections.isEmpty else { return }
        let asset = sections[indexPath.section].assets[indexPath.row]
        let url = fetcher.fileURL(for: game, asset: asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        navigationController?.pushViewController(ScannedImageViewController(title: asset.title, fileURL: url), animated: true)
    }

    private var thumbnailCache: [String: UIImage] = [:]

    private func thumbnail(for asset: InvisiCluesAssetFetcher.Manifest.Asset) -> UIImage? {
        if let cached = thumbnailCache[asset.fileName] { return cached }
        let url = fetcher.fileURL(for: game, asset: asset)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let thumb = image.preparingThumbnail(of: CGSize(width: 88, height: 88)) ?? image
        thumbnailCache[asset.fileName] = thumb
        return thumb
    }
}

/// Full-screen zoom for one scanned page.
final class ScannedImageViewController: UIViewController, UIScrollViewDelegate {
    private let fileURL: URL
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(title: String, fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.backgroundColor = .secondarySystemBackground
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(contentsOfFile: fileURL.path)
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        layoutImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImage()
    }

    private func layoutImage() {
        guard let image = imageView.image else { return }
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        let insetX = max(0, (bounds.width - size.width) / 2)
        let insetY = max(0, (bounds.height - size.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

extension UIViewController {
    func presentGameAssets(for game: GameRecord) {
        let list = GameAssetsViewController(game: game)
        let nav = UINavigationController(rootViewController: list)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        modalPresenter().present(nav, animated: true)
    }

    /// Present modals from a controller that is actually on screen (split panes embed children).
    private func modalPresenter() -> UIViewController {
        var candidate: UIViewController = self
        if navigationController != nil { candidate = navigationController! }
        else if let split = splitViewController { candidate = split }
        while let parent = candidate.parent,
              candidate.view.window == nil,
              !(parent is UINavigationController || parent is UISplitViewController) {
            candidate = parent
        }
        if candidate.view.window == nil, let split = candidate.splitViewController {
            candidate = split
        }
        if candidate.view.window == nil, let nav = candidate.navigationController {
            candidate = nav
        }
        var top = candidate
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
