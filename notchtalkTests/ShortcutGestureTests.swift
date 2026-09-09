import Testing
@testable import notchtalk

struct ShortcutGestureTests {
 @Test func transitions() {

  var gesture = ShortcutGesture()
  #expect(gesture.release() == .none)
  #expect(gesture.press(allowed: true))
  #expect(!gesture.press(allowed: true))
  #expect(gesture.release() == .toggle)
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

 }
}
