import QtQuick

// A Repeater over a plain number rebuilds every delegate whenever the number changes, so a
// streamed row arriving re-created (and re-faded) all its siblings. This only grows or trims.
ListModel {
  property int size: 0
  onSizeChanged: sync()
  Component.onCompleted: sync()
  function sync() {
    while (count < size) append({ slot: count })
    while (count > size) remove(count - 1)
  }
}
