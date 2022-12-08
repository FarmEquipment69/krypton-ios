//
//  Policy.swift
//  Krypton
//
//  Created by Alex Grinman on 9/14/16.
//  Copyright © 2016 KryptCo, Inc. All rights reserved.
//

import Foundation
import JSON
import AwesomeCache

class Policy {
    
    /// ask me every time for u2f
    static var requireUserInteractionU2F:Bool {
        get {
            let setting = (try? KeychainStorage().getData(key: Constants.u2fRequiresApproval)) ?? Data(bytes: [0x01])
            return setting.bytes == [0x01]
        }
        set(v) {
            let byte:UInt8 = v ? 0x01 : 0x00;
            try? KeychainStorage().setData(key: Constants.u2fRequiresApproval, data: Data(bytes: [byte]))
        }
    }
    
    /// Interval Options
    enum Interval:TimeInterval {
        //case fifteenSeconds = 15
        case oneHour = 3600
        case threeHours = 10800
        
        var seconds:TimeInterval {
            return self.rawValue
        }
    }
    
    
    
    /// Policy Storage Keys
    enum StorageKey:String {
        case settings = "policy_settings"
        case temporarilyAllowedHosts = "policy_temporarily_approved_user_at_hosts"

        func key(for sessionID:String) -> String {
            return "\(self.rawValue)_\(sessionID)"
        }
    }
    
    
    /// A temporarily allowed user@hostname
    struct TemporarilyAllowedHost:Jsonable {
        let userAndHost:VerifiedUserAndHostAuth
        let expires:Date
        
        init(userAndHost:VerifiedUserAndHostAuth, expires:Date) {
            self.userAndHost = userAndHost
            self.expires = expires
        }
        
        init(json: Object) throws {
            try self.init(userAndHost: VerifiedUserAndHostAuth(json: json ~> "user_and_host"),
                          expires: Date(timeIntervalSince1970: json ~> "expires"))
        }
        
        var object: Object {
            return ["user_and_host": userAndHost.object, "expires": expires.timeIntervalSince1970]
        }
    }
    
    
    /// Policy Settings
    struct Settings:Jsonable {
        
        /// Storage key for `allowedUntil` preferences on specific request types
        typealias AllowedUntilTypeKey = String

        enum AllowedUntilType:AllowedUntilTypeKey {
            case ssh = "ssh"
            case gitCommit = "git_commit"
            case gitTag = "git_tag"
            case decryptLog = "teams_decrypt_log"
            
            static var all:[AllowedUntilType] { return [.ssh, .gitCommit, .gitTag, .decryptLog] }
            
            var key:AllowedUntilTypeKey { return self.rawValue }
        }
        
        
        // key the request policy to the time remaining
        var allowedUntil:[AllowedUntilTypeKey:UInt64] = [:]
        
        // other settings
        var shouldShowApprovedNotifications:Bool = true
        var shouldPermitUnknownHostsAllowed:Bool = false
        
        // u2f
        var u2fZeroTouchEnabled:Bool = false
        
        // dangerous setting: never ask
        var shouldNeverAsk:Bool = false
        
        var hasMigratedOldPolicies:Bool = false

        
        init() {}
        
        init( allowedUntil:[AllowedUntilTypeKey:UInt64],
              shouldShowApprovedNotifications:Bool,
              shouldPermitUnknownHostsAllowed:Bool,
              u2fZeroTouchEnabled:Bool = false,
              shouldNeverAsk:Bool,
              hasMigratedOldPolicies:Bool)
        {
            self.allowedUntil = allowedUntil
            self.shouldShowApprovedNotifications = shouldShowApprovedNotifications
            self.shouldPermitUnknownHostsAllowed = shouldPermitUnknownHostsAllowed
            self.u2fZeroTouchEnabled = u2fZeroTouchEnabled
            self.shouldNeverAsk = shouldNeverAsk
            self.hasMigratedOldPolicies = hasMigratedOldPolicies
        }
        
        init(json: Object) throws {
            let zeroTouchEnabled:Bool? = try? json ~> "u2f_zero_touch"
            
            try self.init(allowedUntil: json ~> "allowed_until",
                          shouldShowApprovedNotifications: json ~> "should_show_approved_notifications",
                          shouldPermitUnknownHostsAllowed: json ~> "should_permit_unknownHosts_allowed",
                          u2fZeroTouchEnabled: zeroTouchEnabled ?? false,
                          shouldNeverAsk: json ~> "should_never_ask",
                          hasMigratedOldPolicies: json ~> "has_migrated_old_policies")
        }
        
        var object: Object {
            return [ "allowed_until": allowedUntil,
                     "should_show_approved_notifications": shouldShowApprovedNotifications,
                     "should_permit_unknownHosts_allowed": shouldPermitUnknownHostsAllowed,
                     "u2f_zero_touch": u2fZeroTouchEnabled,
                     "should_never_ask": shouldNeverAsk,
                     "has_migrated_old_policies": hasMigratedOldPolicies]
        }
        
    }
    
    /// Policy Session based Settings
    class SessionSettings {
        // policy settings
        let sessionID:String
        private var _settings:Settings
        
        var settings:Settings {
            return _settings
        }
        
        // special case cache
        private let sshUserAndHostAllowedUntil:Cache<NSData>?
        
        /// init
        init(for session:Session) {
            self.sessionID = session.id
            
            let cacheName = StorageKey.temporarilyAllowedHosts.key(for: session.id)
            self.sshUserAndHostAllowedUntil = try? Cache<NSData>(name: cacheName,
                                                                 directory: SecureLocalStorage.directory(for: cacheName))
            
            guard let settingsObject = try? KeychainStorage().getData(key: StorageKey.settings.key(for: session.id)),
                let settings = try? Settings(jsonData: settingsObject)
                else {
                    self._settings = Settings()
                    return
            }
            
            self._settings = settings
        }
        
        // Set  settings
        
        func setAlwaysAsk() {
            _settings.shouldNeverAsk = false
            _settings.allowedUntil = [:]
            
            // if always ask selected: turn off migration abilities
            _settings.hasMigratedOldPolicies = true
            
            sshUserAndHostAllowedUntil?.removeAllObjects()
            save()
        }
        
        func setAlwaysAsk(for allowedType:Settings.AllowedUntilType) {
            _settings.allowedUntil.removeValue(forKey: allowedType.key)
            save()
        }
        
        func setAlwaysAsk(for userAndHost:VerifiedUserAndHostAuth)  {
            sshUserAndHostAllowedUntil?.removeObject(forKey: userAndHost.uniqueID)
        }
        
        func setZeroTouch(enabled:Bool) {
            _settings.u2fZeroTouchEnabled = enabled
            save()
        }
        
        func setNeverAsk() {
            _settings.shouldNeverAsk = true
            _settings.allowedUntil = [:]
            sshUserAndHostAllowedUntil?.removeAllObjects()
            
            save()
        }
        
        
        func set(shouldShowApprovedNotifications:Bool) {
            _settings.shouldShowApprovedNotifications = shouldShowApprovedNotifications
            save()
        }
        
        func set(shouldPermitUnknownHostsAllowed:Bool) {
            _settings.shouldPermitUnknownHostsAllowed = shouldPermitUnknownHostsAllowed
            save()
        }
        
        func setHasMigratedOldPolicySettings() {
            _settings.hasMigratedOldPolicies = true
            save()
        }
        
        /// Set Allow
        func allow(request:Request) {
            switch request.body {
            case .ssh, .git, .hosts, .me, .decryptLog, .noOp, .unpair, .teamOperation, .u2fAuthenticate, .u2fRegister:
                return
            case .readTeam:
                // special cases to allow logs for 6 hours when the readTeam request is allowed.
                self.allowAll(allowAllType: Policy.Settings.AllowedUntilType.decryptLog, for: TimeSeconds.hour.multiplied(by: 6))
            }
        }
        func allowAll(request:Request, for timeInterval:TimeInterval) {
            self.allowAll(allowAllType: request.allowAllUntilPolicyKey, for: timeInterval)
        }
        
        func allowAll(allowAllType:Policy.Settings.AllowedUntilType?, for timeInterval:TimeInterval) {
            
            let allowedUntil = Date().addingTimeInterval(timeInterval).timeIntervalSince1970
            
            guard let allowAllRequestKey = allowAllType else {
                // not auto allow-all-able
                return
            }
            
            _settings.allowedUntil[allowAllRequestKey.key] = UInt64(allowedUntil)
            
            // special case: remove specific hosts if *all* ssh is temporarily allowed
            if case .ssh = allowAllRequestKey {
                sshUserAndHostAllowedUntil?.removeAllObjects()
            }
            
            save()
            
            // send allowed pending
            Policy.sendAllowedPendingIfNeeded()
        }
        
        func allowThis(userAndHost:VerifiedUserAndHostAuth, for timeInterval:TimeInterval) {
            let allowedUntil = Date().addingTimeInterval(timeInterval)
            let temporarilyAllowedHost = TemporarilyAllowedHost(userAndHost: userAndHost, expires: allowedUntil)
            
            do {
                try sshUserAndHostAllowedUntil?.setObject(temporarilyAllowedHost.jsonData() as NSData,
                                                          forKey: userAndHost.uniqueID,
                                                          expires: .seconds(timeInterval))
            } catch {
                log("error saving temporary host: \(error)", .error)
            }
            
            // send allowed pending
            Policy.sendAllowedPendingIfNeeded()
        }
        
        
        /// Get Allow
        func isAllowed(for request:Request) -> Bool {
            
            let allAllowed = isAllAllowed(for: request)
            
            switch request.body {
            case .me, .unpair, .noOp:
                return true
                
            case .u2fRegister, .u2fAuthenticate:
                return settings.u2fZeroTouchEnabled
                            
            case .hosts, .readTeam, .teamOperation:
                return false
                
            case .ssh(let sshSign):
                sshUserAndHostAllowedUntil?.removeExpiredObjects()
                
                // do we have a host auth?
                guard let userAndHost = sshSign.verifiedUserAndHostAuth else {
                    return allAllowed && settings.shouldPermitUnknownHostsAllowed
                }
                
                // is this host temporarily allowed?
                guard   let data = sshUserAndHostAllowedUntil?.object(forKey: userAndHost.uniqueID),
                        let temporarilyAllowedHost = try? TemporarilyAllowedHost(jsonData: data as Data)
                else {
                        return allAllowed
                }
                
                
                return allAllowed || ( Date() < temporarilyAllowedHost.expires )
                
            case .git, .decryptLog:
                return allAllowed
                
            }
        }
        
        private func isAllAllowed(for request:Request) -> Bool {
            // if never ask is on, all requests should go through automatically
            guard settings.shouldNeverAsk == false
            else {
                // ensure the team allows this policy
                do {
                    guard try Policy.isNeverAskAvailable() else {
                        return false
                    }
                } catch {
                    log("error checking never ask policy: \(error)", .error)
                    return false
                }
                
                return true
            }
            
            guard   let allowAllRequestKey = request.allowAllUntilPolicyKey,
                    let allowedUntil = self.settings.allowedUntil[allowAllRequestKey.key]
                else {
                    return false
            }
            
            let allowedUntilDate = Date(timeIntervalSince1970: TimeInterval(allowedUntil))
            
            return Date() < allowedUntilDate
        }
        
        
        var temporarilyApprovedSSHHosts:[TemporarilyAllowedHost] {
            sshUserAndHostAllowedUntil?.removeExpiredObjects()
            let results:[NSData] = sshUserAndHostAllowedUntil?.allObjects() ?? []
            
            var temporarilyApproved:[TemporarilyAllowedHost] = []
            
            results.forEach({ object in
                guard let allowedHost = try? TemporarilyAllowedHost(jsonData: object as Data)
                    else {
                        return
                }
                
                temporarilyApproved.append(allowedHost)
            })
            
            return temporarilyApproved
        }
        
        /// Save
        private func save() {
            do {
                try KeychainStorage().setData(key: StorageKey.settings.key(for: sessionID), data: self.settings.jsonData())
            } catch {
                log("error: could not save policy prefs \(error)", .error)
            }
            
        }
    }
    
    
    // migrate old policy settings if needed
    static func migrateOldPolicySettingsIfNeeded(for session:Session) {
        let sessionPolicy = Policy.SessionSettings(for: session)
        
        guard   sessionPolicy.settings.hasMigratedOldPolicies == false,
                let oldPolicyNeedsUserApproval = UserDefaults.group?.object(forKey: "policy_user_approval_\(session.id)") as? Bool,
                oldPolicyNeedsUserApproval == false
        else {
            return
        }
        
        sessionPolicy.setHasMigratedOldPolicySettings()
        sessionPolicy.setNeverAsk()
    }
    
    static func migrateZeroTouchBrowserSettingIfNeeded(for sessions:[Session]) {
        do {
            let requireInteractionOldSetting = try KeychainStorage().getData(key: Constants.u2fRequiresApproval)
            
            // if zero touch is on (interaction disabled)
            // migrate all sessions
            if requireInteractionOldSetting.bytes == [0x00] {
                sessions.forEach {
                    // only for browser sessions
                    guard $0.pairing.browser != nil else {
                        return
                    }
                    
                    Policy.SessionSettings(for: $0).setZeroTouch(enabled: true)
                }
            }
            
            Policy.requireUserInteractionU2F = true
            try KeychainStorage().delete(key: Constants.u2fRequiresApproval)
            
        } catch KeychainStorageError.notFound {
        } catch {
            log("error migrating zero touch: \(error)", .error)
        }
    }

    
}

extension Request {
    internal var allowAllUntilPolicyKey:Policy.Settings.AllowedUntilType? {
        switch body {
        case .me, .unpair, .noOp, .hosts, .readTeam, .teamOperation, .u2fAuthenticate, .u2fRegister:
            // not auto-allowable
            return nil
            
        case .ssh:
            return .ssh
            
        case .decryptLog:
            return .decryptLog
            
        case .git(let gitSign):
            switch gitSign.git {
            case .commit:
                return .gitCommit
                
            case .tag:
                return .gitTag
            }
        }
    }
    
}



func ==(l:Policy.PendingAuthorization, r:Policy.PendingAuthorization) -> Bool {
    return  l.session.id == r.session.id &&
            l.request.id == r.request.id
}


