// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import BigInt
import TrustKeystore

struct UnconfirmedTransaction {
    let transferType: TransferType
    let value: BigInt
    let to: Address?
    let data: Data?
    let gasLimit: BigInt?
    let gasPrice: BigInt?
    let nonce: BigInt?
    let v: UInt8?
    let r: String?
    let s: String?
    let expiry: BigUInt?
    let indices: [UInt16]?
}
