import QtQuick
import QtQuick.Controls.Material

// A lazy column: items only for the rows that show, which the host's Rows
// has the app fill, as Android's RecyclerView.
ListView {
    id: list
    property QtObject rows
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: true
    ScrollBar.vertical: ScrollBar {}

    delegate: Item {
        id: row
        required property int index
        width: ListView.view.width
        Component.onCompleted: list.rows.bind(row, index)
        ListView.onReused: list.rows.bind(row, index)
        ListView.onPooled: list.rows.pool(row)
        // Not when the list itself goes, with its Rows.
        Component.onDestruction: if (list.rows) list.rows.release(row)
    }
}
