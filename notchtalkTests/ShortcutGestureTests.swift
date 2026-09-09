import Testing
@testable import notchtalk

struct ShortcutGestureTests {
 @Test func transitions() {

  var gesture = ShortcutGesture()
  #expect(gesture.release() == .none)
  #expect(gesture.press(allowed: true))
  #expect(!gesture.press(allowed: true))
  #expect(gesture.release() == .none)
  #expect(!gesture.threshold())
  #expect(gesture.press(allowed: true))
  #expect(gesture.threshold())
  #expect(!gesture.threshold())
  #expect(gesture.release() == .endHold)
  #expect(gesture.press(allowed: true))
  gesture.cancel()
  #expect(!gesture.threshold())
  #expect(gesture.release() == .none)
  #expect(!gesture.press(allowed: false))
  #expect(!gesture.threshold())
  #expect(gesture.release() == .none)
  #expect(gesture.press(allowed: true))
  #expect(gesture.threshold())
  gesture.cancel()
  #expect(gesture.release() == .none)

  #expect(gesture.press(allowed: true, now: 10))
  #expect(gesture.release(now: 10.79) == .none)
  #expect(gesture.press(allowed: true, now: 20))
  #expect(gesture.release(now: 20.81) == .endHold)

  #expect(gesture.press(allowed: true, now: 30))
  #expect(gesture.release(now: 30.4, holdDelay: 0.3) == .endHold)
  #expect(gesture.press(allowed: true, now: 40))
  #expect(gesture.release(now: 40.9, holdDelay: 1.2) == .none)

 }
}
