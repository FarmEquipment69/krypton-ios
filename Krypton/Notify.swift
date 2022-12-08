//
//  Notify.swift
//  Krypton
//
//  Created by Alex Grinman on 2/2/17.
//  Copyright © 2017 KryptCo. All rights reserved.
//

import Foundation
import UIKit

import UserNotifications
import JSON
import AwesomeCache

struct NonPresentableRequestError:Error {}

extension Request {
    /**
        An identifier to group identical requests by
        only acceptable for SSH signature requests
     */
    var groupableNotificationIdentifer:String {
        switch self.body {
        case .ssh(let sshSign):
            return sshSign.display
        default:
            return self.id
        }
    }
}

/**
    Show an auto-approved local notification
    group identical requests with the number of times they appeared.
    i.e.: "root@server.com (5)"
 */
typealias GroupableRequestNotificationIdentifier = String
extension GroupableRequestNotificationIdentifier {
    init(request:Request, session:Session) {
        self = "\(session.id)_\(request.groupableNotificationIdentifer)"
    }
    
    func with(count:Int) -> String {
        return "\(self)_\(count)"
    }
}


/**
    Handle presenting local request notifications to the user.
    presents:
        - approvable requests: need users response
        - auto-approved: policy settings already approved, notify user it happened
 */
class Notify {
    private static var _shared:Notify?
    static var shared:Notify {
        if let sn = _shared {
            return sn
        }
        _shared = Notify()
        return _shared!
    }
    
    
    static let shouldPresentInAppUserInfoKey:String = "present_in_app"

    // to avoid showing double notifications for auto-approve, app open notifications
    private static let inAppNoteCacheName = "in_app_note_cache"

    func shouldPresentInAppNotification(notification:UNNotification) -> Bool {
        if  let present = notification.request.content.userInfo[Notify.shouldPresentInAppUserInfoKey] as? Bool,
            present
        {
            return true
        }
        
        guard notification.request.content.categoryIdentifier == Policy.NotificationCategory.autoAuthorized.identifier
            else {
                return false
        }
        
        do {
            guard let payload = notification.request.content.userInfo as? JSON.Object else {
                throw LocalNotificationProcessError.invalidUserInfoPayload
            }
            
            let verifiedLocalNotification = try LocalNotificationAuthority.verifyLocalNotification(with: payload)
            let cache = try? Cache<NSData>(name: Notify.inAppNoteCacheName, directory: SecureLocalStorage.directory(for: Notify.inAppNoteCacheName))
            
            guard cache?.object(forKey: verifiedLocalNotification.request.id) == nil else {
                cache?.removeExpiredObjects()
                return false
            }
            
            cache?.setObject(Data() as NSData, forKey: verifiedLocalNotification.request.id, expires: .seconds(30))
            
            return true

        } catch {
            log("error checking to present in app notification: \(error)")
        }
        
        return false
    }


    init() {}
    
    var pushedNotifications:[String:Int] = [:]
    var noteMutex = Mutex()
    
    static func present(request:Request, for session:Session) {
        
        guard request.body.isApprovable else {
            log("trying to present approval notification for non approvable request type", .error)
            return
        }
        
        let noteSubtitle = request.notificationSubtitle(for: session.pairing.displayName)
        let (noteTitle, noteBody) = request.notificationDetails()
        
        // check if request exists in delivered notifications
        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { (notes) in
            for note in notes {
                guard   let payload = note.request.content.userInfo as? JSON.Object,
                    let verifiedRequest = try? LocalNotificationAuthority.verifyLocalNotification(with: payload)
                    else {
                        continue
                }
                
                // return if it's already there
                if verifiedRequest.request.id == request.id {
                    return
                }
            }
            
            // otherwise, no notificiation so display it:
            let content = UNMutableNotificationContent()
            content.title = noteTitle
            content.subtitle = noteSubtitle
            content.body = noteBody
            content.sound = UNNotificationSound.default()
            
            let localRequest = LocalNotificationAuthority.VerifiedLocalRequest(alertText: noteBody,
                                                                               request: request,
                                                                               sessionID: session.id,
                                                                               sessionName: session.pairing.displayName)
            do {
                content.userInfo = try LocalNotificationAuthority.createSignedPayload(for: localRequest)
            } catch {
                Notify.presentError(message: "Cannot display request: \(error)", request: request, session: session)
                return
            }
            
            content.categoryIdentifier = request.notificationCategory(for: session).identifier
            content.threadIdentifier = request.id
            
            let noteId = request.id
            log("pushing note with id: \(noteId)")
            let request = UNNotificationRequest(identifier: noteId, content: content, trigger: nil)
            
            UNUserNotificationCenter.current().add(request) {(error) in
                log("error firing notification: \(String(describing: error))")
            }
        })
    }
    

    
    func presentApproved(request:Request, for session:Session) {
        
        guard request.body.isApprovable else {
            log("trying to present auto-approved notification for non approvable request type", .error)
            return
        }
        
        let noteSubtitle = request.notificationSubtitle(for: session.pairing.displayName, autoResponse: true, isError: false)
        let (noteTitle, noteBody) = request.notificationDetails(autoResponse: true)

        let noteId = GroupableRequestNotificationIdentifier(request: request, session:session)
        
        let content = UNMutableNotificationContent()
        content.title = noteTitle
        content.subtitle = noteSubtitle
        content.body = noteBody
        content.categoryIdentifier = request.autoNotificationCategory.identifier
        content.sound = UNNotificationSound.default()
        
        // check grouping index for same notification
        var noteIndex = 0
        noteMutex.lock()
        if let idx = pushedNotifications[noteId] {
            noteIndex = idx
        }
        noteMutex.unlock()
        
        let prevRequestIdentifier = noteId.with(count: noteIndex)
        
        // check if delivered notifications cleared
        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { (notes) in
            
            // if notifications clear, reset count
            if notes.filter({ $0.request.identifier == prevRequestIdentifier}).isEmpty {
                self.pushedNotifications.removeValue(forKey: noteId)
                noteIndex = 0
            }
                // otherwise remove previous, update note body
            else {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [prevRequestIdentifier])
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [prevRequestIdentifier])
                content.body = "\(content.body) (\( noteIndex + 1))"
                content.sound = UNNotificationSound(named: "")
            }
            self.noteMutex.unlock()
            
            log("pushing note with id: \(noteId)")
            
            let localRequest = LocalNotificationAuthority.VerifiedLocalRequest(alertText: content.body,
                                                                               request: request,
                                                                               sessionID: session.id,
                                                                               sessionName: session.pairing.displayName)
            
            do {
                content.userInfo = try LocalNotificationAuthority.createSignedPayload(for: localRequest)
            } catch {
                Notify.presentError(message: "Cannot display request: \(error)", request: request, session: session)
                return
            }

            let request = UNNotificationRequest(identifier: noteId.with(count: noteIndex+1), content: content, trigger: nil)
            
            UNUserNotificationCenter.current().add(request) {(error) in
                log("error firing notification: \(String(describing: error))")
                self.noteMutex.lock {
                    self.pushedNotifications[noteId] = noteIndex+1
                }
            }
        })

    }
    
    /**
        Show "error" local notification
    */
    static func presentError(message:String, request:Request, session:Session) {
        
        if UserRejectedError.isRejected(errorString: message) {
            return
        }
        
        let noteSubtitle = request.notificationSubtitle(for: session.pairing.displayName, autoResponse: true, isError: true)
        let (noteTitle, _) = request.notificationDetails(autoResponse: true)

        let noteBody = message
        
        let content = UNMutableNotificationContent()
        content.title = noteTitle
        content.subtitle = noteSubtitle
        content.body = noteBody
        content.sound = UNNotificationSound.default()
        
        let request = UNNotificationRequest(identifier: "\(session.id)_\(message.hash)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    static func presentAppDataProtectionNotAvailableError() {
        let request = UNNotificationRequest(identifier: "app_error_identifier", content: NotifyShared.appDataProtectionNotAvailableError(), trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    
    /**
        Tell the user that their PGP Key was exported
     */
    func presentExportedSignedPGPKey(identities:[String], fingerprint:Data) {
        
        let noteTitle = "Succesfully Exported PGP Public Key"
        let noteSubtitle = "\(fingerprint.hexPretty)"
        
        var noteBody = ""
        if identities.count == 1 {
            noteBody = "Signed user identity: \(identities[0])."
        } else if identities.count > 1 {
            noteBody = "Signed user identities: \(identities.joined(separator: ", "))."
        }
        
        let content = UNMutableNotificationContent()
        content.title = noteTitle
        content.subtitle = noteSubtitle
        content.body = noteBody
        content.sound = UNNotificationSound.default()
        
        let request = UNNotificationRequest(identifier: "pgp_export", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

    }

}







