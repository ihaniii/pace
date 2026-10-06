//
//  PaceTurnLease.swift
//  leanring-buddy
//

import Foundation

/// Identifies one accepted user turn. Async work must still own the active
/// lease before it is allowed to install response work or update turn state.
struct PaceTurnLease: Equatable, Sendable {
    fileprivate let generation: UInt64
    let turnId: String
    /// Where this turn came from. Fixed when the turn is accepted; there is
    /// no way to change it afterwards.
    let origin: PaceTurnOrigin

    init(
        generation: UInt64,
        turnId: String = UUID().uuidString,
        origin: PaceTurnOrigin = .local
    ) {
        self.generation = generation
        self.turnId = turnId
        self.origin = origin
    }

    static func == (lhs: PaceTurnLease, rhs: PaceTurnLease) -> Bool {
        lhs.generation == rhs.generation && lhs.turnId == rhs.turnId && lhs.origin == rhs.origin
    }
}

/// Pure generation gate for rejecting results from cancelled or superseded
/// routing work. CompanionManager owns task cancellation; this type owns the
/// separate truth of whether an async result still belongs to the active turn.
struct PaceTurnLeaseRegistry {
    private var currentGeneration: UInt64 = 0
    /// The origin of the turn that currently owns the lease, or nil when no
    /// turn does. Derived from the lease handed out by `beginTurn`; it is
    /// never set on its own.
    private(set) var currentTurnOrigin: PaceTurnOrigin?

    mutating func beginTurn(origin: PaceTurnOrigin = .local) -> PaceTurnLease {
        currentGeneration &+= 1
        currentTurnOrigin = origin
        return PaceTurnLease(generation: currentGeneration, origin: origin)
    }

    mutating func invalidateCurrentTurn() {
        currentGeneration &+= 1
        currentTurnOrigin = nil
    }

    func isCurrent(_ lease: PaceTurnLease) -> Bool {
        lease.generation == currentGeneration
    }
}
