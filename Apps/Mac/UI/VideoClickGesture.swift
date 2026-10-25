import Foundation
import CoreGraphics

/// A surface click is available immediately when the pointer is released.
/// Tokens let the event monitor and responder consume that release only once.
struct SPVideoClickGesture {
    typealias Token = UInt64
    static let movementTolerance: CGFloat = 4

    private var candidate: (windowOrigin: CGPoint, pointer: CGPoint)?
    private var generation: Token = 0
    private var pending: Token?

    mutating func mouseDown(clickCount: Int, eligible: Bool,
                            windowOrigin: CGPoint, pointer: CGPoint) {
        cancel()
        guard eligible, clickCount == 1 else { return }
        candidate = (windowOrigin, pointer)
    }

    mutating func mouseDragged(windowOrigin: CGPoint, pointer: CGPoint) {
        guard let candidate else { return }
        if moved(from: candidate, windowOrigin: windowOrigin, pointer: pointer) {
            cancel()
        }
    }

    mutating func mouseUp(sameWindow: Bool, windowOrigin: CGPoint,
                          pointer: CGPoint) -> Token? {
        guard let candidate else { return nil }
        self.candidate = nil
        guard sameWindow,
              !moved(from: candidate, windowOrigin: windowOrigin, pointer: pointer) else {
            cancel()
            return nil
        }
        generation &+= 1
        pending = generation
        return generation
    }

    mutating func consume(_ token: Token) -> Bool {
        guard pending == token else { return false }
        pending = nil
        return true
    }

    mutating func cancel() {
        candidate = nil
        pending = nil
        generation &+= 1
    }

    private func moved(from candidate: (windowOrigin: CGPoint, pointer: CGPoint),
                       windowOrigin: CGPoint, pointer: CGPoint) -> Bool {
        windowOrigin != candidate.windowOrigin ||
            hypot(pointer.x - candidate.pointer.x, pointer.y - candidate.pointer.y) > Self.movementTolerance
    }
}
