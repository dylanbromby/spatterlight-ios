import UIKit
import UniformTypeIdentifiers

/// The list of stories.
final class LibraryViewController: UIViewController, UICollectionViewDelegate, UIDocumentPickerDelegate, UISearchResultsUpdating, UIGestureRecognizerDelegate {
    var onOpen: ((GameRecord) -> Void)?
    var onSettings: (() -> Void)?
    /// Used in the side pane, where the title and buttons are the pane's.
    var embedded = false

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let emptyView = UIStackView()
    private var query = ""
    private var expandedDescriptions = Set<String>()
    private let search = UISearchController(searchResultsController: nil)
    private var reorderPress: UILongPressGestureRecognizer!
    private var reorderSourceID: String?
    private var reorderLastDestinationIndex: Int?
    private var isActivelyReordering = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = .systemGroupedBackground

        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self = self, let id = self.dataSource.itemIdentifier(for: indexPath), let game = Library.shared.game(withID: id) else { return nil }
            let rename = UIContextualAction(style: .normal, title: "Rename") { _, _, done in
                self.rename(game); done(true)
            }
            rename.backgroundColor = .systemBlue
            rename.image = UIImage(systemName: "pencil")
            return UISwipeActionsConfiguration(actions: [rename])
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self = self, let id = self.dataSource.itemIdentifier(for: indexPath), let game = Library.shared.game(withID: id) else { return nil }
            var actions: [UIContextualAction] = []
            let assets = UIContextualAction(style: .normal, title: "Assets") { _, _, done in
                self.presentGameAssets(for: game)
                done(true)
            }
            assets.backgroundColor = .systemIndigo
            assets.image = UIImage(systemName: "archivebox")
            actions.insert(assets, at: 0)
            if let terp = game.format.terpName, AutosaveStore.hasAutosave(for: game, terp: terp) {
                let restart = UIContextualAction(style: .normal, title: "Start Over") { _, _, done in
                    AutosaveStore.discard(for: game, terp: terp)
                    self.reload()
                    self.onOpen?(game)
                    done(true)
                }
                restart.backgroundColor = .systemOrange
                restart.image = UIImage(systemName: "arrow.counterclockwise")
                actions.append(restart)
            }
            let delete = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                self.confirmRemove(game); done(true)
            }
            delete.image = UIImage(systemName: "trash")
            actions.append(delete)
            return UISwipeActionsConfiguration(actions: actions)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let registration = UICollectionView.CellRegistration<StoryCell, String> { [weak self] cell, _, id in
            guard let game = Library.shared.game(withID: id) else { return }
            var meta: [String] = []
            if let author = game.author { meta.append(author) }
            meta.append(game.format.displayName)
            if let played = game.lastPlayed {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                meta.append("played " + formatter.localizedString(for: played, relativeTo: Date()))
            }
            let resumable = AutosaveStore.hasAutosave(for: game, terp: game.format.terpName ?? "")
            let expanded = self?.expandedDescriptions.contains(id) ?? false
            cell.configure(
                title: game.title,
                meta: meta.joined(separator: " · "),
                summary: IFDBCoverFetcher.cleanSummary(game.summary),
                expanded: expanded,
                resume: resumable,
                image: self?.thumbnail(for: game)
            ) { [weak self] in
                self?.toggleDescription(for: id)
            }
            cell.accessibilityHint = self?.query.isEmpty == true
                ? "Opens the story. Touch and hold, then drag to reorder."
                : "Opens the story"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        reorderPress = UILongPressGestureRecognizer(target: self, action: #selector(handleReorderPress(_:)))
        reorderPress.minimumPressDuration = 0.45
        reorderPress.delegate = self
        collectionView.addGestureRecognizer(reorderPress)

        if !embedded {
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(addTapped)),
            ]
            navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settingsTapped))
            navigationItem.leftBarButtonItem?.accessibilityLabel = "Settings"
            navigationItem.rightBarButtonItems?.first?.accessibilityLabel = "Add story"
            search.searchResultsUpdater = self
            search.obscuresBackgroundDuringPresentation = false
            navigationItem.searchController = search
            navigationItem.hidesSearchBarWhenScrolling = true
        }

        buildEmptyView()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .libraryDidChange, object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func buildEmptyView() {
        emptyView.axis = .vertical
        emptyView.alignment = .center
        emptyView.spacing = 12
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "books.vertical", withConfiguration: UIImage.SymbolConfiguration(pointSize: 48)))
        icon.tintColor = .tertiaryLabel
        let title = UILabel()
        title.text = "No stories yet"
        title.font = UIFont.preferredFont(forTextStyle: .title2)
        let body = UILabel()
        body.text = "Add interactive fiction files (Z-code or Glulx: .z5, .zblorb, .ulx, .gblorb) from Files, AirDrop, or a download."
        body.font = UIFont.preferredFont(forTextStyle: .body)
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0
        var config = UIButton.Configuration.filled()
        config.title = "Add a Story"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 6
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.addTapped() })
        [icon, title, body, button].forEach { emptyView.addArrangedSubview($0) }
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor, constant: 24),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor, constant: -24),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private var thumbnailCache: [String: UIImage] = [:]

    private func thumbnail(for game: GameRecord) -> UIImage? {
        if let image = thumbnailCache[game.id] { return image }
        if game.hasCover, let image = UIImage(contentsOfFile: game.coverURL.path) {
            let thumb = image.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? image
            thumbnailCache[game.id] = thumb
            return thumb
        }
        // A simple stand-in: the first letter on a coloured tile.
        let size = CGSize(width: 56, height: 56)
        let hue = CGFloat(abs(game.id.hashValue % 360)) / 360
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let letter = String(game.title.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: UIColor.white]
            let textSize = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        thumbnailCache[game.id] = image
        return image
    }

    private func toggleDescription(for id: String) {
        if expandedDescriptions.contains(id) {
            expandedDescriptions.remove(id)
        } else {
            expandedDescriptions.insert(id)
        }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func handleReorderPress(_ gesture: UILongPressGestureRecognizer) {
        guard query.isEmpty else { return }
        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: location),
                  let id = dataSource.itemIdentifier(for: indexPath) else { return }
            reorderSourceID = id
            reorderLastDestinationIndex = indexPath.item
            isActivelyReordering = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            collectionView.cellForItem(at: indexPath)?.alpha = 0.55
        case .changed:
            guard let sourceID = reorderSourceID else { return }
            guard let destPath = destinationIndexPath(forDragAt: location) else { return }
            if destPath.item == reorderLastDestinationIndex { return }
            reorderLastDestinationIndex = destPath.item
            applyReorder(sourceID: sourceID, to: destPath.item)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .ended, .cancelled, .failed:
            finishReorderGesture()
        default:
            break
        }
    }

    private func destinationIndexPath(forDragAt location: CGPoint) -> IndexPath? {
        if let path = collectionView.indexPathForItem(at: location) { return path }
        let items = dataSource.snapshot().itemIdentifiers(inSection: 0)
        guard !items.isEmpty else { return nil }
        for item in 0..<items.count {
            let path = IndexPath(item: item, section: 0)
            if let attrs = collectionView.layoutAttributesForItem(at: path), location.y < attrs.frame.midY {
                return path
            }
        }
        return IndexPath(item: items.count - 1, section: 0)
    }

    private func applyReorder(sourceID: String, to destinationIndex: Int) {
        var snapshot = dataSource.snapshot()
        var ids = snapshot.itemIdentifiers(inSection: 0)
        guard let sourceIndex = ids.firstIndex(of: sourceID), sourceIndex != destinationIndex else { return }
        ids.remove(at: sourceIndex)
        var insertIndex = destinationIndex
        if destinationIndex > sourceIndex { insertIndex -= 1 }
        insertIndex = min(max(insertIndex, 0), ids.count)
        ids.insert(sourceID, at: insertIndex)
        snapshot.deleteItems(snapshot.itemIdentifiers(inSection: 0))
        snapshot.appendItems(ids, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func finishReorderGesture() {
        guard isActivelyReordering else { return }
        isActivelyReordering = false
        collectionView.visibleCells.forEach { $0.alpha = 1 }
        if query.isEmpty {
            Library.shared.applyDisplayOrder(dataSource.snapshot().itemIdentifiers(inSection: 0))
        }
        reorderSourceID = nil
        reorderLastDestinationIndex = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === reorderPress, query.isEmpty else { return true }
        let point = gestureRecognizer.location(in: collectionView)
        return collectionView.indexPathForItem(at: point) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === reorderPress && other === collectionView.panGestureRecognizer
    }

    @objc private func reload() {
        thumbnailCache.removeAll()
        let games = Library.shared.gamesForList(matching: query)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(games.map(\.id))
        snapshot.reconfigureItems(games.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        emptyView.isHidden = !Library.shared.games.isEmpty
        collectionView.isHidden = Library.shared.games.isEmpty
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        reload()
    }

    // MARK: Actions

    @objc private func addTapped() {
        let types: [UTType] = [.data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func settingsTapped() { onSettings?() }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importGames(urls)
    }

    func importGames(_ urls: [URL]) {
        var errors: [String] = []
        var last: GameRecord?
        for url in urls {
            do { last = try Library.shared.importGame(from: url) }
            catch { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty {
            let alert = UIAlertController(title: "Could not add", message: errors.joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } else if urls.count == 1, let game = last {
            onOpen?(game)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !isActivelyReordering else { return }
        guard let id = dataSource.itemIdentifier(for: indexPath), let game = Library.shared.game(withID: id) else { return }
        onOpen?(game)
    }

    private func rename(_ game: GameRecord) {
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = game.title; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { _ in
            if let text = alert.textFields?.first?.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Library.shared.rename(game, to: text)
            }
        })
        present(alert, animated: true)
    }

    private func confirmRemove(_ game: GameRecord) {
        let alert = UIAlertController(title: "Remove “\(game.title)”?", message: "The story file and its autosave are deleted. Saved games stay in Files under Spatterlight.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in Library.shared.remove(game) })
        present(alert, animated: true)
    }
}


/// One story in the list: cover and title on the first row; optional description expands on demand.
final class StoryCell: UICollectionViewListCell {
    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let summaryLabel = UILabel()
    private let descriptionButton = UIButton(type: .system)
    private var onToggleDescription: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 10
        coverView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 3
        metaLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 2
        summaryLabel.font = UIFont.preferredFont(forTextStyle: .body)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = .label
        summaryLabel.numberOfLines = 0
        descriptionButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        descriptionButton.contentHorizontalAlignment = .leading
        descriptionButton.addAction(UIAction { [weak self] _ in self?.onToggleDescription?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [coverView, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        coverView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        coverView.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let column = UIStackView(arrangedSubviews: [header, metaLabel, descriptionButton, summaryLabel])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, meta: String, summary: String?, expanded: Bool, resume: Bool, image: UIImage?,
                   onToggleDescription: (() -> Void)?) {
        titleLabel.text = title
        coverView.image = image
        self.onToggleDescription = onToggleDescription

        let metaText = NSMutableAttributedString()
        if resume {
            metaText.append(NSAttributedString(string: "Resume", attributes: [
                .font: UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold),
                .foregroundColor: tintColor ?? UIColor.systemBlue,
            ]))
            if !meta.isEmpty { metaText.append(NSAttributedString(string: " · ")) }
        }
        if !meta.isEmpty { metaText.append(NSAttributedString(string: meta)) }
        metaLabel.attributedText = metaText
        metaLabel.isHidden = metaText.length == 0

        let hasSummary = !(summary ?? "").isEmpty
        descriptionButton.isHidden = !hasSummary
        summaryLabel.isHidden = !hasSummary || !expanded
        if hasSummary {
            summaryLabel.text = summary
            var config = UIButton.Configuration.plain()
            config.title = expanded ? "Less" : "More"
            config.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            config.imagePadding = 2
            config.imagePlacement = .trailing
            config.baseForegroundColor = .secondaryLabel
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = UIFont.systemFont(ofSize: 13, weight: .medium)
                return out
            }
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            descriptionButton.configuration = config
        }

        accessibilityLabel = title
        var spoken = meta
        if resume { spoken = "Resume. " + spoken }
        if expanded, let summary { spoken += ". " + summary }
        accessibilityValue = spoken
        accessories = []
    }
}
