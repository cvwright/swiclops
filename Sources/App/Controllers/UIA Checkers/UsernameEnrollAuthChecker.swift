//
//  UsernameEnrollAuthChecker.swift
//  
//
//  Created by Charles Wright on 10/5/22.
//

import Vapor
import Fluent

import AnyCodable

struct UsernameEnrollAuthChecker: AuthChecker {
    let AUTH_TYPE_ENROLL_USERNAME = "m.enroll.username"
    
    let app: Application
    var badWords: Set<String>
    
    init(app: Application) throws {

        
        self.app = app

        let results = try? BadWord.query(on: app.db).all().wait()
        
        if let badWordList = results {
            self.badWords = Set(badWordList.compactMap {
                guard let word = $0.id else {
                    return nil
                }
                return word.lowercased().replacingOccurrences(of: " ", with: "")
            })
        } else {
            self.badWords = []
        }
        app.logger.debug("UsernameEnrollAuthChecker: Loaded \(self.badWords.count) bad words")
    }
    
    func getSupportedAuthTypes() -> [String] {
        [AUTH_TYPE_ENROLL_USERNAME]
    }
    
    func getParams(req: Request, sessionId: String, authType: String, userId: String?) async throws -> [String : AnyCodable]? {
        [:]
    }
    
    
    private func checkForBadWords(req: Request, username: String) throws {
        // Is the username a known bad word?
        if badWords.contains(username) {
            req.logger.debug("Username is a known bad word")
            throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is not available")
        }
        
        // Is the username a leetspeak version of a known bad word?
        let unl33t = username
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "2", with: "z")
            .replacingOccurrences(of: "3", with: "r")
            .replacingOccurrences(of: "4", with: "a")
            .replacingOccurrences(of: "5", with: "s")
            .replacingOccurrences(of: "6", with: "b")
            .replacingOccurrences(of: "7", with: "t")
            .replacingOccurrences(of: "8", with: "ate")
            .replacingOccurrences(of: "9", with: "g")
        if badWords.contains(unl33t) {
            req.logger.debug("Username is a bad word in leetspeak")
            throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is not available")
        }
        
        // Did they use punctuation to hide a bad word?
        let usernameWithoutPunks = username
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if badWords.contains(usernameWithoutPunks) {
            req.logger.debug("Username is a bad word with punctuation")
            throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is not available")
        }
        
        // Did they use punctuation AND leetspeak?
        let unl33tWithoutPunks = unl33t
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if badWords.contains(unl33tWithoutPunks) {
            req.logger.debug("Username is a bad word in leetspeak with punctuation")
            throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is not available")
        }
        
        // Does the username contain a bad word as an obvious subcomponent?
        // e.g. cuss_insult_swear or cuss-insult-swear or cuss.insult.swear
        let dashTokens = username.split(separator: "-")
        let underscoreTokens = username.split(separator: "_")
        let dotTokens = username.split(separator: ".")
        for tokenList in [dashTokens, underscoreTokens, dotTokens] {
            for token in tokenList {
                if badWords.contains(String(token)) {
                    req.logger.debug("Username contains a known bad word")
                    throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is not available")
                }
            }
        }
    }
    
    func check(req: Request, authType: String) async throws -> Bool {
        struct UsernameEnrollUiaRequest: Content {
            struct UsernameAuthDict: UiaAuthDict {
                var type: String
                var session: String
                var username: String
            }
            var auth: UsernameAuthDict
        }
        
        guard let usernameRequest = try? req.content.decode(UsernameEnrollUiaRequest.self) else {
            let msg = "Couldn't parse \(AUTH_TYPE_ENROLL_USERNAME) request"
            req.logger.error("\(msg)") // The need for this dance is moronic.  Thanks SwiftLog.
            throw MatrixError(status: .badRequest, errcode: .badJson, error: msg)
        }
        let sessionId = usernameRequest.auth.session
        let username = usernameRequest.auth.username.lowercased()
        
        guard let uiaRequest = try? req.content.decode(UiaRequest.self) else {
            throw MatrixError(status: .badRequest, errcode: .badJson, error: "Couldn't parse UIA request")
        }
        
        let auth = uiaRequest.auth
        let session = req.uia.connectSession(sessionId: auth.session)
        let userEmailAddress = await session.getData(for: EmailAuthChecker.ENROLL_SUBMIT_TOKEN+".email") as? String
        
        // Now we run our sanity checks on the requested username
        
        // Is it too short, or too long?
        guard username.count > 0,
              username.count < 256
        else {
            let msg = "Username must be at least 1 character and no more than 255 characters"
            req.logger.debug("\(msg)")
            throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: msg)
        }
        
        // Does it look like it's trying to be misleading or possibly impersonate another user?
        // e.g. _bob or bob_ or bob. or .bob
        guard let first = username.first,
              let last = username.last,
              first.isPunctuation == false,
              last.isPunctuation == false
        else {
            let msg = "Username may not start or end with punctuation"
            req.logger.debug("\(msg)")
            throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: msg)
        }
        
        // Is the requested username a valid Matrix username according to the spec?
        // Dangit, the new Regex is only available in Swift 5.7+
        //let regex = try Regex("([A-z]|[a-z]|[0-9]|[-_\.])+")
        // Doing it the old fashioned way -- Thank you Paul Hudson https://www.hackingwithswift.com/articles/108/how-to-use-regular-expressions-in-swift
        let range = NSRange(location: 0, length: username.utf16.count)
        let regex = try! NSRegularExpression(pattern: "([A-z]|[a-z]|[0-9]|[-_\\.])+")
        if regex.rangeOfFirstMatch(in: username, range: range).length != range.length {
            let msg = "Username must consist of ONLY alphanumeric characters and dot, dash, and underscore"
            req.logger.debug("\(msg)")
            throw MatrixError(status: .badRequest, errcode: .invalidUsername, error: msg)
        }
        
        // Does the requested username contain any obvious bad words?
        if badWords.count > 0 {
            try checkForBadWords(req: req, username: username)
        }
        
        // Is the username already taken?
        let existingUsername = try await Username.find(username, on: req.db)
        if let record = existingUsername {
            if record.status == .pending {
                req.logger.debug("Username [\(username)] is pending with reason [\(record.reason ?? "(none)")]")

                if record.reason == sessionId {
                    // There is already a pending registration but it's the same user
                    req.logger.debug("Username is already pending but it's for this UIA session so it's OK")
                }
                
                // cvw: Let's loosen this up a bit
                // * Allow a user with the same subscription identifier or the same email address to pick up where they left off and complete registration with the same username
                else if let email = userEmailAddress,
                        record.reason == email
                {
                    // There is already a pending registration but it's the same user
                    req.logger.debug("Username is already pending but it's for the same email address so it's OK")
                }
                
                else {
                    req.logger.debug("Username is already pending for someone else")
                    
                    // OK there is (was?) a pending registration for some other client.  Is it an old one or is it current?
                    let now = Date()
                    // Here "current" means within the past n minutes
                    let timeoutSeconds = 600.0
                    
                    guard let timestamp = record.updated ?? record.created
                    else {
                        req.logger.error("Username is pending but there is no timestamp")
                        throw MatrixError(status: .internalServerError, errcode: .unknown, error: "Error handling pending username reservation")
                    }
                    
                    let elapsedTime = timestamp.distance(to: now)
                    req.logger.debug("Username has been pending for \(elapsedTime) of \(timeoutSeconds) seconds")
                    
                    if elapsedTime < timeoutSeconds {
                        req.logger.warning("Username is already pending for someone else")
                        throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is pending.  Try again in \(timeoutSeconds) seconds.")
                    }
                    req.logger.debug("Old reservation is now expired.  Ok to claiming username [\(username)] for the new user.")

                }
                
                // If we are still here, then we have an existing pending reservation, but the current user is allowed to override and overwrite it.
                // Either because they created the old one, or the old one is expired.
                // Update the record in the database
                let reason = userEmailAddress ?? sessionId
                try await Username.query(on: req.db)
                                  .set(\.$status, to: .pending)
                                  .set(\.$reason, to: reason)
                                  .filter(\.$id == username)
                                  .filter(\.$status == .pending)  // Only modify an existing username if it's pending -- ie don't grab it from someone who has already completed registration
                                  .update()

            } else {
                // Otherwise the existence of this non-pending record in the database shows that the username is unavailable
                req.logger.warning("Username has already been claimed")
                throw MatrixError(status: .forbidden, errcode: .invalidUsername, error: "Username is not available")
            }
            
        } else {
            // This username is new to us.
            // Create a new pending reservation for this client, trying our best to remember who reserved it, in case they are unable to complete the registration in this session.
            let reason = userEmailAddress ?? sessionId
            let pending = Username(username, status: .pending, reason: reason)
            req.logger.debug("Creating pending Username reservation with reason [\(reason)]")
            try await pending.create(on: req.db)
        }

        // Save the username in our session, for use by other UIA components
        req.logger.debug("Saving username [\(username)] in our session")
        await session.setData(for: "username", value: username)
        
        req.logger.debug("Done with username stage!")
        return true
    }
    
    func onSuccess(req: Request, authType: String, userId: String) async throws {
        // Do nothing
    }
    
    func onLoggedIn(req: Request, authType: String, userId: String) async throws {
        // Do nothing -- Should never happen anyway
    }
    
    func onEnrolled(req: Request, authType: String, userId: String) async throws {
        // First extract the basic username from the fully-qualified Matrix user id
        let localpart = userId.split(separator: ":").first!
        let username = localpart.trimmingCharacters(in: .init(charactersIn: "@"))
        
        guard let uiaRequest = try? req.content.decode(UiaRequest.self) else {
            let msg = "Could not parse UIA request"
            req.logger.error("\(msg)")
            throw MatrixError(status: .badRequest, errcode: .badJson, error: msg)
        }
        let auth = uiaRequest.auth
        let sessionId = auth.session

        // Then save this username in the database in a currently-enrolled state
        // Doh, doing this naively results in a race condition
        //let record = Username(username, status: .enrolled)
        //try await record.save(on: req.db)
        // Doing this properly requires that we make sure it really was *this* UIA session that had reserved the username (and that the username is still pending, and hasn't been grabbed by someone else...  Like maybe our user started signing up and then walked away for an hour before completing the last steps.  That's not gonna cut it buddy; somebody else is free to take that username after 20 minutes.  So we need to check for that.
        try await Username.query(on: req.db)
                          .set(\.$status, to: .enrolled)
                          .filter(\.$id == username)
                          .filter(\.$status == .pending)
                          .filter(\.$reason == sessionId)
                          .update()
            
    }
    
    func isUserEnrolled(userId: String, authType: String) async throws -> Bool {
        // If you have a user id, then yes you have a username
        return true
    }
    
    func isRequired(for userId: String, making request: Request, authType: String) async throws -> Bool {
        // If you already have a user id, then you have no need to enroll for a new one
        return false
    }
    
    func onUnenrolled(req: Request, userId: String) async throws {
        // Do nothing
    }
    
    
}
