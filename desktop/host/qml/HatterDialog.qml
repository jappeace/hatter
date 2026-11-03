import QtQuick
import QtQuick.Controls.Material

// A question with up to three buttons, as Android's AlertDialog: the first
// on the right, the third on the left. It answers with the button's index,
// or 3 if the user dismissed it.
Dialog {
    id: dialog
    property string message
    property string button1
    property string button2
    property string button3
    property int answer: 3
    signal answered(int action)

    // Without its shadow where the window is drawn without GL, which can't
    // draw it: else its background shows elsewhere, or not at all.
    Binding {
        target: dialog.background
        property: "layer.enabled"
        value: false
        when: dialog.background.GraphicsInfo.api === GraphicsInfo.Software
    }

    anchors.centerIn: parent
    width: Math.min(parent.width - 48, 400)
    modal: true
    // Android's scrim, dark in both themes.
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.32)
    }
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    // The title as it is, never as markup, in Material's own header.
    Component.onCompleted: header.textFormat = Text.PlainText

    Label {
        objectName: "message"
        width: parent.width
        textFormat: Text.PlainText
        text: dialog.message
        wrapMode: Text.Wrap
        visible: text !== ""
    }

    footer: Item {
        implicitHeight: buttons.implicitHeight + 16
        Button {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            flat: true
            text: dialog.button3
            visible: text !== ""
            onClicked: { dialog.answer = 2; dialog.close() }
        }
        Row {
            id: buttons
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Button {
                flat: true
                text: dialog.button2
                visible: text !== ""
                onClicked: { dialog.answer = 1; dialog.close() }
            }
            Button {
                flat: true
                text: dialog.button1
                onClicked: { dialog.answer = 0; dialog.close() }
            }
        }
    }

    onClosed: answered(answer)
}
