import UIKit
import UniformTypeIdentifiers

/// The list of stories.
final class LibraryViewController: UIViewController, UICollectionViewDelegate, UIDocumentPickerDelegate, UISearchResultsUpdating {
    var onOpen: ((GameRecord) -> Void)?
    var onSettings: (() -> Void)?
    /// Used in the side pane, where the title and buttons are the pane's.
    var embedded = false

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let emptyView = UIStackView()
    private var query = ""
    private let search = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = .systemGroupedBackground

        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self = self, let id = self.dataSource.itemIdentifier(for: indexPath), let game = Library.shared.game(withID: id) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                self.confirmRemove(game); done(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
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

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let game = Library.shared.game(withID: id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = game.title
            var details: [String] = []
            if let author = game.author { details.append(author) }
            details.append(game.format.displayName)
            if let played = game.lastPlayed {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                details.append("played " + formatter.localizedString(for: played, relativeTo: Date()))
            }
            content.secondaryText = details.joined(separator: " · ")
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .headline)
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = self?.thumbnail(for: game)
            content.imageProperties.maximumSize = CGSize(width: 44, height: 56)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 56)
            content.imageProperties.cornerRadius = 6
            cell.contentConfiguration = content
            cell.accessories = AutosaveStore.hasAutosave(for: game, terp: game.format.terpName ?? "")
                ? [.label(text: "Resume", options: .init(reservedLayoutWidth: .actual, font: .preferredFont(forTextStyle: .caption1)))]
                : []
            cell.accessibilityHint = "Opens the story"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }

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
            let thumb = image.preparingThumbnail(of: CGSize(width: 120, height: 160)) ?? image
            thumbnailCache[game.id] = thumb
            return thumb
        }
        // A simple stand-in: the first letter on a coloured tile.
        let size = CGSize(width: 44, height: 56)
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

    @objc private func reload() {
        let games = Library.shared.games
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.author ?? "").localizedCaseInsensitiveContains(query) }
            .sorted { ($0.lastPlayed ?? $0.dateAdded) > ($1.lastPlayed ?? $1.dateAdded) }
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
        guard let id = dataSource.itemIdentifier(for: indexPath), let game = Library.shared.game(withID: id) else { return }
        onOpen?(game)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let game = Library.shared.game(withID: id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions: [UIMenuElement] = [
                UIAction(title: "Play", image: UIImage(systemName: "play")) { _ in self.onOpen?(game) },
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in self.rename(game) },
            ]
            if let terp = game.format.terpName, AutosaveStore.hasAutosave(for: game, terp: terp) {
                actions.append(UIAction(title: "Start Over", image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                    AutosaveStore.discard(for: game, terp: terp)
                    self.reload()
                    self.onOpen?(game)
                })
            }
            actions.append(UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.confirmRemove(game) })
            return UIMenu(children: actions)
        }
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
