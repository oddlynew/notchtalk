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
  #expect(gesture.press(allowed: true, now: 5))
  #expect(gesture.threshold())
  #expect(!gesture.threshold())
  #expect(gesture.release(now: 6) == .endHold)
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
  #expect(gesture.release(now: 21) == .endHold)

  // Daniel's 350 ms hold delay, 02.10.2026: a slow tap released at 400 ms stopped the recording after 0.24 s
  // and everything said next was lost. A hold under a second keeps recording like a tap.
  #expect(gesture.press(allowed: true, now: 30))
  #expect(gesture.threshold())
  #expect(gesture.release(now: 30.4, holdDelay: 0.35) == .none)
  #expect(gesture.press(allowed: true, now: 35))
  #expect(gesture.release(now: 35.99, holdDelay: 0.35) == .none)
  #expect(gesture.press(allowed: true, now: 36))
  #expect(gesture.release(now: 37, holdDelay: 0.35) == .endHold)
  #expect(gesture.press(allowed: true, now: 40))
  #expect(gesture.release(now: 40.9, holdDelay: 1.2) == .none)

 }

 @Test func doubleTap() {
  var taps = DoubleTapGesture()
  #expect(!taps.handle(key: true, down: true, now: 1))
  #expect(!taps.handle(key: true, down: false, now: 1.1))
  #expect(!taps.handle(key: true, down: true, now: 1.3))
  #expect(taps.handle(key: true, down: false, now: 1.35))

  // A chord on the second press, another key between the taps, a slow second tap, or a held press never counts.
  #expect(!taps.handle(key: true, down: true, now: 2))
  #expect(!taps.handle(key: true, down: false, now: 2.1))
  #expect(!taps.handle(key: true, down: true, now: 2.2))
  #expect(!taps.handle(key: false, down: true, now: 2.25))
  #expect(!taps.handle(key: true, down: false, now: 2.3))
  #expect(!taps.handle(key: true, down: true, now: 3))
  #expect(!taps.handle(key: true, down: false, now: 3.1))
  #expect(!taps.handle(key: false, down: true, now: 3.15))
  #expect(!taps.handle(key: true, down: true, now: 3.2))
  #expect(!taps.handle(key: true, down: false, now: 3.25))
  #expect(!taps.handle(key: true, down: true, now: 3.7))
  #expect(!taps.handle(key: true, down: false, now: 3.75))
  #expect(!taps.handle(key: true, down: true, now: 4.5))
  #expect(!taps.handle(key: true, down: false, now: 4.6))
  #expect(!taps.handle(key: true, down: true, now: 4.7))
  #expect(!taps.handle(key: true, down: false, now: 5.5))
 }
 @Test func pasteGesture() {
  var paste = PasteGesture()
  // No recording started yet: a press finishes as before.
  #expect(!paste.secondPress(now: 1, holdDelay: 0.8))

  // A quick second tap pastes without Enter.
  paste.recordingStarted(now: 10)
  #expect(paste.secondPress(now: 10.3, holdDelay: 0.8))
  #expect(paste.pending)
  #expect(paste.release(now: 10.5) == false)
  #expect(!paste.pending)
  #expect(paste.release(now: 10.6) == nil)

  // A second press held through the finish delay pastes with Enter.
  paste.recordingStarted(now: 20)
  #expect(paste.secondPress(now: 20.4, holdDelay: 0.8))
  #expect(paste.release(now: 21.2) == true)

  // A second press after the window is the normal finish; one recording gives one paste at most.
  paste.recordingStarted(now: 30)
  #expect(!paste.secondPress(now: 30.41, holdDelay: 0.8))
  paste.recordingStarted(now: 40)
  #expect(paste.secondPress(now: 40.1, holdDelay: 0.8))
  #expect(paste.release(now: 40.2) == false)
  #expect(!paste.secondPress(now: 40.3, holdDelay: 0.8))

  // Another key between the taps makes the second press a normal finish.
  paste.recordingStarted(now: 45)
  paste.interrupt()
  #expect(!paste.secondPress(now: 45.2, holdDelay: 0.8))

  // A chord or Escape calls the paste off.
  paste.recordingStarted(now: 50)
  #expect(paste.secondPress(now: 50.2, holdDelay: 0.8))
  paste.cancel()
  #expect(paste.release(now: 50.3) == nil)
 }
}
