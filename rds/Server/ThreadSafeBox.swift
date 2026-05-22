//
//  ThreadSafeBox.swift
//  MacRDP
//
//  Tiny lock-protected reference container, used where we need to
//  share a Swift object between the @MainActor side (session
//  lifecycle) and a non-MainActor side (bridge callbacks) without
//  paying a Task hop on every event.
//

import Foundation

final class ThreadSafeBox<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
