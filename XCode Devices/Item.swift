//
//  Item.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 22.11.2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
