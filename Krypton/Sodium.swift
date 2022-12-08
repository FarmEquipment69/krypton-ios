//
//  Sodium.swift
//  Krypton
//
//  Created by Kevin King on 9/20/16.
//  Copyright © 2016 KryptCo, Inc. All rights reserved.
//

import Foundation
import Sodium

typealias SodiumSignPublicKey = Sign.PublicKey
typealias SodiumSignSecretKey = Sign.SecretKey
typealias SodiumSignKeyPair = Sign.KeyPair

typealias SodiumBoxPublicKey = Box.PublicKey
typealias SodiumBoxKeyPair = Box.KeyPair

typealias SodiumSecretBoxKey = SecretBox.Key

class KRSodium {
    class func instance() -> Sodium {
        return Sodium()
    }
}

extension Array where Element == UInt8 {
    var data:Data {
        return Data(bytes: self)
    }
    
    var SHA256:Data {
        return self.data.SHA256
    }
    
    func toBase64() -> String {
        return self.data.toBase64()
    }
}
