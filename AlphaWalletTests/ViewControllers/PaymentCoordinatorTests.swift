// Copyright SIX DAY LLC. All rights reserved.

import XCTest
@testable import AlphaWallet
import Combine
import AlphaWalletFoundation

extension TokensFilter {
    static func make() -> TokensFilter {
        let actionsService = TokenActionsService()
        return TokensFilter(tokenActionsService: actionsService, tokenGroupIdentifier: FakeTokenGroupIdentifier())
    }
}

extension RealmStore {
    static func fake(for wallet: Wallet) -> RealmStore {
        RealmStore(realm: fakeRealm(wallet: wallet), name: RealmStore.threadName(for: wallet))
    }
}
extension CurrencyService {
    static func make() -> CurrencyService {
        return .init(storage: Config())
    }
}

extension WalletDataProcessingPipeline {
    static func make(wallet: Wallet = .make(), server: RPCServer = .main) -> AppCoordinator.WalletDependencies {
        let fas = FakeAnalyticsService()

        let tokensDataStore = FakeTokensDataStore(account: wallet, servers: [server])
        let sessionsProvider = FakeSessionsProvider(
            config: .make(),
            analytics: FakeAnalyticsService(),
            blockchainsProvider: .make(servers: [server]),
            tokensDataStore: tokensDataStore,
            assetDefinitionStore: .make(),
            reachability: FakeReachabilityManager(true),
            wallet: wallet)

        sessionsProvider.start()

        let eventsActivityDataStore: EventsActivityDataStoreProtocol = EventsActivityDataStore(store: .fake(for: wallet))

        let eventsDataStore = FakeEventsDataStore()
        let transactionsDataStore = FakeTransactionsStorage()
        let nftProvider = FakeNftProvider()
        let coinTickersFetcher = CoinTickersFetcherImpl.make()
        let currencyService: CurrencyService = .make()

        let tokensService = AlphaWalletTokensService(
            sessionsProvider: sessionsProvider,
            tokensDataStore: tokensDataStore,
            analytics: fas,
            transactionsStorage: transactionsDataStore,
            nftProvider: nftProvider,
            assetDefinitionStore: .make(),
            networkService: FakeNetworkService())

        let pipeline: TokensProcessingPipeline = WalletDataProcessingPipeline(
            wallet: wallet,
            tokensService: tokensService,
            coinTickersFetcher: coinTickersFetcher,
            assetDefinitionStore: .make(),
            eventsDataStore: eventsDataStore,
            currencyService: currencyService)

        let fetcher = WalletBalanceFetcher(wallet: wallet, tokensService: pipeline)

        let activitiesPipeLine = ActivitiesPipeLine(
            config: .make(),
            wallet: wallet,
            assetDefinitionStore: .make(),
            transactionDataStore: transactionsDataStore,
            tokensService: tokensService,
            sessionsProvider: sessionsProvider,
            eventsActivityDataStore: eventsActivityDataStore,
            eventsDataStore: eventsDataStore)

        let dep = AppCoordinator.WalletDependencies(
            activitiesPipeLine: activitiesPipeLine,
            transactionsDataStore: transactionsDataStore,
            tokensDataStore: tokensDataStore,
            tokensService: tokensService,
            pipeline: pipeline,
            fetcher: fetcher,
            sessionsProvider: sessionsProvider,
            eventsDataStore: eventsDataStore,
            currencyService: currencyService)
        
        dep.sessionsProvider.start()
        dep.fetcher.start()
        dep.pipeline.start()

        return dep
    }
}

class PaymentCoordinatorTests: XCTestCase {

    func testSendFlow() {
        let address: AlphaWallet.Address = .make()

        let wallet: Wallet = .make()
        let server: RPCServer = .main
        let dep = WalletDataProcessingPipeline.make(wallet: wallet, server: server)

        let coordinator = PaymentCoordinator(
            navigationController: FakeNavigationController(),
            flow: .send(type: .transaction(.nativeCryptocurrency(Token(), destination: .init(address: address), amount: .notSet))),
            server: .main,
            sessionsProvider: dep.sessionsProvider,
            keystore: FakeEtherKeystore(),
            assetDefinitionStore: .make(),
            analytics: FakeAnalyticsService(),
            tokenCollection: dep.pipeline,
            domainResolutionService: FakeDomainResolutionService(),
            tokenSwapper: TokenSwapper.make(),
            tokensFilter: .make(),
            networkService: FakeNetworkService(),
            transactionDataStore: FakeTransactionsStorage(wallet: wallet))
        coordinator.start()

        XCTAssertEqual(1, coordinator.coordinators.count)
        XCTAssertTrue(coordinator.coordinators.first is SendCoordinator)
    }

    func testRequestFlow() {
        let wallet: Wallet = .make()
        let server: RPCServer = .main
        let dep = WalletDataProcessingPipeline.make(wallet: wallet, server: server)

        let coordinator = PaymentCoordinator(
            navigationController: FakeNavigationController(),
            flow: .request,
            server: .main,
            sessionsProvider: dep.sessionsProvider,
            keystore: FakeEtherKeystore(),
            assetDefinitionStore: .make(),
            analytics: FakeAnalyticsService(),
            tokenCollection: dep.pipeline,
            domainResolutionService: FakeDomainResolutionService(),
            tokenSwapper: TokenSwapper.make(),
            tokensFilter: .make(),
            networkService: FakeNetworkService(),
            transactionDataStore: FakeTransactionsStorage(wallet: wallet))

        coordinator.start()

        XCTAssertEqual(1, coordinator.coordinators.count)
        XCTAssertTrue(coordinator.coordinators.first is RequestCoordinator)
    }
}
