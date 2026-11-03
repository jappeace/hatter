import QtQuick
import QtQuick.Controls.Material

// The app's text as it is, as on Android, never as markup: it may be a
// peer's.
Text {
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: Material.foreground
    font.pixelSize: 14
}
