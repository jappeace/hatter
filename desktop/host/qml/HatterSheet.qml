import QtQuick
import QtQuick.Controls.Material

// A list of choices from the bottom of the window, as Android's bottom
// sheet. It answers with the choice's index, or -1 if the user dismissed it.
Dialog {
    id: sheet
    property var items: []
    property int answer: -1
    signal answered(int action)

    // Without its shadow where the window is drawn without GL, which can't
    // draw it: else its background shows elsewhere, or not at all.
    Binding {
        target: sheet.background
        property: "layer.enabled"
        value: false
        when: sheet.background.GraphicsInfo.api === GraphicsInfo.Software
    }

    x: (parent.width - width) / 2
    y: parent.height - implicitHeight
    width: Math.min(parent.width, 560)
    modal: true
    // Android's scrim, dark in both themes.
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.32)
    }
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 0
    topPadding: 8
    bottomPadding: 8

    // The title as it is, never as markup, in Material's own header.
    Component.onCompleted: header.textFormat = Text.PlainText

    Column {
        width: parent.width
        Repeater {
            model: sheet.items
            ItemDelegate {
                id: item
                objectName: "item"
                width: parent.width
                text: modelData
                // Its text as it is, never as markup, in Material's colours.
                contentItem: Text {
                    text: item.text
                    textFormat: Text.PlainText
                    font: item.font
                    verticalAlignment: Text.AlignVCenter
                    color: item.enabled ? item.Material.foreground : item.Material.hintTextColor
                }
                onClicked: { sheet.answer = index; sheet.close() }
            }
        }
    }

    onClosed: answered(answer)
}
