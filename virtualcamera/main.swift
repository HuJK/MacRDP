//
//  main.swift
//  virtualcamera
//
//  Created by hujk on 2026/5/26.
//

import Foundation
import CoreMediaIO

let providerSource = virtualcameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
