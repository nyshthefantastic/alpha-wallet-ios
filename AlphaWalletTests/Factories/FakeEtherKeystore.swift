// Copyright © 2019 Stormbird PTE. LTD.

import Foundation
@testable import AlphaWallet
import AlphaWalletFoundation

final class FakeEtherKeystore: EtherKeystore {
    convenience init(wallets: [Wallet] = [], recentlyUsedWallet: Wallet? = nil) {
        let walletAddressesStore = fakeWalletAddressStore(wallets: wallets, recentlyUsedWallet: recentlyUsedWallet)
        self.init(keychain: KeychainStorage.make(), walletAddressesStore: walletAddressesStore, analytics: FakeAnalyticsService(), legacyFileBasedKeystore: .make())
        self.recentlyUsedWallet = recentlyUsedWallet
    }

    convenience init(walletAddressesStore: WalletAddressesStore) {
        self.init(keychain: KeychainStorage.make(), walletAddressesStore: walletAddressesStore, analytics: FakeAnalyticsService(), legacyFileBasedKeystore: .make())
        self.recentlyUsedWallet = recentlyUsedWallet
    }
}

extension LegacyFileBasedKeystore {
    static func make() -> LegacyFileBasedKeystore {
        (try! LegacyFileBasedKeystore(securedStorage: KeychainStorage.make()))
    }
}
