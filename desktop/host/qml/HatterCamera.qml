import QtQuick
import QtQuick.Controls.Material
import QtMultimedia

// A picture taken with the desktop's camera, as Android's camera app takes
// one: what the camera sees, and a button that takes it, saved in folder.
// It answers 1 with the file in taken, or 0 if the user closed it.
Popup {
    id: taking
    objectName: "camera"
    property string folder
    property string taken
    signal answered(int action)

    width: parent.width
    height: parent.height
    modal: true
    // For Escape.
    focus: true
    padding: 0
    closePolicy: Popup.CloseOnEscape
    background: Rectangle {
        color: "black"
    }

    MediaDevices {
        id: devices
    }

    CaptureSession {
        camera: Camera {
            active: taking.opened
        }
        imageCapture: ImageCapture {
            id: capture
            onImageSaved: (id, path) => {
                taking.taken = path
                taking.close()
            }
            onErrorOccurred: taking.close()
        }
        videoOutput: preview
    }

    VideoOutput {
        id: preview
        anchors.fill: parent
    }

    Label {
        anchors.centerIn: parent
        visible: devices.videoInputs.length === 0
        text: "No camera"
        color: "white"
    }

    Button {
        flat: true
        text: "Cancel"
        Material.foreground: "white"
        onClicked: taking.close()
    }

    RoundButton {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: 72
        height: 72
        enabled: capture.readyForCapture
        onClicked: capture.captureToFile(taking.folder + "/IMG_" + Date.now() + ".jpg")
    }

    onClosed: answered(taken ? 1 : 0)
}
