//
//  Request+MatrixUIA.swift
//  
//
//  Created by Charles Wright on 3/24/22.
//

import Vapor
import AnyCodable

extension Request {
    
    struct MatrixUIAKey: StorageKey {
        typealias Value = MatrixUIA
    }
    
    var uia: MatrixUIA {
        get {
            if !self.storage.contains(MatrixUIAKey.self) {
                self.storage[MatrixUIAKey.self] = MatrixUIA(req: self)
            }
            return self.storage[MatrixUIAKey.self]!
        }
        set(newValue) {
            self.storage[MatrixUIAKey.self] = newValue
        }
    }
    
    struct MatrixUIA {
        private var req: Request
        
        init(req: Request) {
            self.req = req
            self.session = nil
        }
        
        public mutating func connectSession(sessionId: String) {
            if let _ = self.session {
                return
            }
            self.session = .init(req: self.req, sessionId: sessionId)
        }
        
        var session: Session?
        
        struct Session {
            private var req: Request
            private var sessionId: String
            
            init(req: Request, sessionId: String) {
                self.req = req
                self.sessionId = sessionId
            }
            
            public func getData(for key: String) -> String? {
                let app = self.req.application
                guard let sessionData = app.uia.sessions[self.sessionId] else {
                    return nil
                }
                return sessionData[key]
            }
            
            public func setData(for key: String, value: String) {
                let app = self.req.application
                if let _ = app.uia.sessions[self.sessionId] {
                    // Do nothing
                } else {
                    app.uia.sessions[self.sessionId] = UiaSessionData()
                }
                app.uia.sessions[self.sessionId]![key] = value
                
            }
        }
    }
}
