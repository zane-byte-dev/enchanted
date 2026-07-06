//
//  Date.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 10/12/2023.
//

import Foundation

extension Date {
    func daysAgoString() -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day], from: self, to: now)
        
        guard let daysAgo = components.day else {
            return "Today"
        }
        
        switch daysAgo {
        case 0:
            return "Today"
        case 1:
            return "1 day ago"
        default:
            return "\(daysAgo) days ago"
        }
    }

    /// Compact relative time for sidebar rows, e.g. "now", "6d", "1w", "2mo".
    func shortAgoString() -> String {
        let seconds = max(0, Date().timeIntervalSince(self))
        let minute = 60.0, hour = 3600.0, day = 86400.0, week = 604800.0, month = 2592000.0, year = 31536000.0
        switch seconds {
        case ..<minute:  return "now"
        case ..<hour:    return "\(Int(seconds / minute))m"
        case ..<day:     return "\(Int(seconds / hour))h"
        case ..<week:    return "\(Int(seconds / day))d"
        case ..<month:   return "\(Int(seconds / week))w"
        case ..<year:    return "\(Int(seconds / month))mo"
        default:         return "\(Int(seconds / year))y"
        }
    }
}
