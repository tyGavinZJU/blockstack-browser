//
//  AppDelegate.swift
//  Blockstack
//
//  Created by Larry Salibra on 2/26/17.
//  Copyright © 2017 Blockstack. All rights reserved.
//

import Cocoa
import Sparkle
import os.log
import ServiceManagement

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {


    let productionModePortalPort = 8888
    let developmentModePortalPort = 3000
    let corsProxyPort = 1337
    let portalAuthenticationPath = "/auth?authRequest="

    var statusItem : NSStatusItem = NSStatusItem()

    var isDevModeEnabled : Bool = false
    var isBetaModeEnabled : Bool = false

    var isRegTestModeEnabled : Bool = false
    var isRegTestModeChanging : Bool = false
    let regTestCoreAPIPassword = "blockstack_integration_test_api_password"

    var isShutdown : Bool = false

    let keychainServiceName = "blockstack-core-wallet-password"
    let keychainAccountName = "blockstack-core"

    let portalRunDirectory = "portal"
    let launcherBundleIdentifier = "org.blockstack.macLauncher"
    
    let startOnLogInUserDefaultKey = "StartOnLogIn"

    let portalProxyProcess = Process()
    let corsProxyProcess = Process()

    let sparkleUpdater = SUUpdater.init(for: Bundle.main)

    var portalLogServer:PortalLogServer? = nil
    let logServerPort = 8333

    let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "Default")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // This must be registered before `applicationDidFinishLaunching` otherwise the event
        // may not be triggered if Blockstack.app was not already running.
        let appleEventManager = NSAppleEventManager.shared()
        appleEventManager.setEventHandler(self, andSelector: #selector(handleGetURLEvent), forEventClass: UInt32(kInternetEventClass), andEventID: UInt32(kAEGetURL))
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        os_log("applicationDidFinishLaunching: %{public}@", log: log, type: .default, blockstackDataURL().absoluteString)

        // portalLogServer = PortalLogServer.init(port: UInt16(logServerPort), password: self.createOrRetrieveCoreWalletPassword())

        // register initial user default values
        registerInitialUserDefaults()
        
        // configure to start at login
        configureStartOnLogIn(enabled: isUserDefaultSetToStartOnLogin(), writeDefaults: false)
        
        // kill launcher service if started at login
        var startedAtLogin = false
        if !NSRunningApplication.runningApplications(withBundleIdentifier: launcherBundleIdentifier).isEmpty {
            startedAtLogin = true
            killLauncher()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(named: NSImage.Name(rawValue: "MenuBar"))
            button.alternateImage = NSImage(named: NSImage.Name(rawValue: "MenuBarDark"))
            button.action = #selector(statusItemClick)
        }

        // using the wallet password as Core API password is intentional
        startPortalProxy(complete: {
            if !startedAtLogin {
                let delayInSeconds = 0.5
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delayInSeconds) {
                    self.openPortal(path: "/")
                }
            }
        })

        startCorsProxy(complete: {
            // do nothing on task completion
        })
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        shutdown(terminate: false)
    }

    func configureStartOnLogIn(enabled: Bool, writeDefaults: Bool = true) {
        if SMLoginItemSetEnabled(launcherBundleIdentifier as CFString, enabled) {
            os_log("Launcher login item set successfully", log: log, type: .debug)
        }
        else {
            os_log("Failed to set launcher login item", log: log, type: .debug)
        }
        
        if writeDefaults {
            setUserDefaultStartOnLogIn(enabled: enabled)
        }
    }
    
    func registerInitialUserDefaults() {
        let userDefaults = [
            startOnLogInUserDefaultKey: true
        ]
        UserDefaults.standard.register(defaults: userDefaults)
    }
    
    func isUserDefaultSetToStartOnLogin() -> Bool {
        return UserDefaults.standard.bool(forKey: startOnLogInUserDefaultKey)
    }
    
    func setUserDefaultStartOnLogIn(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: startOnLogInUserDefaultKey)
    }
    
    func killLauncher() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("kill"), object: Bundle.main.bundleIdentifier, options: DistributedNotificationCenter.Options.deliverImmediately)
    }
    
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {

        var senderAppUrl : URL? = nil
        let senderAppName = event.attributeDescriptor(forKeyword: keyAddressAttr)?.stringValue
        // This `keyOriginalAddressAttr` seems to always match `keyAddressAttr`..
        // Leaving this here for later debugging if needed.
        // let senderAppName = event.attributeDescriptor(forKeyword: keyOriginalAddressAttr)?.stringValue
        
        if senderAppName != nil {
            if let senderAppPath = NSWorkspace.shared.fullPath(forApplication: senderAppName!) {
                senderAppUrl = URL.init(fileURLWithPath: senderAppPath)
                os_log("Blockstack Auth Request came from app: %{public}@", log: log, type: .info, senderAppPath)
            } else {
                os_log("Blockstack Auth Request sender not mapped to an app: %{public}@", log: log, type: .info, senderAppName!)
            }
        } else {
            os_log("Blockstack Auth Request sender not mapped to an app: %{public}@", log: log, type: .info, "keyAddressAttr not provided")
        }
        
        let url = (event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue) ?? ""
        let authRequest = url.replacingOccurrences(of: "blockstack:", with: "")
        os_log("Blockstack URL: %{public}@", log: log, type: .info, url)
        os_log("Blockstack Auth Request: %{public}@", log: log, type: .debug, authRequest)

        openPortal(path: "\(portalAuthenticationPath)\(authRequest)", openWithApplication: senderAppUrl)

    }

    func portalBaseUrl() -> String {
        if (isBetaModeEnabled) {
            return "https://beta.browser.blockstack.org"
        } 
        else {
            return "http://localhost:\(portalPort())"
        }
    }

    func portalPort() -> Int {
        return isDevModeEnabled ? developmentModePortalPort : productionModePortalPort
    }

    @objc func openPortalClick(sender: AnyObject?) {
        os_log("openPortalClick", log: log, type: .debug)
        openPortal(path: "/")
    }

    @objc func openProfilesClick(sender: AnyObject?) {
        os_log("openProfilesClick", log: log, type: .debug)
        openPortal(path: "/profiles")
    }

    func openStorageClick(sender: AnyObject?) {
        os_log("openStorageClick", log: log, type: .debug)
        openPortal(path: "/account/storage")
    }

    @objc func openWalletClick(sender: AnyObject?) {
        os_log("openWalletClick", log: log, type: .debug)
        openPortal(path: "/wallet/receive")
    }

    @objc func openAccountClick(sender: AnyObject?) {
        os_log("openAccountClick", log: log, type: .debug)
        openPortal(path: "/account")
    }
    
    func openPortal(path: String, openWithApplication: URL? = nil) {
        let portalURLString = "\(portalBaseUrl())\(path)"
        os_log("Opening portal with String: %{public}@", log: log, type: .info, portalURLString)
        let portalURLWithSecretString = "\(portalURLString)#coreAPIPassword=\(createOrRetrieveCoreWalletPassword())"
        let portalURLWithSecretAndLogPortString = "\(portalURLWithSecretString)&logServerPort=\(logServerPort)"
        let portalURLWithSecretLogPortAndRegtest = "\(portalURLWithSecretAndLogPortString)&regtest=\(isRegTestModeEnabled ? 1 : 0)"
        let portalURL = URL(string: portalURLWithSecretLogPortAndRegtest)
        
        if (openWithApplication != nil) {
            do {
                try NSWorkspace.shared.open(
                    [portalURL!],
                    withApplicationAt: openWithApplication!,
                    options: .default,
                    configuration: [:]
                )
            } catch {
                os_log("Error opening URL with app: %{public}@", log: log, type: .error, openWithApplication!.absoluteString)
                NSWorkspace.shared.open(portalURL!)
            }
        } else {
            NSWorkspace.shared.open(portalURL!)
        }
        
    }

    @objc func statusItemClick(sender: AnyObject?) {
        os_log("statusItemClick", log: log, type: .debug)

        let menu = NSMenu()

        var showExpandedMenu = false

        if(NSApp.currentEvent?.modifierFlags.contains(NSEvent.ModifierFlags.option) ?? false) {
            os_log("Option click", log: log, type: .debug)
            showExpandedMenu = true
        }

        if isDevModeEnabled {
            showExpandedMenu = true
        }

        menu.addItem(withTitle: "Home", action: #selector(openPortalClick), keyEquivalent: "h")
        menu.addItem(withTitle: "IDs", action: #selector(openProfilesClick), keyEquivalent: "i")
        menu.addItem(withTitle: "Wallet", action: #selector(openWalletClick), keyEquivalent: "w")
        menu.addItem(withTitle: "Settings", action: #selector(openAccountClick), keyEquivalent: "s")
        menu.addItem(NSMenuItem.separator())

        if showExpandedMenu {

            let portalPortMenuItem = NSMenuItem()
            portalPortMenuItem.title = "Browser running on port \(portalPort())"
            portalPortMenuItem.isEnabled = false
            menu.addItem(portalPortMenuItem)

            let corsProxyPortMenuItem = NSMenuItem()
            corsProxyPortMenuItem.title = "CORS proxy running on port \(corsProxyPort)"
            corsProxyPortMenuItem.isEnabled = false
            menu.addItem(corsProxyPortMenuItem)

            if(isDevModeEnabled) {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "Copy Log Server API password", action: #selector(copyAPIKeyClick), keyEquivalent: "")
            }

            menu.addItem(NSMenuItem.separator())

            if (!isBetaModeEnabled) {
                let devModeStatusMenuItem = NSMenuItem()
                devModeStatusMenuItem.title = "Development Mode: \(isDevModeEnabled ? "Enabled" : "Disabled")"
                devModeStatusMenuItem.isEnabled = false
                menu.addItem(devModeStatusMenuItem)

                let devModeMenuItem = NSMenuItem()
                devModeMenuItem.title = "\(isDevModeEnabled ? "Disable" : "Enable") Development Mode"

                if(!isRegTestModeEnabled && !isRegTestModeChanging) {
                    devModeMenuItem.action = #selector(devModeClick)
                    devModeMenuItem.keyEquivalent = "d"
                }

                menu.addItem(devModeMenuItem)
            }

            if (!isDevModeEnabled) {
                let betaModeStatusMenuItem = NSMenuItem()
                betaModeStatusMenuItem.title = "Beta Mode: \(isBetaModeEnabled ? "Enabled" : "Disabled")"
                betaModeStatusMenuItem.isEnabled = false
                menu.addItem(betaModeStatusMenuItem)

                let betaModeMenuItem = NSMenuItem()
                betaModeMenuItem.title = "\(isBetaModeEnabled ? "Disable" : "Enable") Beta Mode"

                betaModeMenuItem.action = #selector(betaModeClick)
                betaModeMenuItem.keyEquivalent = "b"

                menu.addItem(betaModeMenuItem)
            }

            menu.addItem(NSMenuItem.separator())

            let regTestModeStatusMenuItem = NSMenuItem()
            regTestModeStatusMenuItem.title = "Regtest Mode: \(isRegTestModeEnabled ? "Enabled" : "Disabled")"
            menu.addItem(regTestModeStatusMenuItem)

            if(isDevModeEnabled) {
                let regTestModeMenuItem = NSMenuItem()
                regTestModeMenuItem.title = "\(isRegTestModeEnabled ? "Disable" : "Enable") Regtest Mode"

                if(!isRegTestModeChanging) {
                    regTestModeMenuItem.action = #selector(regTestModeClick)
                    regTestModeMenuItem.keyEquivalent = "r"
                }

                menu.addItem(regTestModeMenuItem)
            }


            menu.addItem(NSMenuItem.separator())

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String

            let versionMenuItem = NSMenuItem()
            versionMenuItem.title = "Blockstack v\(version) (\(build))"
            versionMenuItem.isEnabled = false
            menu.addItem(versionMenuItem)
            menu.addItem(withTitle: "Check for updates...", action: #selector(checkForUpdatesClick), keyEquivalent: "u")

            menu.addItem(NSMenuItem.separator())
        }

        menu.addItem(withTitle: "Quit Blockstack", action: #selector(exitClick), keyEquivalent: "q")

        statusItem.popUpMenu(menu)
    }

    @objc func copyAPIKeyClick(sender: AnyObject?) {
        os_log("copyAPIKeyClick", log: log, type: .debug)
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
        if(isRegTestModeEnabled) {
            os_log("copying regtest core api password", log: log, type: .debug)
            pasteboard.setString(regTestCoreAPIPassword, forType: NSPasteboard.PasteboardType.string)
        } else {
            os_log("copying production core api password", log: log, type: .debug)
            pasteboard.setString(createOrRetrieveCoreWalletPassword(), forType: NSPasteboard.PasteboardType.string)
        }
    }

    @objc func devModeClick(sender: AnyObject?) {
        os_log("devModeClick", log: log, type: .debug)
        isDevModeEnabled = !isDevModeEnabled
    }

    @objc func betaModeClick(sender: AnyObject?) {
        os_log("betaModeClick", log: log, type: .debug)
        if (!isBetaModeEnabled) {
            openPortal(path: "/go-to-beta")
        }
        isBetaModeEnabled = !isBetaModeEnabled
    }
    
    @objc func regTestModeClick(sender: AnyObject?) {
        os_log("regTestModeClick", log: log, type: .debug)
        if(!isRegTestModeChanging) {
            isRegTestModeChanging = true
            os_log("Stopping log server...", log: log, type: .debug)
            portalLogServer?.server.stop()
            if(!isRegTestModeEnabled) {
                self.isRegTestModeChanging = false
                self.isRegTestModeEnabled = true
                os_log("Restarting log server with new API password", log: self.log, type: .debug)
                self.portalLogServer = PortalLogServer.init(port: UInt16(self.logServerPort), password: self.createOrRetrieveCoreWalletPassword())
            } else {
                os_log("Exiting reg test mode...", log: log, type: .debug)
                self.isRegTestModeChanging = false
                self.isRegTestModeEnabled = false
                
                os_log("Stopping log server...", log: log, type: .debug)
                portalLogServer?.server.stop()
                let walletPassword = createOrRetrieveCoreWalletPassword()
                os_log("Restarting log server with new API password", log: self.log, type: .debug)
                self.portalLogServer = PortalLogServer.init(port: UInt16(self.logServerPort), password: walletPassword)

            }
        } else {
            os_log("Regtest mode is already changing. Doing nothing.", log: log, type: .debug)
        }
    }


    @objc func exitClick(sender: AnyObject?) {
        os_log("exitClick", log: log, type: .debug)

        let alert = NSAlert()

        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.messageText = "Quit Blockstack?"
        alert.informativeText = "You will not be able to access the decentralized internet if you quit Blockstack."
        alert.alertStyle = NSAlert.Style.warning

        let startOnLoginCheckbox = NSButton.init(checkboxWithTitle: "Start Blockstack when logging back in", target: self, action: #selector(handleStartOnLogInCheckboxClick))
        startOnLoginCheckbox.state = isUserDefaultSetToStartOnLogin() ? NSControl.StateValue.on : NSControl.StateValue.on
        alert.accessoryView = startOnLoginCheckbox
        
        if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
            os_log("User decided to exit...", log: log, type: .info)
            shutdown(terminate: true)
        }
    }
    
    @objc func handleStartOnLogInCheckboxClick(sender: NSButton) {
        if sender.state == NSControl.StateValue.on {
            os_log("startOnLogInCheckboxClick On", log: log, type: .debug)
            configureStartOnLogIn(enabled: true)
        }
        else {
            os_log("startOnLogInCheckboxClick Off", log: log, type: .debug)
            configureStartOnLogIn(enabled: false)
        }
    }

    @objc func checkForUpdatesClick(sender: AnyObject?) {
        os_log("checkForUpdatesClick", log: log, type: .debug)
        sparkleUpdater?.checkForUpdates(nil)
    }

    func shutdown(terminate: Bool = true) {
        if(!isShutdown) {
            isShutdown = true // prevent shutdown code from running twice
            NSStatusBar.system.removeStatusItem(statusItem)

            portalProxyProcess.terminate()
            os_log("Blockstack Portal proxy terminated", log: log, type: .default)

            corsProxyProcess.terminate()
            os_log("CORS proxy terminated", log: log, type: .default)
            
            os_log("Goodbye!", log: self.log, type: .default)
            NSApplication.shared.terminate(self)
        }
    }

    func startPortalProxy(complete: @escaping () -> Void) {
        let nodeBinPath = Bundle.main.path(forResource: "node", ofType: "", inDirectory: "server")
        let proxyPath = Bundle.main.path(forResource: "blockstackProxy.js", ofType: "", inDirectory: "server")
        let portalPath = Bundle.main.path(forResource: "browser", ofType: "")

        os_log("Portal proxy path: %{public}@", log: log, type: .info, proxyPath!)
        os_log("Portal path: %{public}@", log: log, type: .info, portalPath!)

        do {
            os_log("Trying to remove any existing portal code...", log: log, type: .info)
            try FileManager.default.removeItem(atPath: portalRunPath())
        } catch {
            os_log("Can't remove existing portal code. It probably doesn't exist.", log: log, type: .info)
        }

        os_log("Copying the latest portal code into the portal run path %{public}@", log: log, type: .info, portalRunPath())

        do {
            try FileManager.default.copyItem(atPath: portalPath!, toPath: portalRunPath())
        } catch {
            os_log("Can't copy Portal code to the run path: %{public}@", log: log, type: .error, portalRunPath())
        }

        self.portalProxyProcess.launchPath = nodeBinPath

        self.portalProxyProcess.arguments = [proxyPath!, String(self.productionModePortalPort), self.portalRunPath()]

        os_log("Starting Blockstack Portal proxy...", log: log, type: .default)
        
        let stdErrorPipe = Pipe()
        self.portalProxyProcess.standardError = stdErrorPipe
        self.portalProxyProcess.terminationHandler = {
            task in
            DispatchQueue.main.async(execute: {
                let errorData = stdErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = NSString(data: errorData, encoding: String.Encoding.utf8.rawValue)! as String
                let alert = NSAlert()
                alert.messageText = "Blockstack Error: Portal server was terminated"
                alert.informativeText = errorString
                alert.alertStyle = NSAlert.Style.warning
                alert.runModal()
            })
        }
        
        self.portalProxyProcess.launch()
        complete()

    }

    func startCorsProxy(complete: @escaping () -> Void) {
        let nodeBinPath = Bundle.main.path(forResource: "node", ofType: "", inDirectory: "server")
        let corsProxyPath = Bundle.main.path(forResource: "corsproxy.js", ofType: "", inDirectory: "server")

        os_log("CORS proxy Path: %{public}@", log: log, type: .info, corsProxyPath!)

        corsProxyProcess.arguments = [corsProxyPath!]
        corsProxyProcess.launchPath = nodeBinPath

        os_log("Starting CORS proxy...", log: log, type: .default)

        let stdErrorPipe = Pipe()
        corsProxyProcess.standardError = stdErrorPipe
        corsProxyProcess.terminationHandler = {
            task in
            DispatchQueue.main.async(execute: {
                let errorData = stdErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = NSString(data: errorData, encoding: String.Encoding.utf8.rawValue)! as String
                let alert = NSAlert()
                alert.messageText = "Blockstack Error: CORS proxy was terminated"
                alert.informativeText = errorString
                alert.alertStyle = NSAlert.Style.warning
                alert.runModal()
            })
        }
        
        corsProxyProcess.launch()
        complete()
    }

   


    func portalRunPath() -> String {
        return blockstackDataURL().path + "/\(portalRunDirectory)"
    }

    func blockstackDataURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        os_log("Application Support directory: %{public}@", log: log, type: .debug, applicationSupportDirectory.absoluteString)

        let blockstackDataPath = applicationSupportDirectory.appendingPathComponent("Blockstack")

        os_log("Blockstack data directory: %{public}@", log: log, type: .debug, blockstackDataPath.absoluteString)

        do {
            try FileManager.default.createDirectory(atPath: blockstackDataPath.path, withIntermediateDirectories: false, attributes: nil)
        } catch {
            os_log("Blockstack data directory probably already exists", log: log, type: .debug)
        }

        return blockstackDataPath
    }


    /* Keychain management of Blockstack Core wallet password */

    func createOrRetrieveCoreWalletPassword() -> String {
        os_log("createOrRetrieveCoreWalletPassword", log: log, type: .debug)
        if(isRegTestModeEnabled && !isRegTestModeChanging) {
            return regTestCoreAPIPassword
        }
        
        return generatePassword()

        let serviceNameData = (keychainServiceName as NSString).utf8String
        let accountNameData = (keychainAccountName as NSString).utf8String

        var passwordLength : UInt32 = 0
        var passwordData : UnsafeMutableRawPointer? = nil

        var unmanagedItem : SecKeychainItem? = nil

        let keychains : CFTypeRef? = nil // use the default keychain


        let status = SecKeychainFindGenericPassword(keychains, UInt32(strlen(serviceNameData!)), serviceNameData, UInt32(strlen(accountNameData!)), accountNameData, &passwordLength, &passwordData, &unmanagedItem)
        if(status == errSecSuccess) {
            let password = String(NSString(bytes: UnsafeMutableRawPointer(passwordData)!, length: Int(passwordLength), encoding: String.Encoding.utf8.rawValue)!)
            SecKeychainItemFreeContent(nil, passwordData) // free memory
            os_log("Blockstack Core wallet password found in keychain", log: log, type: .info)
            return password
        } else {
            os_log("Blockstack Core wallet password not found in keychain: %{public}@", log: log, type: .info, SecCopyErrorMessageString(status, nil) as! CVarArg)
            SecKeychainItemFreeContent(nil, passwordData) // free memory

            return createAndStorePasswordInKeychain()
        }
    }

    func createAndStorePasswordInKeychain() -> String {
        os_log("createAndStorePasswordInKeychain", log: log, type: .debug)
        let serviceNameData = (keychainServiceName as NSString).utf8String
        let accountNameData = (keychainAccountName as NSString).utf8String

        let password : String = generatePassword()
        let passwordData = (password as NSString).utf8String

        var unmanagedItem : SecKeychainItem? = nil

        let keychains : SecKeychain? = nil // use the default keychain

        os_log("Storing new password in Keychain: service name: %{public} account name: %{public}@", keychainServiceName, keychainAccountName)
        let status = SecKeychainAddGenericPassword(keychains, UInt32(strlen(serviceNameData!)), serviceNameData, UInt32(strlen(accountNameData!)), accountNameData, UInt32(strlen(passwordData!)), passwordData!, &unmanagedItem)

        if(status != errSecSuccess) {
            os_log("Problem storing Blockstack Core wallet password to Keychain %{public}@", log: log, type: .error, (SecCopyErrorMessageString(status, nil) as! CVarArg))
        }

        return password
    }

    func generatePassword() -> String {
        os_log("generatePassword", log: log, type: .debug)
        // this isn't necessarily secure or random, but good enough for our purposes.
        return ProcessInfo.processInfo.globallyUniqueString
    }

    func loggingPipe() -> Pipe {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { pipe in

            if let line = String(data: pipe.availableData, encoding: String.Encoding.utf8) {
                os_log("%{public}@", log: self.log, type: .debug, line)
            } else {
                os_log("Error decoding data: %{public}@", log: self.log, type: .error, pipe.availableData as CVarArg)
            }
        }
        return pipe
    }



}
