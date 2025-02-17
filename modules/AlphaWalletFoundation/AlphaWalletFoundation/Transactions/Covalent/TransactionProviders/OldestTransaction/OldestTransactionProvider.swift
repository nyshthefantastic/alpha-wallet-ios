//
//  OldestTransactionProvider.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 01.04.2022.
//

import Foundation
import Combine
import AlphaWalletCore

final class OldestTransactionProvider: NSObject {
    private let session: WalletSession
    private lazy var transactionsTracker: TransactionsTracker = TransactionsTracker(sessionID: session.sessionID)
    private let scheduler: SchedulerProtocol
    private let ercTokenDetector: ErcTokenDetector
    private let queue = DispatchQueue(label: "com.OldestTransactionProvider.updateQueue")
    private let transactionDataStore: TransactionDataStore

    init(session: WalletSession, scheduler: SchedulerProtocol, ercTokenDetector: ErcTokenDetector, transactionDataStore: TransactionDataStore) {
        self.session = session
        self.scheduler = scheduler
        self.ercTokenDetector = ercTokenDetector
        self.transactionDataStore = transactionDataStore
        super.init()
    }

    func startScheduler() {
        queue.async { [scheduler] in
            //NOTE: we don't check for `fetchingState is .done` to allow the app make a call on app launch because previously fetcher might be stopped because of error appeared, what is not realy correct.
            scheduler.start()
        }
    }

    func resumeScheduler() {
        queue.async { [scheduler, transactionsTracker] in
            //NOTE: Don't resume timer if what is `.done`
            guard transactionsTracker.fetchingState != .done else { return }
            scheduler.resume()
        }
    }

    func cancelScheduler() {
        queue.async { [scheduler] in
            scheduler.cancel()
        }
    }

    deinit {
        scheduler.cancel()
    }

    private func didReceiveError(error: PromiseError) {
        transactionsTracker.fetchingState = .failed
    }

    private func didReceiveValue(transactions: [TransactionInstance]) {
        if transactions.isEmpty {
            transactionsTracker.fetchingState = .done
            scheduler.cancel()
        } else {
            transactionDataStore.addOrUpdate(transactions: transactions)
            ercTokenDetector.detect(from: transactions)
        }
    }
}

extension OldestTransactionProvider: OldestTransactionSchedulerProviderDelegate {
    func didReceiveResponse(_ response: Swift.Result<[TransactionInstance], PromiseError>, in provider: OldestTransactionSchedulerProvider) {
        switch response {
        case .success(let transactions):
            didReceiveValue(transactions: transactions)
        case .failure(let error):
            didReceiveError(error: error)
        }
    }
}
