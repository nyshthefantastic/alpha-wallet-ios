// Copyright © 2020 Stormbird PTE. LTD.

import UIKit
import Combine
import AlphaWalletFoundation
import AlphaWalletCore

protocol ActivityViewControllerDelegate: AnyObject, RequestSignMessage {
    func reinject(viewController: ActivityViewController)
    func goToToken(viewController: ActivityViewController)
    func speedupTransaction(transactionId: String, server: RPCServer, viewController: ActivityViewController)
    func cancelTransaction(transactionId: String, server: RPCServer, viewController: ActivityViewController)
    func goToTransaction(viewController: ActivityViewController)
    func didPressViewContractWebPage(_ contract: AlphaWallet.Address, server: RPCServer, viewController: ActivityViewController)
}

class ActivityViewController: UIViewController {
    private let roundedBackground = RoundedBackground()
    private let wallet: Wallet
    private let assetDefinitionStore: AssetDefinitionStore
    private let buttonsBar = HorizontalButtonsBar(configuration: .primary(buttons: 1))
    private let tokenImageView = TokenImageView()
    private let stateView = ActivityStateView()
    private let titleLabel = UILabel()
    private let subTitleLabel = UILabel()
    private let timestampLabel = UILabel()
    private let separator = UIView()
    private let bottomFiller = UIView.spacerWidth()
    lazy private var tokenScriptRendererView: TokenInstanceWebView = {
        let webView = TokenInstanceWebView(server: server, wallet: wallet, assetDefinitionStore: assetDefinitionStore)
        webView.isWebViewInteractionEnabled = true
        webView.delegate = self
        webView.isStandalone = true

        return webView
    }()
    private var isFirstLoad = true
    private let defaultErc20ActivityView = DefaultActivityView()
    private let service: ActivitiesServiceType
    private var cancelable = Set<AnyCancellable>()
    private var server: RPCServer {
        viewModel.activity.token.server
    }

    var viewModel: ActivityViewModel
    weak var delegate: ActivityViewControllerDelegate?

    init(wallet: Wallet, assetDefinitionStore: AssetDefinitionStore, viewModel: ActivityViewModel, service: ActivitiesServiceType) {
        self.service = service
        self.wallet = wallet
        self.assetDefinitionStore = assetDefinitionStore
        self.viewModel = viewModel

        super.init(nibName: nil, bundle: nil)

        let viewTransactionButton = UIBarButtonItem(image: R.image.statement(), style: .plain, target: self, action: #selector(showTransaction))
        navigationItem.rightBarButtonItem = viewTransactionButton

        title = viewModel.viewControllerTitle
        view.backgroundColor = viewModel.backgroundColor

        roundedBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(roundedBackground)

        tokenImageView.contentMode = .scaleAspectFit
        let tap = UITapGestureRecognizer(target: self, action: #selector(showContractWebPage))
        tokenImageView.addGestureRecognizer(tap)

        let stackView = [
            .spacer(height: 8),
            timestampLabel,
            .spacer(height: 20),
            tokenImageView,
            .spacer(height: 17),
            titleLabel,
            .spacer(height: 0),
            subTitleLabel,
            .spacer(height: 27),
            separator,
            .spacer(height: 27),
            defaultErc20ActivityView,
            tokenScriptRendererView,
            bottomFiller,
        ].asStackView(axis: .vertical, alignment: .center)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        roundedBackground.addSubview(stackView)
        roundedBackground.addSubview(stateView)

        let footerBar = ButtonsBarBackgroundView(buttonsBar: buttonsBar, separatorHeight: 0)
        roundedBackground.addSubview(footerBar)

        var constraints: [LayoutConstraintsWrapper] = [
            //Setting height for labels to get their heights to be correct. If we want to remove them, make sure to test with both the native Activity view and TokenScript (HTML) Activity views
            timestampLabel.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.heightAnchor.constraint(equalToConstant: 26),
            subTitleLabel.heightAnchor.constraint(equalToConstant: 20),

            tokenImageView.heightAnchor.constraint(equalToConstant: 60),
            tokenImageView.widthAnchor.constraint(equalToConstant: 60),

            separator.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -20),
            separator.heightAnchor.constraint(equalToConstant: DataEntry.Metric.TableView.groupedTableCellSeparatorHeight),
            stackView.anchorsConstraintSafeArea(to: roundedBackground),

            tokenScriptRendererView.widthAnchor.constraint(equalTo: stackView.widthAnchor),

        ] + roundedBackground.createConstraintsWithContainer(view: view)
        + stateView.anchorConstraints(to: tokenImageView, size: .init(width: 24, height: 24), bottomOffset: .zero)
        let footerConstraints: [NSLayoutConstraint] = footerBar.anchorsConstraint(to: view)
        constraints += footerConstraints
        NSLayoutConstraint.activate(constraints)

        configure(viewModel: viewModel)

        service.didUpdateActivityPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in
                guard let strongSelf = self, strongSelf.isForActivity(activity) else { return }

                strongSelf.configure(viewModel: .init(activity: activity))
            }.store(in: &cancelable)
    }

    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.largeTitleDisplayMode = .never
    }

    func configure(viewModel: ActivityViewModel) {
        self.viewModel = viewModel

        let tokenAttributes = viewModel.activity.values.token
        let cardAttributes = viewModel.activity.values.card

        titleLabel.textColor = viewModel.titleTextColor
        titleLabel.font = viewModel.titleFont
        titleLabel.attributedText = viewModel.title

        subTitleLabel.text = viewModel.subTitle
        subTitleLabel.textColor = viewModel.subTitleTextColor
        subTitleLabel.font = viewModel.subTitleFont

        timestampLabel.textColor = viewModel.timestampColor
        timestampLabel.font = viewModel.timestampFont
        timestampLabel.text = viewModel.timestamp

        tokenImageView.subscribable = viewModel.iconImage
        stateView.configure(viewModel: viewModel.activityStateViewViewModel)

        timestampLabel.textAlignment = .center
        titleLabel.textAlignment = .center
        subTitleLabel.textAlignment = .center

        separator.backgroundColor = Configuration.Color.Semantic.tableViewSeparator

        switch viewModel.activity.nativeViewType {
        case .erc20Received, .erc20Sent, .erc20OwnerApproved, .erc20ApprovalObtained, .erc721Sent, .erc721Received, .erc721OwnerApproved, .erc721ApprovalObtained, .nativeCryptoSent, .nativeCryptoReceived:
            defaultErc20ActivityView.isHidden = false
            bottomFiller.isHidden = false
            tokenScriptRendererView.isHidden = true
            defaultErc20ActivityView.configure(viewModel: .init(activity: viewModel.activity))
        case .none:
            defaultErc20ActivityView.isHidden = true
            bottomFiller.isHidden = true
            tokenScriptRendererView.isHidden = false

            tokenScriptRendererView.loadHtml(viewModel.activity.viewHtml)

            tokenScriptRendererView.update(withId: .init(viewModel.activity.id), resolvedTokenAttributeNameValues: tokenAttributes, resolvedCardAttributeNameValues: cardAttributes, isFirstUpdate: isFirstLoad)
            isFirstLoad = false
        }

        buttonsBar.viewController = self
        if Features.default.isAvailable(.isSpeedupAndCancelEnabled) && viewModel.isPendingTransaction {
            buttonsBar.configure(.combined(buttons: 3))
            configureSpeedupButton(buttonsBar.buttons[0])
            configureCancelButton(buttonsBar.buttons[1])
            configureGoToTokenButton(buttonsBar.buttons[2])
        } else {
            buttonsBar.configure(.primary(buttons: 1))
            configureGoToTokenButton(buttonsBar.buttons[0])
        }
    }

    private func configureGoToTokenButton(_ button: BarButton) {
        button.setTitle(R.string.localizable.activityGoToToken(), for: .normal)
        button.addTarget(self, action: #selector(goToToken), for: .touchUpInside)
    }

    private func configureSpeedupButton(_ button: BarButton) {
        button.setTitle(R.string.localizable.activitySpeedup(), for: .normal)
        button.addTarget(self, action: #selector(speedup), for: .touchUpInside)
    }

    private func configureCancelButton(_ button: BarButton) {
        button.setTitle(R.string.localizable.activityCancel(), for: .normal)
        button.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    }

    func isForActivity(_ activity: Activity) -> Bool {
        viewModel.activity.id == activity.id
    }

    @objc private func goToToken() {
        delegate?.goToToken(viewController: self)
    }

    @objc private func speedup() {
        delegate?.speedupTransaction(transactionId: viewModel.activity.transactionId, server: viewModel.activity.server, viewController: self)
    }

    @objc private func cancel() {
        delegate?.cancelTransaction(transactionId: viewModel.activity.transactionId, server: viewModel.activity.server, viewController: self)
    }

    @objc private func showContractWebPage() {
        delegate?.didPressViewContractWebPage(viewModel.activity.token.contractAddress, server: viewModel.activity.token.server, viewController: self)
    }

    @objc private func showTransaction() {
        delegate?.goToTransaction(viewController: self)
    }
}

extension ActivityViewController: TokenInstanceWebViewDelegate {

    func requestSignMessage(message: SignMessageType,
                            server: RPCServer,
                            account: AlphaWallet.Address,
                            source: Analytics.SignMessageRequestSource,
                            requester: RequesterViewModel?) -> AnyPublisher<DappCallbackValue, PromiseError> {

        guard let delegate = delegate else { return .empty() }

        return delegate.requestSignMessage(
            message: message,
            server: server,
            account: account,
            source: source,
            requester: requester)
    }

    func shouldClose(tokenInstanceWebView: TokenInstanceWebView) {
        //no-op
    }

    func reinject(tokenInstanceWebView: TokenInstanceWebView) {
        delegate?.reinject(viewController: self)
    }
}
