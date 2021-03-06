//
//  BrowserRule.swift
//  Shifty
//
//  Created by Enrico Ghirardi on 25/11/2017.
//

import ScriptingBridge
import AXSwift
import PublicSuffix
import SwiftLog

enum SupportedBrowser : String {
    case Safari = "com.apple.Safari"
    case SafariTechnologyPreview = "com.apple.SafariTechnologyPreview"
    
    case Chrome = "com.google.Chrome"
    case ChromeCanary = "com.google.Chrome.canary"
    case Chromium = "org.chromium.Chromium"
    case Vivaldi = "com.vivaldi.Vivaldi"
}

enum BrowserError : Error {
    case BrowserAXError
}

var browserObserver: Observer!

//MARK: Safari Scripting Bridge

func getSafariCurrentTabURL(_ processIdentifier: pid_t) -> URL? {
    if let axapp = Application(forProcessID: processIdentifier) {
        do {
            // Special fullscreen win
            guard let axwin: UIElement = try axapp.attribute(.focusedWindow) else { throw BrowserError.BrowserAXError }
            guard let axwin_children: [UIElement] = try axwin.arrayAttribute(.children) else { throw BrowserError.BrowserAXError }
            switch axwin_children.count {
            case 1:
                var axchild = axwin_children[0]
                for _ in 1...3 {
                    guard let children: [UIElement] = try axchild.arrayAttribute(.children) else { throw BrowserError.BrowserAXError }
                    if !children.isEmpty {
                        axchild = children[0]
                    }
                }
                return try axchild.attribute("AXURL")
            case 2...7:
                // Standard win
                var filtered = try axwin_children.filter {
                    let role = try $0.role()
                    return role == .splitGroup
                }

                if filtered.count == 1 {
                    let child_lvl1 = filtered[0]
                    guard let children_lvl1: [UIElement] =
                        try child_lvl1.arrayAttribute(.children) else { throw BrowserError.BrowserAXError }
                    filtered = try children_lvl1.filter {
                        let role = try $0.role()
                        return role == .tabGroup
                    }
                    if filtered.count == 1 {
                        var axchild = filtered[0]
                        for _ in 1...3 {
                            guard let children: [UIElement] = try axchild.arrayAttribute(.children) else { throw BrowserError.BrowserAXError }
                            if !children.isEmpty {
                                axchild = children[0]
                            }
                        }
                        guard let children_lvl2: [UIElement] =
                            try axchild.arrayAttribute(.children) else { throw BrowserError.BrowserAXError }
                        filtered = try children_lvl2.filter {
                            let role = try $0.role()
                            return role == Role.init(rawValue: "AXWebArea")
                        }
                        if filtered.count == 1 {
                            return try filtered[0].attribute("AXURL")
                        }
                    }
                }
                fallthrough
            default:
                throw BrowserError.BrowserAXError
            }
        } catch {
            if let app: SafariApplication = SBApplication(processIdentifier: processIdentifier) {
                if let windows = app.windows as? [SafariWindow] {
                    if !windows.isEmpty {
                        if let tab = windows[0].currentTab {
                            if let url = URL(string: tab.URL!) {
                                return url
                            }
                        }
                    }
                }
            }
            return nil
        }
    }
    return nil
}

@objc public protocol SafariApplication {
    @objc optional var windows: SBElementArray { get }
}
extension SBApplication: SafariApplication {}

@objc public protocol SafariWindow {
    @objc optional var currentTab: SafariTab { get } // The current tab.
}
extension SBObject: SafariWindow {}

@objc public protocol SafariTab {
    @objc optional var URL: String { get } // The current URL of the tab.
}
extension SBObject: SafariTab {}

//MARK: Chrome Scripting Bridge

func getChromeCurrentTabURL(_ processIdentifier: pid_t) -> URL? {
    if let app: ChromeApplication = SBApplication(processIdentifier: processIdentifier) {
        if let windows = app.windows as? [ChromeWindow] {
            if !windows.isEmpty {
                if let tab = windows[0].activeTab {
                    if let url = URL(string: tab.URL!) {
                        return url
                    }
                }
            }
        }
    }
    return nil
}

@objc public protocol ChromeApplication {
    @objc optional var windows: SBElementArray { get }
}
extension SBApplication: ChromeApplication {}

@objc public protocol ChromeWindow {
    @objc optional var activeTab: ChromeTab { get } // The current tab.
}
extension SBObject: ChromeWindow {}

@objc public protocol ChromeTab {
    @objc optional var URL: String { get } // The current URL of the tab.
}
extension SBObject: ChromeTab {}

private func isSubdomainOfDomain(subdomain: String, domain: String) -> Bool {
    var subdomainComponents = subdomain.components(separatedBy: ".")
    var domainComponents = domain.components(separatedBy: ".")
    let subdomainComponentsCount = subdomainComponents.count
    let domainComponentsCount = domainComponents.count
    let offset = subdomainComponentsCount - domainComponentsCount
    if offset < 0 {
        return false
    }
    for i in offset..<subdomainComponentsCount {
        if !(subdomainComponents[i] == domainComponents[i - offset]) {
            return false
        }
    }
    return true
}

enum RuleType : String, Codable {
    case Domain
    case Subdomain
}

struct BrowserRule: CustomStringConvertible, Equatable, Codable {
    var type: RuleType
    var host: String
    var enableNightShift: Bool
    
    var description: String {
        return "Rule type; \(type) for host: \(host) enables NightSift: \(enableNightShift)"
    }
    static func ==(lhs: BrowserRule, rhs: BrowserRule) -> Bool {
        return lhs.type == rhs.type
            && lhs.host == rhs.host
            && lhs.enableNightShift == rhs.enableNightShift
    }
}

func getBrowserCurrentTabDomainSubdomain(browser: SupportedBrowser, processIdentifier: pid_t) -> (String, String) {
    var currentURL: URL? = nil
    var domain: String = ""
    var subdomain: String = ""
    
    switch browser {
    case .Safari, .SafariTechnologyPreview:
        if let url = getSafariCurrentTabURL(processIdentifier) {
            currentURL = url
        }
    case .Chrome, .ChromeCanary, .Chromium, .Vivaldi:
        if let url = getChromeCurrentTabURL(processIdentifier) {
            currentURL = url
        }
    }
    
    if let url = currentURL {
        domain = url.registeredDomain ?? ""
        subdomain = url.host ?? ""
    }
    return (domain, subdomain)
}

func subdomainRulesForDomain(domain: String, rules: [BrowserRule]) -> [BrowserRule] {
    return rules.filter {
        ($0.type == .Subdomain) && isSubdomainOfDomain(subdomain: $0.host, domain: domain)
    }
}

func checkForBrowserRules(domain: String, subdomain: String, rules: [BrowserRule]) -> (Bool, Bool, Bool) {
    let disabledDomain = rules.filter {
        $0.type == .Domain && $0.host == domain }.count > 0
    var res: Bool
    var isException: Bool
    if disabledDomain {
        res = (rules.filter {
            $0.type == .Subdomain
                && $0.host == subdomain
                && $0.enableNightShift == true
            }.count > 0)
        isException = res
    } else {
        res = (rules.filter {
            $0.type == .Subdomain
                && $0.host == subdomain
                && $0.enableNightShift == false
            }.count > 0)
        isException = false
    }
    return (disabledDomain, res, isException)
}

func startBrowserWatcher(_ processIdentifier: pid_t, callback: @escaping () -> Void) throws {
    if let app = Application(forProcessID: processIdentifier) {
        browserObserver = app.createObserver { (observer: Observer, element: UIElement, event: AXNotification, info: [String: AnyObject]?) in
            if event == .valueChanged
            {
                DispatchQueue.main.async {
                    callback()
                }
            }
        }
        try browserObserver.addNotification(.valueChanged, forElement: app)
    }
}

func stopBrowserWatcher() {
    if browserObserver != nil {
        browserObserver.stop()
        browserObserver = nil
    }
}



