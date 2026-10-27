// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors

import HTTP3

@available(anyAppleOS 27, *)
public struct ReceivedGoawayEvent: Sendable, Hashable {
    public let id: HTTP3GoawayID

    public init(id: HTTP3GoawayID) {
        self.id = id
    }
}
