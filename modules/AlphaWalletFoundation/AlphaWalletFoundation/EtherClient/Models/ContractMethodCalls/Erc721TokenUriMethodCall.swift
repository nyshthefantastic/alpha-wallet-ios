//
//  Erc721TokenUriMethodCall.swift
//  AlphaWalletFoundation
//
//  Created by Vladyslav Shepitko on 17.01.2023.
//

import Foundation
import BigInt

public struct Base64Decoder {
    public typealias Response = (mimeType: String?, encoding: Encoding?, data: Data)

    public enum Encoding {
        case base64
        case other(String)

        init(string: String) {
            switch string {
            case "base64":
                self = .base64
            default:
                self = .other(string)
            }
        }
    }

    public init() {}

    /// for strings like: "data:application/json;base64,ewogICJuYW1lIjogIk5GVFdvcmxkcyBBdmF0YXIgTWludCBQYXNzIiwKICAiZGVzY3JpcHRpb24iOiAiQnkgW1l1Z2FMYWJzXShodHRwczovL29wZW5zZWEuaW8vWXVnYUxhYnMpXHJcblxyXG5QYXNzIHRvIHRha2UgcGFydCBpbiBORlRXb3JsZHMgQXZhdGFyIE1pbnQuXHJcblxyXG5UaGVzZSBhdmF0YXJzIHdpbGwgY292ZXIgdGhlIGludGVybmV0IGZvciBodW5kcmVkcyBvZiB5ZWFycy5cclxuXHJcbk5vdyBpcyB5b3VyIGNoYW5jZSB0byBnZXQgYXZhdGFyIGZvciBjZW50dXJ5IiwKICAiaW1hZ2UiOiAiaHR0cHM6Ly9pcGZzLmlvL2lwZnMvUW1YOTVvOG5Wd1I3a0djclRpeVU4b1N0ZGJudnFQTlRXWVA5UWQ4NXlOWXF4UCIsCiAgImV4dGVybmFsX3VybCI6ICJodHRwczovL25mdHdvcmxkYXZhdGFyLnh5eiIKfQ=="
    public func decode(string: String) -> Response? {
        let predicate = NSPredicate(format: "SELF MATCHES %@", "^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$")

        if let index = string.firstIndex(where: { $0 == "," }) {
            guard index < string.endIndex else { return nil }

            let startBase64Index = string.index(index, offsetBy: 1)
            let supposeBase64 = String(string[startBase64Index ..< string.endIndex])
            let isBase64 = predicate.evaluate(with: supposeBase64)
            if isBase64 {
                guard let data = Data(base64Encoded: supposeBase64) else { return nil }
                //data:application/json;base64,
                let dataEncodingType = String(string[string.startIndex ..< index])
                let components = dataEncodingType.components(separatedBy: ";")

                guard components.count == 2 else {
                    return (nil, nil, data)
                }
                let mimeType = components[0].components(separatedBy: ":")[1]
                let encoding = Encoding(string: components[1])

                return (mimeType, encoding, data)
            } else {
                return nil
            }
        } else {
            let isBase64 = predicate.evaluate(with: string)
            if isBase64, let data = Data(base64Encoded: string) {
                return (nil, nil, data)
            }
        }

        return nil
    }
}

enum TokenUriData {
    case uri(URL)
    case string(String)
    case json(JSON)
    case data(Data)
}

import SwiftyJSON

struct TokenUriDecoder {
    var base64Decoder: Base64Decoder = Base64Decoder()
    let tokenId: String

    private enum DecoderError: Error {
        case decodeFailure
    }

    func decode(from resultObject: Any) throws -> TokenUriData {
        guard let dictionary = resultObject as? [String: AnyObject] else {
            throw CastError(actualValue: resultObject, expectedType: [String: AnyObject].self)
        }

        guard let string = dictionary["0"] as? String else {
            throw CastError(actualValue: resultObject, expectedType: String.self)
        }

        if let data = base64Decoder.decode(string: string) {
            guard let mimeType = data.mimeType else { return .data(data.data) }

            switch mimeType {
            case "application/json":
                guard let json = try? JSON(data: data.data) else { throw DecoderError.decodeFailure }
                return .json(json)
            case "text/plain", "svg+xml":
                guard let string = String(data: data.data, encoding: .utf8) else { throw DecoderError.decodeFailure }
                return .string(string)
            default:
                //NOTE: treat default as string representation, might be needed to tweak
                guard let string = String(data: data.data, encoding: .utf8) else { throw DecoderError.decodeFailure }
                return .string(string)
            }
        } else if let url = URL(string: string.stringWithTokenIdSubstituted(tokenId)) {
            return .uri(url)
        } else {
            throw CastError(actualValue: string, expectedType: TokenUriData.self)
        }
    }
}

struct Erc721TokenUriMethodCall: ContractMethodCall {
    typealias Response = TokenUriData

    private let function = GetTokenUri()
    private let tokenId: String
    private let decoder: TokenUriDecoder

    let contract: AlphaWallet.Address
    var name: String { function.name }
    var abi: String { function.abi }
    var parameters: [AnyObject] { [tokenId] as [AnyObject] }

    init(contract: AlphaWallet.Address, tokenId: String) {
        self.contract = contract
        self.tokenId = tokenId
        self.decoder = TokenUriDecoder(tokenId: tokenId)
    }

    func response(from resultObject: Any) throws -> TokenUriData {
        return try decoder.decode(from: resultObject)
    }
}

struct Erc721UriMethodCall: ContractMethodCall {
    typealias Response = TokenUriData

    private let function = GetUri()
    private let tokenId: String
    private let decoder: TokenUriDecoder

    let contract: AlphaWallet.Address
    var name: String { function.name }
    var abi: String { function.abi }
    var parameters: [AnyObject] { [tokenId] as [AnyObject] }

    init(contract: AlphaWallet.Address, tokenId: String) {
        self.contract = contract
        self.tokenId = tokenId
        self.decoder = TokenUriDecoder(tokenId: tokenId)
    }

    func response(from resultObject: Any) throws -> TokenUriData {
        return try decoder.decode(from: resultObject)
    }
}

extension String {
    fileprivate func stringWithTokenIdSubstituted(_ tokenId: String) -> String {
        //According to https://eips.ethereum.org/EIPS/eip-1155
        //The string format of the substituted hexadecimal ID MUST be lowercase alphanumeric: [0-9a-f] with no 0x prefix.
        //The string format of the substituted hexadecimal ID MUST be leading zero padded to 64 hex characters length if necessary.
        if let tokenId = BigInt(tokenId) {
            let hex = String(tokenId, radix: 16).padding(toLength: 64, withPad: "0", startingAt: 0)
            return self.replacingOccurrences(of: "{id}", with: hex)
        } else {
            return self
        }
    }
}
