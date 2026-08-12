//
//  CombinedView.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 09/01/2023
//  Using Swift 5.0
//  Running on macOS 13.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class CombinedView: NSObject, NSGestureRecognizerDelegate {
    private var groups: [Int: CombinedGroup] = [:]
    
    override init() {
        super.init()
        
        self.migrateIfNeeded()
        
        modules.forEach { (m: Module) in
            m.menuBar.callback = { [weak self] in
                if let s = self, !s.groups.isEmpty {
                    DispatchQueue.main.async(execute: {
                        s.recalculateAll()
                    })
                }
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModuleRearrrange), name: .moduleRearrange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenCombinedModulesPopup), name: .combinedModulesPopup, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModule), name: .toggleModule, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForCombinedGroupsChanged), name: .combinedGroupsChanged, object: nil)
        
        if CombinedGroups.shared.hasGroups() {
            self.reconfigure()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .moduleRearrange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .combinedModulesPopup, object: nil)
        NotificationCenter.default.removeObserver(self, name: .toggleModule, object: nil)
        NotificationCenter.default.removeObserver(self, name: .combinedGroupsChanged, object: nil)
    }
    
    private func migrateIfNeeded() {
        guard !Store.shared.exist(key: "CombinedGroups") else { return }
        guard Store.shared.bool(key: "CombinedModules", defaultValue: false) else { return }
        
        var groups: [String: Int] = [:]
        modules.filter({ $0.enabled }).forEach { (m: Module) in
            groups[m.name] = 1
        }
        CombinedGroups.shared.replace(groups)
        Store.shared.set(key: "CombinedModules", value: false)
    }
    
    private func reconfigure() {
        var desired: [Int: [Module]] = [:]
        modules.filter({ $0.enabled }).forEach { (m: Module) in
            if let id = CombinedGroups.shared.groupID(for: m.name) {
                desired[id, default: []].append(m)
            }
        }
        
        let desiredIDs = Set(desired.keys)
        self.groups.keys.filter({ !desiredIDs.contains($0) }).forEach { id in
            self.groups[id]?.disable()
            self.groups.removeValue(forKey: id)
        }
        
        desired.sorted(by: { $0.key < $1.key }).forEach { (id, mods) in
            if let group = self.groups[id] {
                group.setModules(mods)
            } else {
                let group = CombinedGroup(id: id)
                self.groups[id] = group
                group.setModules(mods)
                group.enable()
            }
        }
    }
    
    private func recalculateAll() {
        self.groups.values.forEach { $0.recalculate() }
    }
    
    private func updateClickHandling() {
        self.groups.values.forEach { $0.updateClickHandling() }
    }
    
    // call when popup appear/disappear
    private func visibilityCallback(_ state: Bool) {}
    
    @objc private func listenForModuleRearrrange() {
        self.recalculateAll()
    }
    
    @objc private func listenCombinedModulesPopup() {
        self.updateClickHandling()
    }
    
    @objc private func listenForModule() {
        self.reconfigure()
    }
    
    @objc private func listenForCombinedGroupsChanged() {
        DispatchQueue.main.async(execute: {
            self.reconfigure()
        })
    }
}

private class CombinedGroup: NSObject {
    let id: Int
    var modules: [Module] = []
    
    private var menuBarItem: NSStatusItem? = nil
    private var view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height))
    private var popup: PopupWindow? = nil
    private let popupView: Popup
    
    private var spacing: CGFloat {
        CGFloat(Int(Store.shared.string(key: "CombinedModules_spacing", defaultValue: "")) ?? 0)
    }
    private var separator: Bool {
        Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
    }
    private var combinedModulesPopup: Bool {
        Store.shared.bool(key: "CombinedModules_popup", defaultValue: true)
    }
    
    init(id: Int) {
        self.id = id
        self.popupView = Popup(modules: [])
        super.init()
        self.popup = PopupWindow(title: "Combined group \(id)", module: .combined, view: self.popupView) { _ in }
    }
    
    func setModules(_ modules: [Module]) {
        self.modules = modules.sorted(by: { $0.combinedPosition < $1.combinedPosition })
        self.popupView.setModules(self.modules)
        self.recalculate()
        self.updateClickHandling()
    }
    
    func enable() {
        guard self.menuBarItem == nil else { return }
        
        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async(execute: {
            self.menuBarItem?.autosaveName = "CombinedGroup-\(self.id)"
        })
        self.menuBarItem?.button?.addSubview(self.view)
        self.menuBarItem?.button?.image = NSImage()
        self.menuBarItem?.button?.toolTip = "\(localizedString("Combined modules")) \(self.id)"
        
        self.updateClickHandling()
        
        DispatchQueue.main.async(execute: {
            self.recalculate()
        })
    }
    
    func disable() {
        self.modules.forEach { (m: Module) in
            m.menuBar.widgets.forEach { w in
                w.item.onClick = nil
            }
        }
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
    }
    
    func recalculate() {
        guard let item = self.menuBarItem else { return }
        
        self.view.subviews.forEach({ $0.removeFromSuperview() })
        
        let visibleModules = self.modules.filter({ !$0.menuBar.activeWidgets.isEmpty })
        var w: CGFloat = 0
        visibleModules.enumerated().forEach { (i, m) in
            if i != 0 {
                w += self.spacing
                if self.separator {
                    self.view.addSubview(SeparatorLineView(frame: NSRect(x: w, y: 3, width: 1, height: Constants.Widget.height-6)))
                    w += 3 + self.spacing
                }
            }
            self.view.addSubview(m.menuBar.view)
            m.menuBar.view.setFrameOrigin(NSPoint(x: w, y: 0))
            w += m.menuBar.view.frame.width
        }
        self.view.setFrameSize(NSSize(width: w, height: self.view.frame.height))
        item.length = w
    }
    
    func updateClickHandling() {
        guard let item = self.menuBarItem else { return }
        
        if !self.combinedModulesPopup {
            self.modules.forEach { (m: Module) in
                m.menuBar.widgets.forEach { w in
                    w.item.onClick = {
                        if let window = w.item.window {
                            NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
                                "module": m.name,
                                "widget": w.type,
                                "origin": window.frame.origin,
                                "center": window.frame.width/2
                            ])
                        }
                    }
                }
            }
            item.button?.action = nil
        } else {
            self.modules.forEach { (m: Module) in
                m.menuBar.widgets.forEach { w in
                    w.item.onClick = nil
                }
            }
            
            item.button?.target = self
            item.button?.action = #selector(self.togglePopup)
            item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }
    
    @objc private func togglePopup() {
        guard let item = self.menuBarItem, let popup = self.popup, let window = item.button?.window else { return }
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        if popup.occlusionState.rawValue == 8192 {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = window.frame.origin.x - windowCenter + window.frame.width/2
            let y = window.frame.origin.y - popup.contentView!.intrinsicContentSize.height - 3
            
            let buttonPoint = NSPoint(x: window.frame.midX, y: window.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonPoint) }) ?? NSScreen.main {
                if x + popup.contentView!.intrinsicContentSize.width > screen.frame.maxX {
                    x = screen.frame.maxX - popup.contentView!.intrinsicContentSize.width - 3
                }
                if x < screen.frame.minX {
                    x = screen.frame.minX + 3
                }
            }
            
            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.setIsVisible(true)
        } else {
            popup.setIsVisible(false)
        }
    }
}

private class SeparatorLineView: NSView {
    override var wantsUpdateLayer: Bool { true }
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (self.isDarkMode ? NSColor.white : NSColor.black).cgColor
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }
}

private class Popup: NSStackView, Popup_p {
    fileprivate var keyboardShortcut: [UInt16] = []
    fileprivate var sizeCallback: ((NSSize) -> Void)? = nil
    private var modules: [Module] = []
    
    init(modules: [Module]) {
        self.keyboardShortcut = Store.shared.array(key: "CombinedModules_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []
        self.modules = modules
        
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .width
        self.spacing = Constants.Popup.spacing*3
        
        self.reinit()
        
        NotificationCenter.default.addObserver(self, selector: #selector(reinit), name: .toggleModule, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleModule, object: nil)
    }
    
    fileprivate func setModules(_ modules: [Module]) {
        self.modules = modules
        self.reinit()
    }
    
    fileprivate func settings() -> NSView? { return nil }
    fileprivate func appear() {}
    fileprivate func disappear() {}
    fileprivate func setKeyboardShortcut(_ binding: [UInt16]) {
        self.keyboardShortcut = binding
        Store.shared.set(key: "CombinedModules_popup_keyboardShortcut", value: binding)
    }
    
    @objc private func reinit() {
        self.subviews.forEach({ $0.removeFromSuperview() })
        
        let availableModules = self.modules.filter({ $0.enabled && $0.portal != nil })
        var modulesHeight: CGFloat = 0
        availableModules.forEach { (m: Module) in
            if let p = m.portal {
                modulesHeight += p.height
                self.addArrangedSubview(p)
            }
        }
        
        let h = modulesHeight + (CGFloat(availableModules.count-1)*self.spacing)
        if h > 0 {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
}
