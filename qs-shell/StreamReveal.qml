import QtQuick

// Upstream often delivers a whole message in one burst, so content that arrives while
// the rail is watching types in at a reading pace instead of popping in; history and
// content you scroll back to render instantly. `fade` fades in an item created that way.
QtObject {
  id: root
  property string full: ""
  property bool live: false
  property real arrivedAt: 0
  property bool snapOnEnd: false
  property Item fade: null
  property int shown: 0
  property bool typingOn: false
  readonly property bool revealing: live || shown < full.length
  property string text: ""
  property NumberAnimation typing: NumberAnimation { target: root; property: "shown" }
  property NumberAnimation fadeIn: NumberAnimation {
    target: root.fade; property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic
  }
  function sync() {
    typing.stop()
    if (typingOn && !(snapOnEnd && !live) && full.length > shown) {
      typing.from = shown; typing.to = full.length
      typing.duration = Math.max(160, Math.min(1200, (full.length - shown) * 4))
      typing.start()
    } else shown = full.length
    paint()
  }
  function paint() { text = shown < full.length ? full.slice(0, shown) : full }
  onShownChanged: paint()
  onFullChanged: sync()
  onLiveChanged: sync()
  Component.onCompleted: {
    typingOn = live || (arrivedAt > 0 && Date.now() - arrivedAt < 3000)
    if (typingOn) shown = 0
    sync()
    if (fade && typingOn) fadeIn.start()
  }
}
