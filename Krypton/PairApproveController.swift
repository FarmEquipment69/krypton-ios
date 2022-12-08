//
//  PairApproveController.swift
//  Krypton
//
//  Created by Alex Grinman on 10/26/16.
//  Copyright © 2016 KryptCo. All rights reserved.
//

import UIKit
import LocalAuthentication

class PairApproveController: UIViewController {
    
    @IBOutlet weak var blurView:UIView!
    
    @IBOutlet weak var popupView:UIView!
    @IBOutlet weak var deviceLabel:UILabel!
    @IBOutlet weak var messageLabel:UILabel!

    
    @IBOutlet weak var buttonView:UIView!
    @IBOutlet weak var buttonViewHeight:NSLayoutConstraint!

    @IBOutlet weak var checkBox:M13Checkbox!
    @IBOutlet weak var arcView:UIView!

    static var isAuthenticated:Bool = false
    
    var rejectColor = UIColor.reject

    var pairing:Pairing?

    var scanController:KRScanController?
    
    var didPairSuccessfully:(() -> ())?
    

    override func viewDidLoad() {
        super.viewDidLoad()
        
        popupView.layer.shadowColor = UIColor.black.cgColor
        popupView.layer.shadowOffset = CGSize(width: 0, height: 0)
        popupView.layer.shadowOpacity = 0.2
        popupView.layer.shadowRadius = 3
        popupView.layer.masksToBounds = false

        checkBox.animationDuration = 1.0
        
        checkBox.checkmarkLineWidth = 2.0
        checkBox.stateChangeAnimation = .spiral
        checkBox.boxLineWidth = 2.0

        if let pairing = pairing {
            deviceLabel.text = pairing.displayName.uppercased()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        arcView.spinningArc(lineWidth: checkBox.checkmarkLineWidth)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    //MARK: Accept Reject
    
    @IBAction func acceptTapped() {
        guard let pairing = self.pairing else {
            self.doRejectAnimation()
            return
        }
        
        UIImpactFeedbackGenerator(style: UIImpactFeedbackStyle.heavy).impactOccurred()

        self.messageLabel.text = "Pairing".uppercased()
        
        UIView.animate(withDuration: 0.2, animations: {
            self.buttonView.alpha = 0
        }) { (_) in
            UIView.animate(withDuration: 0.4, animations: {
                self.messageLabel.textColor = UIColor.app
                self.buttonViewHeight.constant = 0
                self.view.layoutIfNeeded()
                
            }) { (_) in
                self.approve(pairing: pairing)
            }
            
        }
        

    }
    
    @IBAction func rejectTapped() {
        UIImpactFeedbackGenerator(style: UIImpactFeedbackStyle.heavy).impactOccurred()

        Analytics.postEvent(category: "device", action: "pair", label: "reject")
        doRejectAnimation()
    }
    
    func doRejectAnimation() {
        self.checkBox.secondaryCheckmarkTintColor = rejectColor
        self.checkBox.tintColor = rejectColor
        
        self.messageLabel.text = "Cancelled".uppercased()
        
        UIView.animate(withDuration: 0.2, animations: {
            self.buttonView.alpha = 0
        }) { (_) in
            UIView.animate(withDuration: 0.4, animations: {
                self.messageLabel.textColor = self.rejectColor
                self.arcView.alpha = 0
                self.buttonViewHeight.constant = 0
                self.view.layoutIfNeeded()
                
            }) { (_) in
                self.checkBox.setCheckState(M13Checkbox.CheckState.mixed, animated: true)
                dispatchAfter(delay: 1.0, task: {
                    self.dismiss(animated: true, completion: {
                        self.scanController?.canScan = true
                    })
                })
            }
            
        }

    }
    
    
    //MARK: Approve Scanned
    
    func approve(pairing:Pairing) {
        authenticate(completion: { (success) in
            guard success else {
                dispatchMain {
                    self.doRejectAnimation()
                }
                
                self.showWarning(title: "Authentication Failed", body: "Authentication is needed to pair to a new device.")
                
                return
            }
            
            do {
                
                if let existing = SessionManager.shared.getDuplicate(pairing: pairing) {
                    SessionManager.shared.remove(session: existing, keepSeedCache: true)
                    TransportControl.shared.remove(session: existing)
                    Analytics.postEvent(category: "device", action: "pair", label: "existing")
                } else {
                    if let browser = pairing.browser {
                        Analytics.postEvent(category: browser.kind.rawValue, action: "pair", label: "new")
                    } else {
                        Analytics.postEvent(category: "device", action: "pair", label: "new")
                    }
                }
                
                // trying to developer-pair but no developer mode / developer key pair
                if pairing.browser == nil && (try? KeyManager.hasKey()) == .some(false) {
                    dispatchAsync {
                        do {
                            try KeyManager.generateKeyPair(type: KeyType.RSA)
                            dispatchMain {
                                DeveloperMode.isOn = true
                            }
                        } catch {
                            self.showWarning(title: "Error", body: "Cannot generate developer key pair: \(error)")
                        }
                    }
                }
                
                let session = try Session(pairing: pairing)
                SessionManager.shared.add(session: session, temporary: true)
                TransportControl.shared.add(session: session, newPairing: true)

                Policy.SessionSettings(for: session).setAlwaysAsk()

                dispatchAsync {
                    guard TransportControl.shared.waitForPairing(session: session) else {
                        SessionManager.shared.remove(session: session, keepSeedCache: true)
                        TransportControl.shared.remove(session: session)
                        
                        Analytics.postEvent(category: "device", action: "pair", label: "failed")

                        self.showWarning(title: "Error Pairing", body: "Timed out. Please make sure Bluetooth is on or you have an internet connection and try again.", then: {
                            dispatchMain {
                                self.doRejectAnimation()
                            }

                        })
                        
                        return
                    }
                    
                    SessionManager.shared.add(session: session)
                    
                    dispatchMain {
                        self.arcView.alpha = 0
                        
                        self.checkBox.setCheckState(M13Checkbox.CheckState.checked, animated: true)
                        self.messageLabel.text = "Paired".uppercased()
                        
                        dispatchAfter(delay: 1.0, task: {
                            self.dismiss(animated: true, completion: {
                                self.didPairSuccessfully?()
                                self.scanController?.canScan = true
                            })
                        })
                    }

                }


            }
            catch let e {
                log("error creating session: \(e)", .error)
                self.showWarning(title: "Error Pairing", body: "Could not create session with this device. \(e))")
                
                Analytics.postEvent(category: "device", action: "pair", label: "failed")

                dispatchMain {
                    self.doRejectAnimation()
                }
            }
        })
    }
    
    func authenticate(completion:@escaping (Bool)->Void) {
        let context = LAContext()
        let policy = LAPolicy.deviceOwnerAuthentication
        let reason = "\(Properties.appName) needs to authenticate you before pairing with a new computer."
        
        var err:NSError?
        guard context.canEvaluatePolicy(policy, error: &err) else {
            log("cannot eval policy: \(err?.localizedDescription ?? "unknown err")", .error)
            completion(true)
            
            return
        }
        
        
        dispatchMain {
            context.evaluatePolicy(policy, localizedReason: reason, reply: { (success, policyErr) in
                completion(success)
            })
            
        }
        
    }


    

}
