import QtQuick
import QtQuick.Controls.Material

// The app's window, in the system's light or dark colours and its accent,
// as Android's are (Material's own accent is pink).
ApplicationWindow {
    Material.theme: Material.System
    Material.accent: palette.accent
    width: 400
    height: 760
    visible: true

    // A short note over the bottom for a moment, as Android's toast.
    function toast(text) {
        note.text = text
        note.visible = true
        hide.restart()
    }

    Label {
        id: note
        objectName: "note"
        // Over the app and its popups.
        parent: Overlay.overlay
        visible: false
        width: Math.min(implicitWidth, parent.width - 32)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 64
        padding: 12
        wrapMode: Text.Wrap
        color: Material.background
        background: Rectangle {
            color: Material.foreground
            radius: 18
        }
    }

    Timer {
        id: hide
        interval: 2000
        onTriggered: note.visible = false
    }
}
