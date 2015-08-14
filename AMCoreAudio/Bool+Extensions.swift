//
//  Bool+Boolean.swift
//  AMCoreAudio
//
//  Created by Ruben on 7/9/15.
//  Copyright © 2015 9Labs. All rights reserved.
//

import Foundation

extension Bool {
    init<T : IntegerType>(_ integer: T){
        self.init(integer != 0)
    }
}
