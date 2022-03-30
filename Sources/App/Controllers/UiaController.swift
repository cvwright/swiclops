//
//  AuthController.swift
//  
//
//  Created by Charles Wright on 3/24/22.
//

import Vapor
import Yams
import AnyCodable

extension HTTPMethod: Codable {
    
}

struct UiaController: RouteCollection {

    
    var app: Application
    var config: Config
    var checkers: [String: AuthChecker]
    
    struct Config: Codable {
        var homeserver: URL
        var routes: [UiaRoute]
        
        struct UiaRoute: Codable {
            var path: String
            var method: HTTPMethod
            var flows: [UiaFlow]
        }
    }
    
    func boot(routes: RoutesBuilder) throws {
        for route in self.config.routes {
            let pathComponents = route.path.split(separator: "/").map { PathComponent(stringLiteral: String($0)) }
            routes.on(route.method, pathComponents, use: { (req) -> Response in
                try await handleUIA(req: req)
                // Now figure out what to do
                // * Is the route one of our own that we should handle internally?
                // * Or is it one that we should proxy to the homeserver?
                
                throw Abort(.notImplemented)
            })
        }
    }
    
    private func _getNewSessionID() -> String {
        let length = 12
        return String( (0 ..< length).map { _ in "0123456789".randomElement()! } )
    }
    
    // FIXME Add a callback so that we can handle UIA and then do something else
    //       Like, sometimes we want to proxy the "real" request (sans UIA) to the homeserver
    //       But other times, we need to handle the request ourselves in another handler
    func handleUIA(req: Request) async throws {

        // First let's make sure that this is one of our configured routes,
        // and let's get its configuration
        guard let route = self.config.routes.first(where: {
            $0.path == req.url.path && $0.method == req.method
        }) else {
            // We're not even supposed to be here
            throw Abort(.internalServerError)
        }

        let flows = route.flows
        
        // Does this request already have a session associated with it?
        guard let uiaRequest = try? req.content.decode(UiaRequest.self)
        else {
            // No existing UIA structure -- Return a HTTP 401 with an initial UIA JSON response
            let sessionId = _getNewSessionID()
            let session = req.uia.connectSession(sessionId: sessionId)
            var params: [String: [String: AnyCodable]] = [:]
            for flow in flows {
                for stage in flow.stages {
                    if nil != params[stage] {
                        // FIXME The userId should not be nil when the user is logged in and doing something that requires auth
                        //       We can hit https://HOMESERVER/_matrix/client/VERSION/whoami to get the username from the access_token
                        //       We should probably also cache the access token locally, so we don't constantly batter that endpoint
                        params[stage] = try? await checkers[stage]?.getParams(req: req, authType: stage, userId: nil)
                    }
                }
            }
            // FIXME somehow we need to set the UIA session's list of completed flows to []
            
            throw UiaIncomplete(flows: flows, params: params, session: sessionId)
        }
        
        let auth = uiaRequest.auth
        let sessionId = auth.session
        // FIXME somehow we need to get (and later update) the UIA session's list of completed flows
        
        let authType = auth.type
        // Is this one of the auth types that are required here?
        let allStages = flows.reduce( Set<String>()) { (curr,next) in
            curr.union(Set(next.stages))
        }
        guard allStages.contains(authType) else {
            // FIXME Create and return a proper Matrix response
            //throw Abort(.forbidden)
            //return MatrixErrorResponse(status: .forbidden, errorcode: .forbidden, error: "Invalid auth type") //.encodeResponse(for: req)
            throw MatrixError(status: .forbidden, errcode: .invalidParam, error: "Invalid auth type \(authType)")
        }
        
        guard let checker = self.checkers[authType]
        else {
            // Uh oh, we screwed up and we don't have a checker for an auth type that we advertised.  Doh!
            // FIXME Create an actual Matrix response and return it
            //throw Abort(.internalServerError)
            throw MatrixError(status: .internalServerError, errcode: .unknown, error: "No checker found for auth type \(authType)")
        }
        
        let success = try await checker.check(req: req, authType: authType)
        if success {
            // Ok cool, we cleared one stage
            // * Was this the final stage that we needed?
            // * Or are there still more to be completed?
            
            throw Abort(.notImplemented)
            
        } else {
            throw MatrixError(status: .forbidden, errcode: .forbidden, error: "Authentication failed for type \(authType)")
        }
        
        
    }
}
