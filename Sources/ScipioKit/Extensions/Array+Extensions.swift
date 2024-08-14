//
//  Array+Extensions.swift
//
//
//  Created by Evan Coleman on 8/13/24.
//

import Foundation

public extension Array where Element: Hashable {

    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        
        return filter { seen.insert($0).inserted }
    }
}
