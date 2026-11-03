import QtQuick
import QtQuick.Controls.Material

// Its text as it is, never as markup, in Material's colours for a button.
Button {
    id: button
    // Without its shadow where the window is drawn without GL, which can't
    // draw it: else its background shows elsewhere, or not at all.
    Binding {
        target: button.background
        property: "layer.enabled"
        value: false
        when: button.background.GraphicsInfo.api === GraphicsInfo.Software
    }

    contentItem: Text {
        text: button.text
        textFormat: Text.PlainText
        font: button.font
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: !button.enabled ? button.Material.hintTextColor
            : (button.flat && button.highlighted) || (button.checked && !button.highlighted) ? button.Material.accentColor
            : button.highlighted ? button.Material.primaryHighlightedTextColor : button.Material.foreground
    }
}
