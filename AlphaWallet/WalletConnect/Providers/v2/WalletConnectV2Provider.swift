//
//  WalletConnectVvProvider.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 10.11.2021.
//

import Foundation
import Combine
import WalletConnectSwiftV2
import AlphaWalletFoundation
import AlphaWalletLogger

enum ProposalOrServer {
    case server(RPCServer)
    case proposal(WalletConnectSwiftV2.Session.Proposal)
}

final class WalletConnectV2Provider: WalletConnectServer {

    private var currentProposal: WalletConnectSwiftV2.Session.Proposal?
    private var pendingProposals: [WalletConnectSwiftV2.Session.Proposal] = []
    private let storage: WalletConnectV2Storage
    private let config: Config
    //NOTE: Since the connection url doesn't we are getting in `func connect(url: AlphaWallet.WalletConnect.ConnectionUrl) throws` isn't the same of what we got in
    //`SessionProposal` we are not able to manage connection timeout. As well as we are not able to mach topics of urls. connection timeout isn't supported for now for v2.
    private let caip10AccountProvidable: CAIP10AccountProvidable
    private var cancelable = Set<AnyCancellable>()
    private let decoder: WalletConnectRequestDecoder
    private let client: WalletConnectV2Client

    weak var delegate: WalletConnectServerDelegate?
    var sessions: AnyPublisher<[AlphaWallet.WalletConnect.Session], Never> {
        return storage.sessions
            .map { $0.map { AlphaWallet.WalletConnect.Session(multiServerSession: $0) } }
            .eraseToAnyPublisher()
    }

    //NOTE: we support only single account session as WalletConnects request doesn't provide a wallets address to sign transaction or some other method, so we cant figure out wallet address to sign, so for now we use only active wallet session address
    init(caip10AccountProvidable: CAIP10AccountProvidable,
         storage: WalletConnectV2Storage = WalletConnectV2Storage(),
         config: Config = Config(),
         decoder: WalletConnectRequestDecoder = WalletConnectRequestDecoder(),
         client: WalletConnectV2Client) {

        self.client = client
        self.decoder = decoder
        self.storage = storage
        self.config = config
        self.caip10AccountProvidable = caip10AccountProvidable

        caip10AccountProvidable.accounts
            .sink { self.reloadSessions(accounts: $0) }
            .store(in: &cancelable)

        client.sessionProposalPublisher
            .sink { self.didReceive(proposal: $0) }
            .store(in: &cancelable)

        client.sessionRequestPublisher
            .sink { self.didReceive(request: $0) }
            .store(in: &cancelable)

        client.sessionDeletePublisher
            .sink { self.didDelete(topic: $0.0, reason: $0.1) }
            .store(in: &cancelable)

        client.sessionSettlePublisher
            .sink { self.didSettle(session: $0) }
            .store(in: &cancelable)

        client.sessionUpdatePublisher
            .sink { self.didUpgrade(topic: $0.sessionTopic, namespaces: $0.namespaces) }
            .store(in: &cancelable)
    }

    private func reloadSessions(accounts: Set<CAIP10Account>) {
        for each in storage.all() {
            if accounts.isEmpty {
                try? disconnect(each.topicOrUrl)
            } else {
                let filteredAccounts = accounts.filter {
                    guard let server = eip155URLCoder.decodeRPC(from: $0.blockchain.absoluteString) else { return false }
                    return each.servers.contains(server)
                }

                if filteredAccounts.isEmpty {
                    guard let session = try? storage.update(each.topicOrUrl, accounts: accounts) else { continue }
                    client.update(topic: each.topicOrUrl.description, namespaces: session.namespaces)
                } else {
                    guard let session = try? storage.update(each.topicOrUrl, accounts: filteredAccounts) else { continue }
                    client.update(topic: each.topicOrUrl.description, namespaces: session.namespaces)
                }
            }
        }
    }

    func connect(url: AlphaWallet.WalletConnect.ConnectionUrl) throws {
        guard case .v2(let uri) = url, let uri = WalletConnectURI(string: uri.absoluteString) else { return }
        infoLog("[WalletConnect2] Pairing to: \(uri.absoluteString)")

        client.connect(uri: uri)
    }

    func update(_ topicOrUrl: AlphaWallet.WalletConnect.TopicOrUrl, servers: [RPCServer]) throws {
        guard let session = try? storage.update(topicOrUrl, servers: servers) else { return }

        client.update(topic: topicOrUrl.description, namespaces: session.namespaces)
    }

    func session(for topicOrUrl: AlphaWallet.WalletConnect.TopicOrUrl) -> AlphaWallet.WalletConnect.Session? {
        let session = try? storage.session(for: topicOrUrl)
        return session.flatMap { .init(multiServerSession: $0) }
    }

    func disconnect(_ topicOrUrl: AlphaWallet.WalletConnect.TopicOrUrl) throws {
        guard storage.contains(topicOrUrl) else { return }

        storage.remove(for: topicOrUrl)
        client.disconnect(topic: topicOrUrl.description)
    }

    func isConnected(_ topicOrUrl: AlphaWallet.WalletConnect.TopicOrUrl) -> Bool {
        return client.getSessions().contains(where: { $0.topic == topicOrUrl.description })
    }

    func respond(_ response: AlphaWallet.WalletConnect.Response, request: AlphaWallet.WalletConnect.Session.Request) throws {
        guard case .v2(let request) = request else { return }
        switch response {
        case .value(let value):
            guard let value = value else { return }
            client.respond(topic: request.topic, requestId: request.id, response: .response(.init(value.hexEncoded)))
        case .error(let code, let message):
            client.respond(topic: request.topic, requestId: request.id, response: .error(.init(code: code, message: message)))
        }
    }

    private func didReceive(proposal: WalletConnectSwiftV2.Session.Proposal) {
        guard currentProposal == nil else {
            return pendingProposals.append(proposal)
        }

        _didReceive(proposal: proposal, completion: { [weak self] in
            guard let strongSelf = self, let next = strongSelf.pendingProposals.popLast() else { return }
            strongSelf.didReceive(proposal: next)
        })
    }

    private func reject(request: WalletConnectSwiftV2.Request, error: AlphaWallet.WalletConnect.ResponseError) {
        infoLog("[WalletConnect2] WC: Did reject session proposal: \(request) with error: \(error.message)")

        client.respond(topic: request.topic, requestId: request.id, response: .error(.init(code: error.code, message: error.message)))
    }

    private func didReceive(request: WalletConnectSwiftV2.Request) {
        infoLog("[WalletConnect2] WC: Did receive session request")

        //NOTE: guard check to avoid passing unacceptable rpc server,(when requested server is disabled)
        //FIXME: update with ability ask user for enabled disaled server
        guard let server = request.rpcServer, config.enabledServers.contains(server) else {
            return reject(request: request, error: .internalError)
        }

        guard let session = try? storage.session(for: .topic(string: request.topic)) else {
            return reject(request: request, error: .requestRejected)
        }

        let requestV2: AlphaWallet.WalletConnect.Session.Request = .v2(request: request)
        decoder.decode(request: requestV2)
            .map { AlphaWallet.WalletConnect.Action(type: $0) }
            .done { action in
                self.delegate?.server(self, action: action, request: requestV2, session: .init(multiServerSession: session))
            }.catch { error in
                self.delegate?.server(self, didFail: error)
                //NOTE: we need to reject request if there is some arrays
                self.reject(request: request, error: .requestRejected)
            }
    }

    private func didDelete(topic: String, reason: WalletConnectSwiftV2.Reason) {
        infoLog("[WalletConnect2] WC: Did receive session delete")
        storage.remove(for: .topic(string: topic))
    }

    private func didUpgrade(topic: String, namespaces: [String: SessionNamespace]) {
        infoLog("[WalletConnect2] WC: Did receive session upgrate")

        _ = try? storage.update(.topic(string: topic), namespaces: namespaces)
    }

    private func didSettle(session: WalletConnectSwiftV2.Session) {

        infoLog("[WalletConnect2] WC: Did settle session")
        for each in client.getSessions() {
            storage.addOrUpdate(session: each)
        }
    }

    private func _didReceive(proposal: WalletConnectSwiftV2.Session.Proposal, completion: @escaping () -> Void) {
        infoLog("[WalletConnect2] WC: Did receive session proposal")

        func reject(proposal: WalletConnectSwiftV2.Session.Proposal) {
            infoLog("[WalletConnect2] WC: Did reject session proposal: \(proposal)")
            client.reject(proposalId: proposal.id, reason: .userRejectedChains)
            completion()
        }

        guard let delegate = delegate else {
            reject(proposal: proposal)
            return
        }

        do {
            try WalletConnectV2Provider.validateProposalForMixedMainnetOrTestnet(proposal)

            delegate.server(self, shouldConnectFor: .init(proposal: proposal)) { [weak self, caip10AccountProvidable] response in
                guard let strongSelf = self else { return }

                guard response.shouldProceed else {
                    strongSelf.currentProposal = .none
                    reject(proposal: proposal)
                    return
                }

                do {
                    let namespaces = try caip10AccountProvidable.namespaces(proposalOrServer: .proposal(proposal))
                    strongSelf.client.approve(proposalId: proposal.id, namespaces: namespaces)
                    strongSelf.currentProposal = .none

                    completion()
                } catch {
                    delegate.server(strongSelf, didFail: error)
                    //NOTE: for now we dont throw any error, just rejecting connection proposal
                    reject(proposal: proposal)
                }
            }
        } catch {
            delegate.server(self, didFail: error)
            //NOTE: for now we dont throw any error, just rejecting connection proposal
            reject(proposal: proposal)
            return
        }
    }

    //NOTE: Throws an error in case when `sessionProposal` contains mainnets as well as testnets
    private static func validateProposalForMixedMainnetOrTestnet(_ proposal: WalletConnectSwiftV2.Session.Proposal) throws {
        struct MixedMainnetsOrTestnetsError: Error {}
        for namespace in proposal.requiredNamespaces.values {
            let blockchains = Set(namespace.chains.map { $0.absoluteString })
            let servers = RPCServer.decodeEip155Array(values: blockchains)
            let allAreTestnets = servers.allSatisfy { $0.isTestnet }
            if allAreTestnets {
                //no-op
            } else {
                let allAreMainnets = servers.allSatisfy { !$0.isTestnet }
                if allAreMainnets {
                    //no-op
                } else {
                    throw MixedMainnetsOrTestnetsError()
                }
            }
        }
    }
}

fileprivate extension AlphaWallet.WalletConnect.Proposal {

    init(proposal: WalletConnectSwiftV2.Session.Proposal) {
        name = proposal.proposer.name
        dappUrl = URL(string: proposal.proposer.url)!
        description = proposal.proposer.description
        iconUrl = proposal.proposer.icons.compactMap({ URL(string: $0) }).first
        servers = proposal.requiredNamespaces.values.flatMap { RPCServer.decodeEip155Array(values: Set($0.chains.map { $0.absoluteString }) ) }
        methods = Array(proposal.requiredNamespaces.values.flatMap { $0.methods })
        serverEditing = .notSupporting
    }
}
