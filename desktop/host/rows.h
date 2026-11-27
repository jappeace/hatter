// A lazy column's items, as Qt Quick's ListView sees them: how many there
// are, and rows the app fills only for those that show, as Android's
// RecyclerView.

#pragma once

#include <QAbstractListModel>
#include <QQuickItem>

#include <map>
#include <vector>

class Host;

class Rows : public QAbstractListModel {
    Q_OBJECT

public:
    Rows(Host *host, int list, QObject *parent);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;

    // The app's items after a render: as many as it has now, the shown ones
    // where they went, each row filled again.
    void update(int items);
    // Measures the rows again, at the list's width.
    void lay();

    // For the list's QML: an item showing an item at a position, put aside
    // for another, or gone.
    Q_INVOKABLE void bind(QQuickItem *item, int position);
    Q_INVOKABLE void pool(QQuickItem *item);
    Q_INVOKABLE void release(QQuickItem *item);

private:
    // The app's row an item holds, and the item it shows, by its key; -1
    // while it's put aside.
    struct Shown {
        int row = 0;
        int position = -1;
        qint64 key = 0;
    };

    Host *host;
    const int list;
    int count = 0;
    std::map<QQuickItem *, Shown> shown;
    // Rows of items gone, for new ones.
    std::vector<int> spare;

    void fill(QQuickItem *item, Shown &row);
    void size(QQuickItem *item, int row);
    // Where the item with this key is among the items now, -1 if gone.
    int find(qint64 key, int was, int items) const;
};
