#include "rows.h"

#include "host.h"
#include "node.h"

Rows::Rows(Host *host, int list, QObject *parent) : QAbstractListModel(parent), host(host), list(list)
{
}

int Rows::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : count;
}

QVariant Rows::data(const QModelIndex &, int) const
{
    return {};
}

void Rows::update(int items)
{
    // The first item shown, to keep it where it is: items added or taken
    // before it, as older messages, move it.
    const Shown *first = nullptr;
    for (const auto &[item, row] : shown) {
        if (row.position >= 0 && (!first || row.position < first->position)) {
            first = &row;
        }
    }
    const int now = first ? find(first->key, first->position, items) : 0;
    if (now < 0) {
        beginResetModel();
        for (auto &[item, row] : shown) {
            row.position = -1;
        }
        count = items;
        endResetModel();
    } else {
        const int moved = first ? now - first->position : 0;
        if (moved > 0) {
            beginInsertRows({}, 0, moved - 1);
            count += moved;
            endInsertRows();
        } else if (moved < 0) {
            beginRemoveRows({}, 0, -moved - 1);
            count += moved;
            endRemoveRows();
        }
        if (items > count) {
            beginInsertRows({}, count, items - 1);
            count = items;
            endInsertRows();
        } else if (items < count) {
            beginRemoveRows({}, items, count - 1);
            count = items;
            endRemoveRows();
        }
    }
    // What they show may have changed too.
    for (auto &[item, row] : shown) {
        if (row.position >= 0) {
            row.position = item->property("index").toInt();
            fill(item, row);
        }
    }
}

void Rows::lay()
{
    for (const auto &[item, row] : shown) {
        if (row.position >= 0) {
            size(item, row.row);
        }
    }
}

void Rows::bind(QQuickItem *item, int position)
{
    Shown &row = shown[item];
    row.position = position;
    fill(item, row);
}

void Rows::pool(QQuickItem *item)
{
    shown[item].position = -1;
}

void Rows::release(QQuickItem *item)
{
    const auto found = shown.find(item);
    if (found == shown.end()) {
        return;
    }
    const int row = found->second.row;
    shown.erase(found);
    const auto node = host->nodes.find(row);
    if (node != host->nodes.end()) {
        node->second->setParentItem(nullptr);
        spare.push_back(row);
    }
}

void Rows::fill(QQuickItem *item, Shown &row)
{
    if (row.row == 0 && !spare.empty()) {
        row.row = spare.back();
        spare.pop_back();
    }
    row.row = host->app.bind(host->app.ctx, list, row.row, row.position);
    row.key = host->app.key(host->app.ctx, list, row.position);
    size(item, row.row);
}

// As tall as its row is at the list's width.
void Rows::size(QQuickItem *item, int row)
{
    const auto found = host->nodes.find(row);
    if (found == host->nodes.end()) {
        item->setHeight(0);
        return;
    }
    Node *node = found->second;
    if (node->parentItem() != item) {
        node->setParentItem(item);
    }
    const QSizeF measured = node->measure({{Extent::Exactly, item->width()}, {Extent::Unbounded, 0}});
    node->place(0, 0);
    item->setHeight(measured.height());
}

int Rows::find(qint64 key, int was, int items) const
{
    if (was < items && host->app.key(host->app.ctx, list, was) == key) {
        return was;
    }
    for (int position = 0; position < items; ++position) {
        if (host->app.key(host->app.ctx, list, position) == key) {
            return position;
        }
    }
    return -1;
}
