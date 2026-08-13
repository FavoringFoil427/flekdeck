//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    // Registration runs on whichever queue the extension request completes on,
    // while unregistration and the queries run on the main thread. Mutating a
    // Swift array from two threads at once corrupts it, so every access to the
    // list goes through this lock.
    static private let lock = NSLock()

    @objc class func registerMultitaskContainer(container: String) {
        lock.lock()
        defer { lock.unlock() }
        usingMultitaskContainers.append(container)
    }

    @objc class func unregisterMultitaskContainer(container: String) {
        lock.lock()
        defer { lock.unlock() }
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
    }

    @objc class func isUsing(container: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }

    @objc class func isMultitasking() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingMultitaskContainers.count > 0
    }
}
