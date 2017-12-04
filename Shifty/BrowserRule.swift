//
//  BrowserRule.swift
//  Shifty
//
//  Created by Enrico Ghirardi on 25/11/2017.
//

import ScriptingBridge
import AXSwift
import PublicSuffix

enum SupportedBrowser : String {
    case Safari = "com.apple.Safari"
    case SafariTechnologyPreview = "com.apple.SafariTechnologyPreview"
    
    case Chrome = "com.google.Chrome"
    case ChromeCanary = "com.google.Chrome.canary"
    case Chromium = "org.chromium.Chromium"
}

var browserObserver: Observer!

//MARK: Safari Scripting Bridge

func getSafariCurrentTabURL(_ processIdentifier: pid_t) -> URL? {
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

extension URL {
    func matchesDomain(domain: String, includeSubdomains: Bool) -> Bool {
        if let self_host = self.host {
            if includeSubdomains {
                var selfHostComponents = self_host.components(separatedBy: ".")
                var targetHostComponents = domain.components(separatedBy: ".")
                let selfComponentsCount = selfHostComponents.count
                let targetComponentsCount = targetHostComponents.count
                let offset = selfComponentsCount - targetComponentsCount
                if offset < 0 {
                    return false
                }
                for i in offset..<selfComponentsCount {
                    if !(selfHostComponents[i] == targetHostComponents[i - offset]) {
                        return false
                    }
                }
                return true
            } else {
                return self_host == domain
            }
        }
        return false
    }
    
    func containsPath(path: String) -> Bool {
        return self.path.range(of: path) != nil
    }
}

struct BrowserRule: CustomStringConvertible, Equatable, Codable {
    var host: String
    var includeSubdomains: Bool
    var isException: Bool
    
    var description: String {
        return "Rule for domain: \(host), include subdomains: \(includeSubdomains), is exception: \(isException)"
    }
    static func ==(lhs: BrowserRule, rhs: BrowserRule) -> Bool {
        return lhs.host == rhs.host && lhs.includeSubdomains == rhs.includeSubdomains && lhs.isException == rhs.isException
    }
}

enum RuleResult {
    case matchDomain
    case matchSubdomain
    case noMatch
}

private func ruleMatchesURL(rule: BrowserRule, url: URL) -> RuleResult {
    if url.matchesDomain(domain: rule.host,
                         includeSubdomains: rule.includeSubdomains) {
        return rule.includeSubdomains ? .matchDomain : .matchSubdomain
    }
    return .noMatch
}

func checkBrowserForRules(browser: SupportedBrowser, processIdentifier: pid_t, rules: [BrowserRule]) -> (String, Bool, String, Bool, Bool) {
    var currentURL: URL? = nil
    var domain: String = ""
    var subdomain: String = ""
    var matchedDomain: Bool = false
    var matchedSubdomain: Bool = false
    var isException: Bool = false
    
    switch browser {
    case .Safari, .SafariTechnologyPreview:
        if let url = getSafariCurrentTabURL(processIdentifier) {
            currentURL = url
        }
    case .Chrome, .ChromeCanary, .Chromium:
        if let url = getChromeCurrentTabURL(processIdentifier) {
            currentURL = url
        }
    }
    
    if let url = currentURL {
        domain = url.registeredDomain ?? ""
        subdomain = url.host ?? ""
        for rule in rules {
            switch ruleMatchesURL(rule: rule, url: url) {
            case .matchDomain:
                matchedDomain = true
                isException = rule.isException
            case .matchSubdomain:
                matchedSubdomain = true
                isException = rule.isException
            case .noMatch:
                continue
            }
        }
    }
    
    return (domain, matchedDomain, subdomain, matchedSubdomain, isException)
}

func startBrowserWatcher(_ processIdentifier: pid_t, callback: @escaping () -> Void) throws {
    if let app = Application(forProcessID: processIdentifier) {
        browserObserver = app.createObserver { (observer: Observer, element: UIElement, event: AXNotification, info: [String: AnyObject]?) in
            if event == .windowCreated {
                do {
                    try browserObserver.addNotification(.titleChanged, forElement: element)
                } catch let error {
                    NSLog("Error: Could not watch [\(element)]: \(error)")
                }
            }
            if event == .titleChanged || event == .focusedWindowChanged {
                DispatchQueue.main.async {
                    callback()
                }
            }
        }
        
        do {
            let windows = try app.windows()!
            for window in windows {
                do {
                    try browserObserver.addNotification(.titleChanged, forElement: window)
                } catch let error {
                    NSLog("Error: Could not watch [\(window)]: \(error)")
                }
            }
        } catch let error {
            NSLog("Error: Could not get windows for \(app): \(error)")
        }
        try browserObserver.addNotification(.focusedWindowChanged, forElement: app)
        try browserObserver.addNotification(.windowCreated, forElement: app)
    }
}

func stopBrowserWatcher() {
    if browserObserver != nil {
        browserObserver.stop()
        browserObserver = nil
    }
}



