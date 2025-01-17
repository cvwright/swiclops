//
//  RegistrationToken.swift
//  
//
//  Created by Charles Wright on 3/28/22.
//

import Vapor
import Fluent

final class RegistrationToken: Model {
    
    static let schema = "registration_tokens"
    
    @ID(custom: "token", generatedBy: .user)
    var id: String?
    
    @Field(key: "created_by")
    var createdBy: String
    
    @Field(key: "slots")
    var slots: Int
    
    @Timestamp(key: "created_at", on: .create)
    var createAt: Date?
    
    @Field(key: "expires_at")
    var expiresAt: Date?
    
    var isExpired: Bool {
        if let expiration = self.expiresAt {
            return expiration < Date()
        }
        
        return false
    }
    
    init() {
        
    }
    
    init(id: String? = nil, createdBy: String, slots: Int, expiresAt: Date? = nil) {
        self.id = id ?? String(format: "%04x-%04x-%04x-%04x",
                               UInt16.random(),
                               UInt16.random(),
                               UInt16.random(),
                               UInt16.random())
        self.createdBy = createdBy
        self.slots = slots
        self.createAt = Date()
        self.expiresAt = expiresAt
    }
}
