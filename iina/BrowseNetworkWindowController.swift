//
//  BrowseNetworkWindowController.swift
//  iina
//
//  Created by Rhys Cox on 11/14/2020.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa
import upnpx

class BrowseNetworkWindowController: NSWindowController, NSWindowDelegate, NSBrowserDelegate, UPnPDBObserver {
  private enum ContentType {
    case directory
    case file
  }

  private class Content {
    let object: MediaServer1BasicObject
    let type: ContentType
    let column: Int
    var children: [Content] = []
    var childrenLoading = true

    init(container: MediaServer1BasicObject,
         type: ContentType,
         column: Int) {
      self.object = container
      self.type = type
      self.column = column
    }
  }

  @IBOutlet weak var browserView: NSBrowser!
  @IBOutlet weak var playSelectionMenuItem: NSMenuItem!

  private var devices: [BasicUPnPDevice] = []
  private var currentDevice: BasicUPnPDevice?
  private var loadingDeviceContent = false
  private var deviceContent: [Content] = []
  private var selectedDeviceContent: [Content] = []

  override var windowNibName: NSNib.Name {
    return NSNib.Name("BrowseNetworkWindowController")
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    window?.isMovableByWindowBackground = true
    browserView.backgroundColor = .clear
    browserView.target = self
    browserView.action = #selector(browserCellSelected)
    browserView.sendsActionOnArrowKeys = true

    let version = Utility.iinaVersion().0
    UPnPManager.getInstance()?.ssdp.setUserAgentProduct("iina/\(version)", andOS: "OSX");

    // upnpx's socket breaks if we ever stop searching, so we search once and let it continue updating
    // in the background forever, otherwise an app relaunch is required to browse the network again
    let _ = UPnPManager.getInstance()?.ssdp.searchSSDP
  }

  func reset() {
    UPnPManager.getInstance()?.db.add(self)
    reloadDevices()
  }

  func windowWillClose(_ notification: Notification) {
    devices = []
    currentDevice = nil
    loadingDeviceContent = false
    deviceContent = []
    selectedDeviceContent = []

    UPnPManager.getInstance()?.db.remove(self)
    browserView.reloadColumn(0)
    browserView.loadColumnZero()
  }

  func uPnPDBUpdated(_ sender: UPnPDB!) {
    DispatchQueue.main.async { [weak self] in
      self?.reloadDevices()
    }
  }

  func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
    if let item = item as? BasicUPnPDevice {
      return item.friendlyName
    }

    if let item = item as? Content {
      return item.object.title
    }

    if let item = item as? String {
      return item
    }

    return nil
  }

  func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
    if let item = item as? BasicUPnPDevice, item == currentDevice {
      return deviceContent[index]
    }

    if let item = item as? Content {
      return item.children[index]
    }

    if item != nil {
      fatalError("Unknown state")
    }

    return devices[index]
  }

  func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
    if (item == nil) {
      return devices.count
    }

    if let item = item as? BasicUPnPDevice, item == currentDevice {
      return loadingDeviceContent ? 0 : deviceContent.count
    }

    if let item = item as? Content {
      return item.childrenLoading ? 0 : item.children.count
    }

    return 0
  }

  func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
    if let item = item as? Content {
      return item.type == .file
    }

    return false
  }

  func browser(_ sender: NSBrowser, selectRow row: Int, inColumn column: Int) -> Bool {
    return true
  }

  @objc private func browserCellSelected() {
    playSelectionMenuItem.isEnabled = false

    guard browserView.selectionIndexPaths.count > 0 else {
      return
    }

    let indexPaths = browserView.selectionIndexPaths

    if let item = browserView.item(at: indexPaths[0]) as? BasicUPnPDevice {
      if item == currentDevice {
        return
      }

      if let _ = item as? MediaServer1Device {
        currentDevice = item
        loadingDeviceContent = true
        deviceContent = []
        browserView.reloadColumn(1)
        fetchMediaServerContent()
      }
    } else if let parent = browserView.item(at: indexPaths[0]) as? Content, parent.type == .directory {
      parent.children = []
      parent.childrenLoading = true
      browserView.reloadColumn(parent.column + 1)
      fetchMediaServerContent(parent)
    } else {
      selectedDeviceContent = indexPaths.map {
        browserView.item(at: $0) as? Content
      }.compactMap { $0 }
       .filter { $0.type == .file }

      playSelectionMenuItem.isEnabled = selectedDeviceContent.count > 0
    }
  }

  private func reloadDevices() {
    if let ds = UPnPManager.getInstance()?.db.rootDevices as? [BasicUPnPDevice] {
      devices = ds.filter { (device: BasicUPnPDevice) in
        device.urn == "urn:schemas-upnp-org:device:MediaServer:1"
      }
      browserView.reloadColumn(0)
      browserView.loadColumnZero()
    }
  }

  private func fetchMediaServerContent(_ parent: Content? = nil) {
    guard let mediaServer = currentDevice as? MediaServer1Device else {
      return
    }

    DispatchQueue.global().async { [weak self] in
      var sortCriteria = ""
      let sortCaps = NSMutableString()
      mediaServer.contentDirectory.getSortCapabilities(withOutSortCaps: sortCaps)

      if (sortCaps as String).contains("dc:title") {
        sortCriteria = "+dc:title"
      }

      let result = NSMutableString()
      let numberReturned = NSMutableString()
      let totalMatches = NSMutableString()
      let updateID = NSMutableString()
      var objectId = "0"

      if let parent = parent {
        objectId = parent.object.objectID
      }

      mediaServer.contentDirectory.browse(withObjectID: objectId, browseFlag: "BrowseDirectChildren", filter: "*", startingIndex: "0", requestedCount: "0", sortCriteria: sortCriteria, outResult: result, outNumberReturned: numberReturned, outTotalMatches: totalMatches, outUpdateID: updateID)

      let didl = (result as String).data(using: .utf8)
      let objects = NSMutableArray()
      let parser = MediaServerBasicObjectParser(mediaObjectArray: objects, itemsOnly: false)!
      parser.parse(from: didl)

      let containerObjects = objects.map {
        $0 as? MediaServer1BasicObject
      }.compactMap { $0 }

      let column = parent == nil ? 1 : parent!.column + 1

      let content = containerObjects.map {
        Content(container: $0, type: $0.isContainer ? .directory : .file, column: column)
      }

      DispatchQueue.main.async { [weak self] in
        if parent == nil {
          self?.deviceContent = content
          self?.loadingDeviceContent = false
        } else {
          parent?.children = content
          parent?.childrenLoading = false
        }

        self?.browserView.reloadColumn(column)
      }
    }
  }

  @IBAction private func playSelection(_ sender: Any) {
    let urls = selectedDeviceContent
      .map { ($0.object as? MediaServer1ItemObject)?.uri }
      .compactMap { $0 }
      .map { URL(string: $0) }
      .compactMap { $0 }

    PlayerCore.activeOrNewForMenuAction(isAlternative: false).openURLs(urls)
    window?.close()
  }
}
