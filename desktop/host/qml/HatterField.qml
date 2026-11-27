import QtQuick.Controls.Material

// A hint, as Android's: shown while the field is empty, never over text.
TextField {
    property string hint
    placeholderText: length > 0 ? "" : hint
}
