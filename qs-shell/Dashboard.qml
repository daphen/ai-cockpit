import QtQuick
import Quickshell
import QsLib

FocusScope {
  id: root

  property var model: ({})
  property int cursor: 0
  signal actionRequested(string actionId)
  signal focusRequested(string direction)

  readonly property var selectable: {
    var out = []
    var cards = model.cards || []
    for (var i = 0; i < cards.length; i++) {
      var rows = cards[i].rows || []
      for (var j = 0; j < rows.length; j++)
        if (rows[j].action) out.push(rows[j].action)
    }
    return out
  }
  readonly property string currentAction: selectable.length
    ? selectable[Math.max(0, Math.min(cursor, selectable.length - 1))] : ""

  function tone(name) {
    if (name === "accent") return Theme.electric
    if (name === "error") return Theme.red
    if (name === "success") return Theme.green
    if (name === "muted") return Theme.fg_muted
    return Theme.fg
  }
  function changeParts(text) {
    var match = String(text || "").match(/^(.*?\S)\s+(\+\d+)\s+(-\d+)\s*$/)
    if (!match) return null
    return {
      label: match[1].replace(/^•\s*/, ""),
      additions: match[2],
      removals: match[3]
    }
  }
  function move(delta) {
    if (!selectable.length) return
    cursor = (cursor + delta + selectable.length) % selectable.length
  }
  function dispatch(id) {
    if (id) actionRequested(id)
  }
  function activate() {
    dispatch(currentAction)
  }
  function shortcut(text) {
    if (text === "i") { dispatch("key:i"); return true }
    var actions = model.actions || []
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].key === text) { dispatch(actions[i].id); return true }
    }
    return false
  }

  onModelChanged: cursor = 0
  Keys.onPressed: event => {
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_L) { focusRequested("right"); event.accepted = true }
    else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_H) { focusRequested("left"); event.accepted = true }
    else if (event.key === Qt.Key_J || event.text === "j") { move(1); event.accepted = true }
    else if (event.key === Qt.Key_K || event.text === "k") { move(-1); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.text === "o") { activate(); event.accepted = true }
    else if (event.key === Qt.Key_Tab) { dispatch("tab"); event.accepted = true }
    else if (shortcut(event.text)) event.accepted = true
  }

  Rectangle {
    anchors.fill: parent
    color: Theme.bg
  }

  Flickable {
    id: view
    anchors { fill: parent; bottomMargin: hints.height }
    contentWidth: width
    contentHeight: content.implicitHeight + 56
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      width: Math.max(320, Math.min(view.width - 64, 980))
      x: Math.round((view.width - width) / 2)
      y: 36
      spacing: 24

      Image {
        readonly property bool lovableMasthead: String(root.model.masthead || "") === "lovable"
        anchors.horizontalCenter: parent.horizontalCenter
        width: lovableMasthead
          ? Math.min(parent.width * 0.36, 350)
          : Math.min(parent.width * 0.48, 470)
        height: width * 0.233
        source: {
          var dir = Quickshell.env("COCKPIT_ASSET_DIR") || ""
          var name = String(root.model.masthead || "cockpit") + "-" + Theme.mode + ".png"
          return dir ? "file://" + dir + "/" + name : ""
        }
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        height: visible ? 34 : 0
        spacing: 8
        visible: (root.model.tabs || []).length > 1
        Repeater {
          model: root.model.tabs || []
          delegate: Rectangle {
            required property string modelData
            width: tabText.implicitWidth + 24
            height: 30
            radius: 9
            color: modelData === root.model.activeTab ? Theme.fg : "transparent"
            border.width: modelData === root.model.activeTab ? 0 : 1
            border.color: Theme.hairline
            Text {
              id: tabText
              anchors.centerIn: parent
              text: modelData.toUpperCase()
              color: modelData === root.model.activeTab ? Theme.bg : Theme.fg_muted
              font { family: Theme.fontFamily; pixelSize: 15; weight: 600 }
            }
            TapHandler { onTapped: root.dispatch("tab:" + modelData) }
          }
        }
      }

      Repeater {
        model: root.model.cards || []
        delegate: Card {
          id: card
          required property var modelData
          width: content.width
          height: cardBody.implicitHeight + 42
          border.width: 1
          border.color: Theme.hairline

          Column {
            id: cardBody
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
            spacing: 4

            Text {
              text: (root.model.tabs || []).length
                ? String(root.model.activeTab || modelData.title || "").toUpperCase()
                : String(modelData.title || "")
              color: Theme.fg
              font { family: Theme.fontFamily; pixelSize: 16; weight: 650 }
              bottomPadding: 8
            }

            Flickable {
              id: rowsView
              width: cardBody.width
              height: Math.min(rowsColumn.implicitHeight, 548)
              contentWidth: width
              contentHeight: rowsColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollFeel { flick: rowsView }

              Column {
                id: rowsColumn
                width: rowsView.width
                spacing: 4

                Repeater {
                  id: rows
                  model: card.modelData.rows || []
                  delegate: Rectangle {
                id: row
                required property var modelData
                width: cardBody.width
                height: modelData.text ? 32 : 12
                radius: 8
                color: modelData.action === root.currentAction ? Theme.selection : "transparent"

                readonly property bool splitMarker: !!modelData.markerTone && String(modelData.text || "").length > 1
                readonly property bool hasIcon: modelData.icon !== undefined || splitMarker
                readonly property var change: modelData.additions !== undefined
                  ? ({ label: String(modelData.label || ""), additions: String(modelData.additions), removals: String(modelData.removals) })
                  : root.changeParts(modelData.text)
                readonly property bool hasAdditions: !!change && change.additions !== "+0"
                readonly property bool hasRemovals: !!change && change.removals !== "-0"

                Icon {
                  id: marker
                  anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                  visible: row.hasIcon
                  width: 18
                  height: 18
                  name: row.modelData.icon !== undefined ? String(row.modelData.icon)
                    : row.change ? "file-content"
                    : row.modelData.markerTone === "success" ? "check"
                    : row.modelData.markerTone === "accent" ? "loader"
                    : row.modelData.markerTone === "error" ? "triangle-warning"
                    : "minus"
                  color: row.change
                    ? (row.hasAdditions && row.hasRemovals ? Theme.yellow
                      : row.hasAdditions ? Theme.green : Theme.red)
                    : root.tone(row.modelData.iconTone || row.modelData.markerTone)
                }
                Text {
                  anchors {
                    left: row.hasIcon ? marker.right : parent.left
                    leftMargin: row.hasIcon ? 7 : 10
                    right: stats.visible ? stats.left : parent.right
                    rightMargin: stats.visible ? 18 : 10
                    verticalCenter: parent.verticalCenter
                  }
                  text: row.change
                    ? row.change.label
                    : (row.modelData.label !== undefined
                      ? String(row.modelData.label)
                      : (row.splitMarker
                        ? String(row.modelData.text || "").slice(1).trim()
                        : String(row.modelData.text || "")))
                  color: root.tone(row.modelData.tone)
                  elide: Text.ElideMiddle
                  font { family: Theme.fontFamily; pixelSize: 15 }
                }
                Row {
                  id: stats
                  anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                  visible: !!row.change || row.modelData.detail !== undefined
                  spacing: 14
                  Text {
                    visible: !!row.change
                    text: row.change ? row.change.additions : ""
                    color: row.hasAdditions ? Theme.green : Theme.fg_muted
                    font { family: Theme.fontFamily; pixelSize: 15; weight: 650 }
                  }
                  Text {
                    visible: !!row.change
                    text: row.change ? row.change.removals : ""
                    color: row.hasRemovals ? Theme.red : Theme.fg_muted
                    font { family: Theme.fontFamily; pixelSize: 15; weight: 650 }
                  }
                  Text {
                    visible: row.modelData.detail !== undefined
                    text: visible ? String(row.modelData.detail) : ""
                    color: Theme.fg_muted
                    font { family: Theme.fontFamily; pixelSize: 15; weight: 600 }
                  }
                }
                TapHandler {
                  enabled: !!row.modelData.action
                  onTapped: {
                    root.cursor = Math.max(0, root.selectable.indexOf(row.modelData.action))
                    root.dispatch(row.modelData.action)
                  }
                }
              }
            }
          }

              Connections {
                target: root
                function onCurrentActionChanged() {
                  for (var i = 0; i < rows.count; i++) {
                    var item = rows.itemAt(i)
                    if (!item || item.modelData.action !== root.currentAction) continue
                    if (item.y < rowsView.contentY) rowsView.contentY = item.y
                    else if (item.y + item.height > rowsView.contentY + rowsView.height)
                      rowsView.contentY = item.y + item.height - rowsView.height
                    return
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Item {
    id: hints
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    visible: (root.model.actions || []).length > 0
    height: visible ? 40 : 0
    Row {
      anchors.centerIn: parent
      spacing: 18
      Repeater {
        model: root.model.actions || []
        delegate: Row {
          required property var modelData
          spacing: 7
          KeyCap { text: modelData.key; small: true }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            color: Theme.fg_muted
            font { family: Theme.fontFamily; pixelSize: 14 }
          }
          TapHandler { onTapped: root.dispatch(modelData.id) }
        }
      }
    }
  }
}
