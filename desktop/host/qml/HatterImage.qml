import QtQuick
import QtQuick.Effects

// A picture, with its corners as round as the app asks. Square where the
// window is drawn without GL, which can't draw the mask: else it shows
// nothing.
Image {
    id: image
    property real radius
    fillMode: Image.PreserveAspectFit
    layer.enabled: radius > 0 && GraphicsInfo.api !== GraphicsInfo.Software
    layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: corners
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    Rectangle {
        id: corners
        width: image.width
        height: image.height
        radius: image.radius
        visible: false
        layer.enabled: true
    }
}
