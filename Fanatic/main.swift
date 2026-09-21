//
//  main.swift
//  Fanatic
//
//  Explicit entry point. There is no MainMenu nib for NSApplicationMain to
//  build the delegate from, so the app assembles itself here.
//

import AppKit

// NSApplication references its delegate weakly: this binding is what keeps the
// delegate alive for the lifetime of the process.
let delegate = AppDelegate()

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = delegate
    application.run()
}
