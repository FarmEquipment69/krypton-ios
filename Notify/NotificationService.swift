//
//  NotificationService.swift
//  Notify
//
//  Created by Alex Grinman on 12/15/16.
//  Copyright © 2016 KryptCo. All rights reserved.
//

import UserNotifications
import JSON

class NotificationService: UNNotificationServiceExtension {
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    
    struct UnknownSessionError:Error{}
    struct InvalidCipherTextError:Error{}
    struct InvalidAlertTextError:Error{}
    struct ResultExpected:Error{}
    
    var bestAttemptMutex = Mutex()
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        
        bestAttemptMutex.lock {
            self.contentHandler = contentHandler
        }
        
        /// resync shared session manager
        SessionManager.reload()
        
        /// if app is ever launched in the background *before* device is "unlocked for the first time":
        /// ensure that we wait until the device is "unlocked for the first time" so that the sessions
        /// can be loaded
        guard KeychainStorage().isInteractionAllowed() else {
            contentHandler(NotifyShared.appDataProtectionNotAvailableError())
            return
        }
        
        var session:Session
        var unsealedRequest:Request
        do {
            (session, unsealedRequest) = try NotificationService.unsealRemoteNotification(userInfo: request.content.userInfo)
            
        } catch {
            log("could not processess remote notification content: \(error)")
            
            failUnknown(with: error, contentHandler: contentHandler)
            
            return
        }
        
        // provision AWS API
        guard API.provision() else {
            log("API provision failed.", LogType.error)
            
            failUnknown(with: nil, contentHandler: contentHandler)
            
            return
        }
        
        // migrations
        Policy.migrateOldPolicySettingsIfNeeded(for: session)
        
        do {
            // update our view of the db
            
            // use a single silo
            let silo = try Silo()
            
            var teamIdentity = try IdentityManager.getTeamIdentity()
            try teamIdentity?.syncTeamDatabaseData(from: .mainApp, to: .notifyExt)
            
            // update teams if we need to
            if teamIdentity != nil && TeamUpdater.shouldCheck(for: unsealedRequest) {
                TeamUpdater.checkForUpdate {_ in
                    dispatchAsync {
                        self.handleNoChecks(silo: silo, unsealedRequest: unsealedRequest, session: session, contentHandler: contentHandler)
                    }
                }
                return
            } else {
                self.handleNoChecks(silo: silo, unsealedRequest: unsealedRequest, session: session, contentHandler: contentHandler)
            }
            
        } catch {
            failUnknown(with: error, contentHandler: contentHandler)
            return
        }
        
    }
    
    func handleNoChecks(silo:Silo, unsealedRequest:Request, session:Session, contentHandler: @escaping (UNNotificationContent) -> Void) {
        do {
            // ask silo to handle the request
            try silo.handle(request: unsealedRequest, session: session, communicationMedium: .remoteNotification, completionHandler: {
                self.onTransportCompletionHandler(silo: silo, unsealedRequest: unsealedRequest, session: session, contentHandler: contentHandler)
            })
        }
        catch {
            self.onTransportErrorHandler(error: error, unsealedRequest: unsealedRequest, session: session, contentHandler: contentHandler)
        }
    }
    
    func onTransportCompletionHandler(silo: Silo, unsealedRequest: Request, session: Session, contentHandler: @escaping (UNNotificationContent) -> Void) {
        dispatchMain {
            UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { (notes) in
                
                var noSound = false
                
                for note in notes {
                    guard   let requestObject = note.request.content.userInfo["request"] as? JSON.Object,
                        let deliveredRequest = try? Request(json: requestObject)
                        else {
                            continue
                    }
                    
                    if deliveredRequest.id == unsealedRequest.id {
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [note.request.identifier])
                        
                        noSound = true
                        break
                    }
                }
                
                let cachedResponse:Response? = silo.cachedResponse(for: session, with: unsealedRequest)
                
                let content = UNMutableNotificationContent()
                let (noteTitle, noteBody) = unsealedRequest.notificationDetails(autoResponse: cachedResponse != nil)
                
                content.title = noteTitle
                content.subtitle = unsealedRequest.notificationSubtitle(for: session.pairing.displayName,
                                                                        autoResponse: cachedResponse != nil,
                                                                        isError: cachedResponse?.body.error != nil)
                content.body = noteBody
                
                // special case: me request
                if case .me = unsealedRequest.body {
                    content.title = "\(session.pairing.displayName)."
                }
                // cached
                else if let resp = cachedResponse
                {
                    if let error = resp.body.error {
                        content.body = error
                    } else {
                        content.categoryIdentifier = unsealedRequest.autoNotificationCategory.identifier
                        
                        if !Policy.SessionSettings(for: session).settings.shouldShowApprovedNotifications {
                            self.handleApprovedSilent(contentHandler: contentHandler)
                            return
                        }
                    }
                }
                // pending response
                else {
                    content.categoryIdentifier = unsealedRequest.notificationCategory(for: session).identifier
                }
                
                do {
                    let localRequest = LocalNotificationAuthority.VerifiedLocalRequest(alertText: noteBody,
                                                                                       request: unsealedRequest,
                                                                                       sessionID: session.id,
                                                                                       sessionName: session.pairing.displayName)
                    
                    content.userInfo = try LocalNotificationAuthority.createSignedPayload(for: localRequest)
                } catch {
                    self.failUnknown(with: error, contentHandler: contentHandler)
                    return
                }
                
                
                if noSound {
                    content.sound = nil
                } else {
                    content.sound = UNNotificationSound.default()
                }
                
                contentHandler(content)
            })
            
        }
    }
    
    func onTransportErrorHandler(error: Error?, unsealedRequest: Request, session: Session, contentHandler: @escaping (UNNotificationContent) -> Void) {
        // look for pending notifications with same request (via bluetooth or silent notifications)
        UNUserNotificationCenter.current().getPendingNotificationRequests(completionHandler: { (notes) in
            for request in notes {
                if request.identifier == unsealedRequest.id {
                    let noteContent = request.content
                    
                    let currentContent = UNMutableNotificationContent()
                    currentContent.title = noteContent.title + "." // period for testing
                    currentContent.subtitle = noteContent.subtitle
                    currentContent.categoryIdentifier = noteContent.categoryIdentifier
                    currentContent.body = noteContent.body
                    currentContent.userInfo = noteContent.userInfo
                    currentContent.sound = UNNotificationSound.default()
                    
                    // remove old note
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    
                    // replace with remote with same content
                    contentHandler(currentContent)
                    
                    return
                }
            }
            
            
            // look for delivered notifications with same request (via bluetooth or silent notifications)
            UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { (notes) in
                for note in notes {
                    
                    if note.request.identifier == unsealedRequest.id {
                        let noteContent = note.request.content
                        
                        let currentContent = UNMutableNotificationContent()
                        currentContent.title = noteContent.title  + "." // period for testing
                        currentContent.subtitle = noteContent.subtitle
                        currentContent.categoryIdentifier = noteContent.categoryIdentifier
                        currentContent.body = noteContent.body
                        currentContent.userInfo = noteContent.userInfo
                        currentContent.sound = UNNotificationSound.default()
                        
                        // remove old note
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [note.request.identifier])
                        
                        // replace with remote with same content
                        contentHandler(currentContent)
                        
                        return
                    }
                }
                
                
                // if not pending or delivered, fail with unknown error.
                self.failUnknown(with: error, contentHandler: contentHandler)
            })
            
        })
    }
    
    func handleApprovedSilent(contentHandler:((UNNotificationContent) -> Void)) {
        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { (notes) in
            for note in notes {
                if note.request.content.body == "Krypton Request" {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [note.request.identifier])
                }
            }
        })

        contentHandler(UNMutableNotificationContent())
    }
    
    func failUnknown(with error:Error?, contentHandler:((UNNotificationContent) -> Void)) {
        
        let content = UNMutableNotificationContent()
        
        content.title = "Request failed"
        if let e = error {
            content.body = "The incoming request was invalid. \(e). Please try again."
        } else {
            content.body = "The incoming request was invalid. Please try again."
        }
        content.userInfo = [:]
        
        contentHandler(content)
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        
        let content = UNMutableNotificationContent()
        
        content.title = "Request could not be completed"
        content.body = "The incoming request timed out. Please try again."
        
        self.bestAttemptMutex.lock {
            contentHandler?(content)
        }
    }
    
    
    static func unsealRemoteNotification(userInfo:[AnyHashable : Any]?) throws -> (Session,Request) {
        
        guard   let notificationDict = userInfo?["aps"] as? [String:Any],
            let ciphertextB64 = notificationDict["c"] as? String,
            let ciphertext = try? ciphertextB64.fromBase64()
            else
        {
            log("invalid base64 ciphertext", .error)
            throw InvalidCipherTextError()
        }
        
        guard   let alert = notificationDict["alert"] as? String,
            alert == Properties.defaultRemoteRequestAlert || alert == Properties.defaultRemoteRequestAlertOld
            else {
                throw InvalidAlertTextError()
        }
        
        
        guard   let sessionUUID = notificationDict["session_uuid"] as? String,
            let session = SessionManager.shared.get(queue: sessionUUID)
            else {
                log("unknown session id", .error)
                throw UnknownSessionError()
        }
        
        let sealed = try NetworkMessage(networkData: ciphertext).data
        let request = try Request(from: session.pairing, sealed: sealed)
        
        return (session, request)
    }
    
    
}
