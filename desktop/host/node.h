// A Hatter node as a Qt Quick item. It draws its background, holds what
// Qt Quick shows for it (a text, button, field, picture or scrolling view),
// and measures and places its children the way Android does.

#pragma once

#include <QColor>
#include <QPointer>
#include <QQuickItem>
#include <QTimer>

#include <climits>
#include <cmath>
#include <vector>

class Host;
class Rows;

// How much room a node gets along one axis, as Android's measure specs.
struct Extent {
    enum Mode { Exactly, AtMost, Unbounded } mode;
    double size;
};

struct Spec {
    Extent w, h;
};

class Node : public QQuickItem {
    Q_OBJECT

public:
    Node(int type, Host *host);
    ~Node() override;

    const int type;

    // Layout parameters the app gave, NaN where it gave none. A width or
    // height of -1 fills the parent.
    double wantWidth = NAN, wantHeight = NAN, weight = NAN, margin = NAN;
    // Hatter's SelfAlignment, -1 for none.
    int alignSelf = -1;
    double padding = 0, maxWidth = INFINITY, translateX = 0, translateY = 0;
    // Padding at the top and bottom, where it differs from padding's.
    double paddingY = NAN;
    // Hatter's TextAlignment: for a column or row, where its children go.
    int gravity = 0;

    // Event handlers by Hatter's event type, -1 for none.
    int handlers[4] = {-1, -1, -1, -1};

    std::vector<Node *> kids;
    Node *parentNode = nullptr;

    // What Qt Quick shows for a leaf, or the Flickable of a scrolling view.
    QPointer<QQuickItem> content;
    QPointer<QQuickItem> background;

    // A lazy column's items, and the rows that show them.
    Rows *rows = nullptr;

    // A scrolling view kept at its end while it's there, and the position
    // the app last heard of.
    bool keepAtEnd = false, pinned = true;
    int position = -1;

    // While the host sets a field's text, which isn't the user typing.
    bool quiet = false;
    // Hatter's InputType of a text input.
    int inputType = 0;
    // The picture it shows from bytes, by its name for Pictures.
    QString picture;
    // The stream it shows frames of, by its key.
    QString stream;
    // The icon it shows, and its size, which it wants unless the app sizes it.
    QString resource;
    QSizeF natural;

    bool scrolling() const;
    // Where the children's items go.
    QQuickItem *slot() const;

    void setBackground(const QColor &colour);
    void setRadius(double radius);
    // A corner's radius, 0 the top left and on clockwise, or with NaN, the
    // radius again.
    void setCorner(int corner, double radius);
    double vertical() const;
    void setHandler(int event, int callback);

    // Measures the node for a spec, keeping what it needs to place it.
    QSizeF measure(const Spec &spec);
    // Places the node, as last measured, and its children.
    void place(double x, double y);

public slots:
    void clicked();
    void pressedLong();
    void edited();
    void moved();

protected:
    void mousePressEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void mouseUngrabEvent() override;
    void updatePolish() override;

private:
    Host *host;
    QSizeF size;
    // Where each child goes inside this node, as last measured.
    std::vector<QPointF> offsets;
    // A scrolling view's content, and short content pushed to the end.
    double extent = 0, pushed = 0;
    QTimer hold;
    bool held = false;

    QSizeF core(const Spec &spec);
    QSizeF leaf(const Spec &spec);
    QSizeF linear(bool vertical, const Spec &spec);
    QSizeF stacked(const Spec &spec);
    QSizeF scroller(const Spec &spec);
    QSizeF listed(const Spec &spec);
};
