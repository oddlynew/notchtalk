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

 @Test func doubleTap() {
  var taps = DoubleTapGesture()
  #expect(!taps.handle(key: true, down: true, now: 1))
  #expect(!taps.handle(key: true, down: false, now: 1.1))
  #expect(taps.handle(key: true, down: true, now: 1.3))
  #expect(!taps.handle(key: true, down: false, now: 1.35))

  // Another key between the taps, a slow second tap, or a held first press never counts.
  #expect(!taps.handle(key: true, down: true, now: 2))
  #expect(!taps.handle(key: true, down: false, now: 2.1))
  #expect(!taps.handle(key: false, down: true, now: 2.15))
  #expect(!taps.handle(key: true, down: true, now: 2.2))
  #expect(!taps.handle(key: true, down: false, now: 2.25))
  #expect(!taps.handle(key: true, down: true, now: 2.7))
  #expect(!taps.handle(key: true, down: false, now: 3.5))
  #expect(!taps.handle(key: true, down: true, now: 3.6))
 }
}
