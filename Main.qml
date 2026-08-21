import QtQuick
import QtQuick.Window
import Heidr

Window {
  visible: true
  width: 1200
  height: 800
  title: "Cockpit × libghostty-vt"
  color: "#181818"

  Row {
    anchors.fill: parent

    // Left: QML chrome (mock rail) — proves QML UI + embedded terminal share one window.
    Rectangle {
      id: rail
      width: 300
      height: parent.height
      color: "#141414"

      Column {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 10

        Text {
          text: "ROSTER · lovable"
          color: "#FF570D"
          font.family: "GeistMono Nerd Font"
          font.pixelSize: 13
          font.bold: true
        }

        Repeater {
          model: [
            { name: "every-2662", state: "working 13s", accent: "#97B5A6" },
            { name: "lovable",    state: "idle 8m",     accent: "#8A9AA6" },
            { name: "every-2640", state: "idle 3h",     accent: "#8A9AA6" },
            { name: "every-2457", state: "idle 3h",     accent: "#8A9AA6" }
          ]
          Rectangle {
            width: rail.width - 36
            height: 52
            radius: 10
            color: "#1e1e1e"
            border.color: "#2a2a2a"
            border.width: 1
            Column {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: 14
              spacing: 3
              Row {
                spacing: 8
                Rectangle { width: 8; height: 8; radius: 4; color: modelData.accent; anchors.verticalCenter: parent.verticalCenter }
                Text { text: modelData.name; color: "#EDEDED"; font.family: "GeistMono Nerd Font"; font.pixelSize: 13 }
              }
              Text { text: modelData.state; color: "#707B84"; font.family: "GeistMono Nerd Font"; font.pixelSize: 11 }
            }
          }
        }
      }
    }

    // Right: the real libghostty-vt terminal.
    TermView {
      id: term
      width: parent.width - rail.width
      height: parent.height
      focus: true
      Component.onCompleted: term.forceActiveFocus()
    }
  }
}
