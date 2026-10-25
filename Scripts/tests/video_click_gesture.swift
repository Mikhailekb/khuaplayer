import Foundation

@main
@MainActor
struct VideoClickGestureChecks {
    static var checks = 0
    static let origin = CGPoint(x: 100, y: 200)
    static let pointer = CGPoint(x: 500, y: 600)

    static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        precondition(condition(), description)
    }

    static func down(_ gesture: inout SPVideoClickGesture, count: Int = 1,
                     eligible: Bool = true) {
        gesture.mouseDown(clickCount: count, eligible: eligible,
                          windowOrigin: origin, pointer: pointer)
    }

    static func up(_ gesture: inout SPVideoClickGesture,
                   sameWindow: Bool = true, origin: CGPoint = origin,
                   pointer: CGPoint = pointer) -> SPVideoClickGesture.Token? {
        gesture.mouseUp(sameWindow: sameWindow, windowOrigin: origin, pointer: pointer)
    }

    static func main() {
        var gesture = SPVideoClickGesture()
        expect(up(&gesture) == nil, "A release without a video press does nothing")
        down(&gesture)
        let first = up(&gesture)
        expect(first != nil, "An ordinary video click is available on release")
        expect(gesture.consume(first!), "The release commits synchronously without a timer or another input")
        expect(up(&gesture) == nil, "Monitor and responder release delivery cannot toggle twice")
        expect(!gesture.consume(first!), "The same release cannot be consumed twice")

        down(&gesture)
        let beforeDouble = up(&gesture)!
        var toggles = gesture.consume(beforeDouble) ? 1 : 0
        expect(toggles == 1, "The first click acts immediately even when a double click will follow")
        down(&gesture, count: 2)
        if let token = up(&gesture), gesture.consume(token) { toggles += 1 }
        expect(toggles == 1, "The second click enters fullscreen without adding another playback toggle")
        expect(!gesture.consume(beforeDouble), "Fullscreen does not replay or roll back the completed first click")
        down(&gesture, count: 3)
        expect(up(&gesture) == nil, "A triple click does not leave an extra playback action")

        down(&gesture)
        gesture.mouseDragged(windowOrigin: origin, pointer: CGPoint(x: 506, y: 600))
        expect(up(&gesture) == nil, "A drag is not a video click, even after returning to its starting point")
        down(&gesture)
        expect(up(&gesture, pointer: CGPoint(x: 503, y: 603)) == nil,
               "The movement threshold uses radial displacement")
        down(&gesture)
        let jitter = up(&gesture, pointer: CGPoint(x: 504, y: 600))
        expect(jitter != nil && gesture.consume(jitter!), "Small pointer jitter is still a click")
        down(&gesture)
        expect(up(&gesture, origin: CGPoint(x: 101, y: 200)) == nil,
               "Native window movement suppresses playback regardless of pointer displacement")
        down(&gesture)
        gesture.mouseDragged(windowOrigin: CGPoint(x: 101, y: 200), pointer: pointer)
        expect(up(&gesture) == nil, "A window dragged back to its original position remains a drag")
        down(&gesture)
        expect(up(&gesture, sameWindow: false) == nil, "Releasing in a different window does nothing")

        down(&gesture, eligible: false)
        expect(up(&gesture) == nil, "Control-click, controls and absent media are ineligible")
        down(&gesture)
        let cancelled = up(&gesture)!
        gesture.cancel()
        expect(!gesture.consume(cancelled), "Session, focus, panel and gesture cancellation invalidate an unconsumed release")
        down(&gesture)
        gesture.cancel()
        expect(up(&gesture) == nil, "Cancellation also removes an unfinished press")

        down(&gesture)
        let superseded = up(&gesture)!
        down(&gesture)
        let current = up(&gesture)!
        expect(!gesture.consume(superseded), "An old release cannot consume a newer click")
        expect(gesture.consume(current), "Only the current click can commit")
        down(&gesture)
        let supersededByControl = up(&gesture)!
        down(&gesture, eligible: false)
        expect(!gesture.consume(supersededByControl), "A new control press cancels an unconsumed surface release")
        expect(up(&gesture) == nil, "The control release does not inherit the earlier video press")
        print("Video click gesture checks passed (\(checks) assertions).")
    }
}
