
//
//  UIViewController+KR.swift
//  Krypton
//
//  Created by Alex Grinman on 6/16/15.
//  Copyright (c) 2015 KryptCo.LLC. All rights reserved.
//

import Foundation
import UIKit

extension UIViewController {

    func showWarning(title:String, body:String, then:(()->Void)? = nil) {
        dispatchMain {
            
            let alertController:UIAlertController = UIAlertController(title: title, message: body,
                                                                      preferredStyle: UIAlertControllerStyle.alert)
            
            alertController.addAction(UIAlertAction(title: "OK", style: UIAlertActionStyle.default, handler: { (action:UIAlertAction!) -> Void in
                    then?()
                }))
            
            self.present(alertController, animated: true, completion: nil)
            
        }
    }
    
    func showSettings(with title:String, message:String, dnd:String? = nil, then:(()->Void)? = nil) {
        
        let alertController = UIAlertController(title: title,
                                                message: message,
                                                preferredStyle: .alert)
        
        let settingsAction = UIAlertAction(title: "Settings", style: .default) { (alertAction) in
            
            if let appSettings = URL(string: UIApplicationOpenSettingsURLString) {
                UIApplication.shared.open(appSettings, options: [:], completionHandler: nil)
            }
            
            then?()
        }
        alertController.addAction(settingsAction)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: UIAlertActionStyle.cancel) { (action) in
            then?()
        }
        alertController.addAction(cancelAction)
        
        if let dndKey = dnd {
            alertController.addAction(UIAlertAction(title: "Don't ask again", style: UIAlertActionStyle.destructive) { (action) in
                UserDefaults.standard.set(true, forKey: dndKey)
            })
            
        }

        dispatchMain {
            self.present(alertController, animated: true, completion: nil)
        }
        

    }
    
    func askConfirmationIn(title:String, text:String, accept:String, cancel:String, handler: @escaping ((_ confirmed:Bool) -> Void)) {
        
        let alertController:UIAlertController = UIAlertController(title: title, message: text, preferredStyle: UIAlertControllerStyle.alert)
        
        
        alertController.addAction(UIAlertAction(title: accept, style: UIAlertActionStyle.default, handler: { (action:UIAlertAction) -> Void in
            
            handler(true)
            
        }))
        
        alertController.addAction(UIAlertAction(title: cancel, style: UIAlertActionStyle.cancel, handler: { (action:UIAlertAction) -> Void in
            
            handler(false)
            
        }))
        
        self.present(alertController, animated: true, completion: nil)
    }

}

extension UIViewController {
    
    func findTopViewController() -> UIViewController? {
        
        if let tabbed = self as? UITabBarController {
            return tabbed.selectedViewController?.findTopViewController()
        }
        else if let nav = self as? UINavigationController {
            return nav.visibleViewController?.findTopViewController()
        }
        
        return self
    }
}



