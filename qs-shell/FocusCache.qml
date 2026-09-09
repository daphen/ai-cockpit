import QtQuick
import Quickshell
import Quickshell.Io

Process {
  required property string nvimSocket
  command: ["sh", "-c", 'umask 077; p="$1.$$.tmp"; printf %s "$2" > "$p" && mv -f "$p" "$1"',
    "sh", Quickshell.env("XDG_RUNTIME_DIR") + "/cockpit-ipc." + nvimSocket.split("/").pop() + ".id",
    Quickshell.instanceId]
  running: nvimSocket.length > 0
}
