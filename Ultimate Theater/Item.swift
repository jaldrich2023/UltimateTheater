//
//  Item.swift
//  Ultimate Theater
//
//  Created by John Aldrich on 10/21/26.
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
