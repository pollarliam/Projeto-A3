//
//  Item.swift
//  whereto-Swift
//
//  Created by Ramael Cerqueira on 2025/10/8.
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
