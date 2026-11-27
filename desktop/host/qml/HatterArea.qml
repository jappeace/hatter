import QtQuick
import QtQuick.Controls.Material

// A hint, as Android's: shown while the field is empty, never over text.
TextArea {
    property string hint
    placeholderText: length > 0 ? "" : hint
    wrapMode: TextEdit.Wrap
}
