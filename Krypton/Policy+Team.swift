//
//  Policy+Team.swift
//  Krypton
//
//  Created by Alex Grinman on 8/6/17.
//  Copyright © 2017 KryptCo. All rights reserved.
//

import Foundation

struct TemporaryApprovalTime {
    let description:String
    let short:String
    let value:TimeInterval
}
extension Policy {
    
    static var temporaryApprovalInterval:TemporaryApprovalTime {
        
        var approvalSeconds:TimeInterval
        
        // check if we have a team
        if  let teamIdentity = (try? IdentityManager.getTeamIdentity()) as? TeamIdentity,
            let team = (try? teamIdentity.dataManager.withTransaction{ return try $0.fetchTeam() }),
            let teamApprovalSeconds = team.policy.temporaryApprovalSeconds
        {
            approvalSeconds = Double(teamApprovalSeconds)
        } else {
            approvalSeconds = Properties.Interval.threeHours.rawValue
        }
        
        let description = approvalSeconds.timeAgoLong(suffix: "")
        let short = approvalSeconds.timeAgo(suffix: "")
        
        return TemporaryApprovalTime(description: description, short: short, value: approvalSeconds)
    }
    
    static func isNeverAskAvailable() throws -> Bool {
        guard let teamIdentity = try IdentityManager.getTeamIdentity() else {
            return true
        }
        
        // if the team has a policy set, we must not allow never ask
        let policy = try teamIdentity.dataManager.withReadOnlyTransaction(){ try $0.fetchTeam().policy.temporaryApprovalSeconds }
        guard policy == nil
        else {
            return false
        }
        
        return true
    }
}
