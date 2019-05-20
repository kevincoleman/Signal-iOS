//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit

private class StickerPackActionButton: UIView {

    private let block: () -> Void

    @available(*, unavailable, message:"use other constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    init(actionIconName: String, block: @escaping () -> Void) {
        self.block = block

        super.init(frame: .zero)

        configure(actionIconName: actionIconName)
    }

    private func configure(actionIconName: String) {
        let actionIconSize: CGFloat = 20
        let actionCircleSize: CGFloat = 32
        let actionCircleView = CircleView(diameter: actionCircleSize)
        actionCircleView.backgroundColor = Theme.offBackgroundColor
        let actionIcon = UIImage(named: actionIconName)?.withRenderingMode(.alwaysTemplate)
        let actionIconView = UIImageView(image: actionIcon)
        actionIconView.tintColor = Theme.secondaryColor
        actionCircleView.addSubview(actionIconView)
        actionIconView.autoCenterInSuperview()
        actionIconView.autoSetDimensions(to: CGSize(width: actionIconSize, height: actionIconSize))

        self.addSubview(actionCircleView)
        actionCircleView.autoPinEdgesToSuperviewEdges()

        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                    action: #selector(didTapButton)))
    }

    @objc
    func didTapButton(sender: UIGestureRecognizer) {
        block()
    }
}

// MARK: -

@objc
public class ManageStickersViewController: OWSTableViewController {

    // MARK: - Dependencies

    private var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    private var stickerManager: StickerManager {
        return SSKEnvironment.shared.stickerManager
    }

    // MARK: Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    required public init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    @objc
    public required override init() {
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View Lifecycle

    override public func loadView() {
        super.loadView()

        navigationItem.title = NSLocalizedString("STICKERS_MANAGE_VIEW_TITLE", comment: "Title for the 'manage stickers' view.")

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .stop, target: self, action: #selector(didPressDismiss))

        if FeatureFlags.stickerPackOrdering {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(didPressEditButton))
        }
    }

    override public func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(stickersOrPacksDidChange),
                                               name: StickerManager.StickersOrPacksDidChange,
                                               object: nil)

        updateState()

        StickerManager.refreshContents()
    }

    private var installedStickerPacks = [StickerPack]()
    private var availableBuiltInStickerPacks = [StickerPack]()
    private var availableKnownStickerPacks = [StickerPack]()

    private func updateState() {
        self.databaseStorage.read { (transaction) in
            let allPacks = StickerManager.allStickerPacks(transaction: transaction)
            // Only show packs with installed covers.
            let packsWithCovers = allPacks.filter {
                StickerManager.isStickerInstalled(stickerInfo: $0.coverInfo,
                                                  transaction: transaction)
            }
            // Sort sticker packs by "date saved, descending" so that we feature
            // packs that the user has just learned about.
            let installedStickerPacks = packsWithCovers.filter { $0.isInstalled }
            let availableBuiltInStickerPacks = packsWithCovers.filter { !$0.isInstalled && StickerManager.isDefaultStickerPack($0) }
            let availableKnownStickerPacks = packsWithCovers.filter { !$0.isInstalled && !StickerManager.isDefaultStickerPack($0) }
            self.installedStickerPacks = installedStickerPacks.sorted {
                $0.dateCreated > $1.dateCreated
            }
            let sortAvailablePacks = { (pack0: StickerPack, pack1: StickerPack) -> Bool in
                // Sort "default" packs before "known" packs.
                let isDefault0 = StickerManager.isDefaultStickerPack(pack0)
                let isDefault1 = StickerManager.isDefaultStickerPack(pack1)
                if isDefault0 && !isDefault1 {
                    return true
                }
                if !isDefault0 && isDefault1 {
                    return false
                }
                return pack0.dateCreated > pack1.dateCreated
            }
            self.availableBuiltInStickerPacks = availableBuiltInStickerPacks.sorted(by: sortAvailablePacks)
            self.availableKnownStickerPacks = availableKnownStickerPacks.sorted(by: sortAvailablePacks)
        }

        updateTableContents()
    }

    private func updateTableContents() {
        let contents = OWSTableContents()

        let installedSection = OWSTableSection()
        installedSection.headerTitle = NSLocalizedString("STICKERS_MANAGE_VIEW_INSTALLED_PACKS_SECTION_TITLE", comment: "Title for the 'installed stickers' section of the 'manage stickers' view.")
        if installedStickerPacks.count < 1 {
            installedSection.add(OWSTableItem(customCellBlock: { [weak self] in
                guard let self = self else {
                    return UITableViewCell()
                }
                let text = NSLocalizedString("STICKERS_MANAGE_VIEW_NO_INSTALLED_PACKS", comment: "Label indicating that the user has no installed sticker packs.")
                return self.buildEmptySectionCell(labelText: text)
                },
                                              customRowHeight: UITableView.automaticDimension))
        }
        for stickerPack in installedStickerPacks {
            installedSection.add(OWSTableItem(customCellBlock: { [weak self] in
                guard let self = self else {
                    return UITableViewCell()
                }
                return self.buildTableCell(installedStickerPack: stickerPack)
                },
                                     customRowHeight: UITableView.automaticDimension,
                                     actionBlock: { [weak self] in
                                        self?.show(stickerPack: stickerPack)
            }))
        }
        contents.addSection(installedSection)

        let itemForAvailablePack = { (stickerPack: StickerPack) -> OWSTableItem in
            OWSTableItem(customCellBlock: { [weak self] in
                guard let self = self else {
                    return UITableViewCell()
                }
                return self.buildTableCell(availableStickerPack: stickerPack)
                },
                         customRowHeight: UITableView.automaticDimension,
                         actionBlock: { [weak self] in
                            self?.show(stickerPack: stickerPack)
            })
        }

        if availableBuiltInStickerPacks.count > 0 {
            let section = OWSTableSection()
            section.headerTitle = NSLocalizedString("STICKERS_MANAGE_VIEW_AVAILABLE_BUILT_IN_PACKS_SECTION_TITLE", comment: "Title for the 'available built-in stickers' section of the 'manage stickers' view.")
            for stickerPack in availableBuiltInStickerPacks {
                section.add(itemForAvailablePack(stickerPack))
            }
            contents.addSection(section)
        }

        let knownSection = OWSTableSection()
        knownSection.headerTitle = NSLocalizedString("STICKERS_MANAGE_VIEW_AVAILABLE_KNOWN_PACKS_SECTION_TITLE", comment: "Title for the 'available known stickers' section of the 'manage stickers' view.")
        if availableKnownStickerPacks.count < 1 {
            knownSection.add(OWSTableItem(customCellBlock: { [weak self] in
                guard let self = self else {
                    return UITableViewCell()
                }
                let text = NSLocalizedString("STICKERS_MANAGE_VIEW_NO_KNOWN_PACKS", comment: "Label indicating that the user has no known sticker packs.")
                return self.buildEmptySectionCell(labelText: text)
                },
                                          customRowHeight: UITableView.automaticDimension))
        }
        for stickerPack in availableKnownStickerPacks {
            knownSection.add(itemForAvailablePack(stickerPack))
        }
        contents.addSection(knownSection)

        self.contents = contents
    }

    private func buildTableCell(installedStickerPack stickerPack: StickerPack) -> UITableViewCell {
        var actionIconName = CurrentAppContext().isRTL ? "reply-filled-24" : "reply-filled-reversed-24"
        return buildTableCell(stickerPack: stickerPack,
                              stickerInfo: stickerPack.coverInfo,
                              title: stickerPack.title,
                              authorName: stickerPack.author,
                              actionIconName: actionIconName) { [weak self] in
                                self?.share(stickerPack: stickerPack)
        }
    }

    private func buildTableCell(availableStickerPack stickerPack: StickerPack) -> UITableViewCell {
        let actionIconName = "download-filled-24"
        return buildTableCell(stickerPack: stickerPack,
                              stickerInfo: stickerPack.coverInfo,
                              title: stickerPack.title,
                              authorName: stickerPack.author,
                              actionIconName: actionIconName) { [weak self] in
                                self?.install(stickerPack: stickerPack)
        }
    }

    private func buildTableCell(stickerPack: StickerPack,
                                stickerInfo: StickerInfo,
                                title titleValue: String?,
                                authorName authorNameValue: String?,
                                actionIconName: String?,
                                block: @escaping () -> Void) -> UITableViewCell {
        let cell = OWSTableItem.newCell()

        let iconView = StickerView(stickerInfo: stickerInfo, size: 64)

        let title: String
        if let titleValue = titleValue?.ows_stripped(),
            titleValue.count > 0 {
            title = titleValue
        } else {
            title = NSLocalizedString("STICKERS_PACK_DEFAULT_TITLE", comment: "Default title for sticker packs.")
        }
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.ows_dynamicTypeBody.ows_mediumWeight()
        titleLabel.textColor = Theme.primaryColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let textStack = UIStackView(arrangedSubviews: [
            titleLabel
            ])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.setContentHuggingHorizontalLow()
        textStack.setCompressionResistanceHorizontalLow()

        // TODO: Should we show a default author name?

        let isDefaultStickerPack = StickerManager.isDefaultStickerPack(stickerPack)

        var authorViews = [UIView]()
        if isDefaultStickerPack {
            let builtInPackView = UIImageView()
            builtInPackView.setTemplateImageName("check-circle-filled-16", tintColor: UIColor.ows_signalBrandBlue)
            builtInPackView.setCompressionResistanceHigh()
            builtInPackView.setContentHuggingHigh()
            authorViews.append(builtInPackView)
        }

        if let authorName = authorNameValue?.ows_stripped(),
            authorName.count > 0 {
            let authorLabel = UILabel()
            authorLabel.text = authorName
            authorLabel.font = isDefaultStickerPack ? UIFont.ows_dynamicTypeCaption1.ows_mediumWeight() : UIFont.ows_dynamicTypeCaption1
            authorLabel.textColor = isDefaultStickerPack ? UIColor.ows_signalBlue : Theme.secondaryColor
            authorLabel.lineBreakMode = .byTruncatingTail
            authorViews.append(authorLabel)
        }

        if authorViews.count > 0 {
            let authorStack = UIStackView(arrangedSubviews: authorViews)
            authorStack.axis = .horizontal
            authorStack.alignment = .center
            authorStack.spacing = 4
            textStack.addArrangedSubview(authorStack)
        }

        var subviews: [UIView] = [
            iconView,
            textStack
        ]
        if let actionIconName = actionIconName {
            let actionButton = StickerPackActionButton(actionIconName: actionIconName, block: block)
            subviews.append(actionButton)
        }

        let stack = UIStackView(arrangedSubviews: subviews)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12

        cell.contentView.addSubview(stack)
        stack.ows_autoPinToSuperviewMargins()

        return cell
    }

    private func buildEmptySectionCell(labelText: String) -> UITableViewCell {
        let cell = OWSTableItem.newCell()

        let bubbleView = UIView()
        bubbleView.backgroundColor = Theme.offBackgroundColor
        bubbleView.layer.cornerRadius = 8

        let label = UILabel()
        label.text = labelText
        label.font = UIFont.ows_dynamicTypeCaption1
        label.textColor = Theme.secondaryColor
        label.textAlignment = .center
        bubbleView.addSubview(label)
        label.autoPinHeightToSuperview(withMargin: 24)
        label.autoPinWidthToSuperview(withMargin: 16)

        cell.contentView.addSubview(bubbleView)
        bubbleView.ows_autoPinToSuperviewMargins()

        return cell
    }

    // MARK: Events

    private func show(stickerPack: StickerPack) {
        AssertIsOnMainThread()

        Logger.verbose("")

        let packView = StickerPackViewController(stickerPackInfo: stickerPack.info)
        present(packView, animated: true)
    }

    private func share(stickerPack: StickerPack) {
        AssertIsOnMainThread()

        Logger.verbose("")

        StickerSharingViewController.shareStickerPack(stickerPack.info, from: self)
    }

    private func install(stickerPack: StickerPack) {
        AssertIsOnMainThread()

        Logger.verbose("")

        StickerManager.installStickerPack(stickerPack: stickerPack)
    }

    @objc func stickersOrPacksDidChange() {
        AssertIsOnMainThread()

        Logger.verbose("")

        updateState()
    }

    @objc
    private func didPressEditButton(sender: UIButton) {
        AssertIsOnMainThread()

        Logger.verbose("")

        // TODO:
    }

    @objc
    private func didPressDismiss(sender: UIButton) {
        AssertIsOnMainThread()

        Logger.verbose("")

        dismiss(animated: true)
    }
}