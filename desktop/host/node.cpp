#include "node.h"

#include <QMouseEvent>
#include <QQmlProperty>

#include <algorithm>

#include "host.h"
#include "rows.h"

namespace {

double resolve(const Extent &extent, double wanted)
{
    switch (extent.mode) {
    case Extent::Exactly:
        return extent.size;
    case Extent::AtMost:
        return std::min(extent.size, wanted);
    default:
        return wanted;
    }
}

Extent shrink(double by, Extent extent)
{
    if (extent.mode != Extent::Unbounded) {
        extent.size = std::max(0.0, extent.size - by);
    }
    return extent;
}

// How a child wants to be sized along one axis.
struct Want {
    enum Kind { Match, Wrap, Fixed } kind;
    double size;
};

Extent childExtent(const Extent &parent, double used, const Want &want)
{
    switch (want.kind) {
    case Want::Fixed:
        return {Extent::Exactly, want.size};
    case Want::Match:
        return shrink(used, parent);
    default: {
        Extent extent = shrink(used, parent);
        if (extent.mode == Extent::Exactly) {
            extent.mode = Extent::AtMost;
        }
        return extent;
    }
    }
}

enum class Parent { Column, Row, Stack };

// Hatter's SelfAlignment.
enum { SelfStart, SelfCenter, SelfEnd, SelfStretch };

struct Params {
    Want width, height;
    double weight, margin;
    int align;
};

Want wanted(double size, Want otherwise)
{
    if (std::isnan(size)) {
        return otherwise;
    }
    return size == -1 ? Want{Want::Match, 0} : Want{Want::Fixed, size};
}

// As Android's defaults for a child of each kind of parent.
Params params(Parent parent, const Node &node)
{
    const Want match{Want::Match, 0}, wrap{Want::Wrap, 0};
    const bool aligned = node.alignSelf >= 0, stretched = node.alignSelf == SelfStretch;
    Want width = wrap, height = wrap;
    switch (parent) {
    case Parent::Column:
        width = stretched || !aligned ? match : wrap;
        break;
    case Parent::Row:
        height = stretched ? match : wrap;
        break;
    case Parent::Stack:
        width = height = stretched || !aligned ? match : wrap;
        break;
    }
    return {wanted(node.wantWidth, width), wanted(node.wantHeight, height),
            parent == Parent::Stack ? NAN : node.weight,
            std::isnan(node.margin) ? 0 : node.margin, node.alignSelf};
}

// Where a child goes across its parent's room, by its alignment.
double across(int align, double room, double size, double margin)
{
    switch (align) {
    case SelfCenter:
        return (room - size) / 2;
    case SelfEnd:
        return room - size - margin;
    default:
        return margin;
    }
}

} // namespace

Node::Node(int type, Host *host) : type(type), host(host)
{
    hold.setSingleShot(true);
    hold.setInterval(500);
    connect(&hold, &QTimer::timeout, this, [this] {
        held = true;
        this->host->click(handlers[UI_EVENT_LONG_PRESS]);
    });
}

Node::~Node()
{
    for (Node *kid : kids) {
        kid->parentNode = nullptr;
    }
}

bool Node::scrolling() const
{
    return type == UI_NODE_SCROLL_VIEW || type == UI_NODE_HORIZONTAL_SCROLL_VIEW
        || type == UI_NODE_LAZY_COLUMN;
}

QQuickItem *Node::slot() const
{
    if (scrolling() && content) {
        return content->property("contentItem").value<QQuickItem *>();
    }
    return const_cast<Node *>(this);
}

void Node::setBackground(const QColor &colour)
{
    if (!background) {
        background = host->make("Background", this);
    }
    background->setProperty("color", colour);
}

void Node::setRadius(double radius)
{
    if (!background) {
        setBackground(Qt::transparent);
    }
    background->setProperty("radius", radius);
}

void Node::setCorner(int corner, double radius)
{
    static const char *const names[] = {"topLeftRadius", "topRightRadius", "bottomRightRadius",
                                        "bottomLeftRadius"};
    if (!background) {
        setBackground(Qt::transparent);
    }
    QQmlProperty property(background, names[corner]);
    if (std::isnan(radius)) {
        property.reset();
    } else {
        property.write(radius);
    }
}

double Node::vertical() const
{
    return std::isnan(paddingY) ? padding : paddingY;
}

void Node::setHandler(int event, int callback)
{
    handlers[event] = callback;
    // Buttons and switches take their own taps; other nodes take them once
    // they listen.
    if (type != UI_NODE_BUTTON && type != UI_NODE_SWITCH
        && (event == UI_EVENT_CLICK || event == UI_EVENT_LONG_PRESS)) {
        setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton);
    }
    if (event == UI_EVENT_SCROLLED) {
        position = 2;
    }
}

QSizeF Node::measure(const Spec &spec)
{
    Extent capped = spec.w;
    if (std::isfinite(maxWidth)) {
        capped = spec.w.mode == Extent::Unbounded ? Extent{Extent::AtMost, maxWidth}
                                                  : Extent{spec.w.mode, std::min(spec.w.size, maxWidth)};
    }
    const double across = 2 * padding, down = 2 * vertical();
    const QSizeF inner = core({shrink(across, capped), shrink(down, spec.h)});
    size = {resolve(capped, inner.width() + across), resolve(spec.h, inner.height() + down)};
    return size;
}

QSizeF Node::core(const Spec &spec)
{
    switch (type) {
    case UI_NODE_COLUMN:
        return linear(true, spec);
    case UI_NODE_ROW:
        return linear(false, spec);
    case UI_NODE_STACK:
        return stacked(spec);
    case UI_NODE_SCROLL_VIEW:
    case UI_NODE_HORIZONTAL_SCROLL_VIEW:
        return scroller(spec);
    case UI_NODE_LAZY_COLUMN:
        return listed(spec);
    default:
        return leaf(spec);
    }
}

// What Qt Quick shows, as big as it wants within the spec. Wrapped text is
// as tall as the width it gets makes it.
QSizeF Node::leaf(const Spec &spec)
{
    if (!content) {
        return {resolve(spec.w, 0), resolve(spec.h, 0)};
    }
    if (natural.isValid()) {
        return {resolve(spec.w, natural.width()), resolve(spec.h, natural.height())};
    }
    const double width = resolve(spec.w, content->implicitWidth());
    if (content->width() != width) {
        content->setWidth(width);
    }
    return {width, resolve(spec.h, content->implicitHeight())};
}

// A column or row, like Android's LinearLayout: first the children without
// a weight, each with what the others left, then those with one share what
// is left.
QSizeF Node::linear(bool vertical, const Spec &spec)
{
    const Extent along = vertical ? spec.h : spec.w;
    const Extent acrossExtent = vertical ? spec.w : spec.h;
    const size_t n = kids.size();
    std::vector<Params> ps;
    for (Node *kid : kids) {
        ps.push_back(params(vertical ? Parent::Column : Parent::Row, *kid));
    }
    auto alongOf = [vertical](QSizeF s) { return vertical ? s.height() : s.width(); };
    auto acrossOf = [vertical](QSizeF s) { return vertical ? s.width() : s.height(); };
    auto alongWant = [vertical](const Params &p) { return vertical ? p.height : p.width; };
    auto acrossWant = [vertical](const Params &p) { return vertical ? p.width : p.height; };
    auto measureKid = [&](size_t i, Extent alongKid, Extent acrossKid) {
        return kids[i]->measure(vertical ? Spec{acrossKid, alongKid} : Spec{alongKid, acrossKid});
    };
    auto weighted = [&](size_t i) { return !std::isnan(ps[i].weight) && along.mode != Extent::Unbounded; };

    std::vector<QSizeF> sizes(n);
    double used = 0, weights = 0;
    for (size_t i = 0; i < n; ++i) {
        const double margins = 2 * ps[i].margin;
        if (weighted(i)) {
            weights += ps[i].weight;
            continue;
        }
        sizes[i] = measureKid(i, childExtent(along, used + margins, alongWant(ps[i])),
                              childExtent(acrossExtent, margins, acrossWant(ps[i])));
        used += alongOf(sizes[i]) + margins;
    }
    const double spare = along.mode == Extent::Unbounded ? 0 : std::max(0.0, along.size - used);
    for (size_t i = 0; i < n; ++i) {
        if (weighted(i)) {
            const double margins = 2 * ps[i].margin;
            const double share = weights > 0 ? spare * ps[i].weight / weights : 0;
            sizes[i] = measureKid(i, {Extent::Exactly, std::max(0.0, share - margins)},
                                  childExtent(acrossExtent, margins, acrossWant(ps[i])));
        }
    }

    double total = 0, widest = 0;
    for (size_t i = 0; i < n; ++i) {
        total += alongOf(sizes[i]) + 2 * ps[i].margin;
        widest = std::max(widest, acrossOf(sizes[i]) + 2 * ps[i].margin);
    }
    const double length = resolve(along, total);
    const double breadth = resolve(acrossExtent, widest);

    // Those filling across get all of it, now that it is known.
    for (size_t i = 0; i < n; ++i) {
        const double inner = std::max(0.0, breadth - 2 * ps[i].margin);
        if (acrossWant(ps[i]).kind == Want::Match && acrossOf(sizes[i]) != inner) {
            sizes[i] = measureKid(i, {Extent::Exactly, alongOf(sizes[i])}, {Extent::Exactly, inner});
        }
    }

    // A column's gravity aligns its children across; a row's moves them along.
    double at = 0;
    if (!vertical && gravity == SelfCenter) {
        at = (length - total) / 2;
    } else if (!vertical && gravity == SelfEnd) {
        at = length - total;
    }
    offsets.assign(n, {});
    for (size_t i = 0; i < n; ++i) {
        const Params &p = ps[i];
        const int align = p.align >= 0 ? p.align : vertical ? gravity : SelfStart;
        const double side = across(align, breadth, acrossOf(sizes[i]), p.margin);
        offsets[i] = vertical ? QPointF(side, at + p.margin) : QPointF(at + p.margin, side);
        at += alongOf(sizes[i]) + 2 * p.margin;
    }
    return vertical ? QSizeF(breadth, length) : QSizeF(length, breadth);
}

// Children over each other, like Android's FrameLayout.
QSizeF Node::stacked(const Spec &spec)
{
    const size_t n = kids.size();
    std::vector<Params> ps;
    std::vector<QSizeF> sizes(n);
    double width = 0, height = 0;
    for (size_t i = 0; i < n; ++i) {
        ps.push_back(params(Parent::Stack, *kids[i]));
        const double margins = 2 * ps[i].margin;
        sizes[i] = kids[i]->measure({childExtent(spec.w, margins, ps[i].width),
                                     childExtent(spec.h, margins, ps[i].height)});
        width = std::max(width, sizes[i].width() + margins);
        height = std::max(height, sizes[i].height() + margins);
    }
    width = resolve(spec.w, width);
    height = resolve(spec.h, height);
    offsets.assign(n, {});
    for (size_t i = 0; i < n; ++i) {
        const Params &p = ps[i];
        const double w = std::max(0.0, width - 2 * p.margin), h = std::max(0.0, height - 2 * p.margin);
        const bool matchW = p.width.kind == Want::Match, matchH = p.height.kind == Want::Match;
        if ((matchW && sizes[i].width() != w) || (matchH && sizes[i].height() != h)) {
            sizes[i] = kids[i]->measure({{Extent::Exactly, matchW ? w : sizes[i].width()},
                                         {Extent::Exactly, matchH ? h : sizes[i].height()}});
        }
        offsets[i] = {across(p.align, width, sizes[i].width(), p.margin),
                      across(p.align, height, sizes[i].height(), p.margin)};
    }
    return {width, height};
}

// A scrolling column or row: its children as a column or row as long as
// they are, in as much room as it has. Short content of a column kept at
// its end sits at the end.
QSizeF Node::scroller(const Spec &spec)
{
    const bool vertical = type != UI_NODE_HORIZONTAL_SCROLL_VIEW;
    const Extent unbounded{Extent::Unbounded, 0};
    const QSizeF inner = linear(vertical, vertical ? Spec{spec.w, unbounded} : Spec{unbounded, spec.h});
    extent = vertical ? inner.height() : inner.width();
    const double along = resolve(vertical ? spec.h : spec.w, extent);
    const double breadth = vertical ? inner.width() : inner.height();
    pushed = keepAtEnd && vertical ? std::max(0.0, along - extent) : 0;
    return vertical ? QSizeF(breadth, along) : QSizeF(along, breadth);
}

// A lazy column: as wide as it may be, and as tall as its rows if it may
// be, as far as its list knows them.
QSizeF Node::listed(const Spec &spec)
{
    const double length = content ? content->property("contentHeight").toDouble() : 0;
    return {spec.w.mode == Extent::Unbounded ? 0 : spec.w.size, resolve(spec.h, length)};
}

void Node::place(double x, double y)
{
    setPosition({x + translateX, y + translateY});
    setSize(size);
    if (background) {
        background->setSize(size);
    }
    const QRectF inner(padding, vertical(), std::max(0.0, size.width() - 2 * padding),
                       std::max(0.0, size.height() - 2 * vertical()));
    if (content) {
        content->setPosition(inner.topLeft());
        content->setSize(inner.size());
    }
    const bool vertical = type != UI_NODE_HORIZONTAL_SCROLL_VIEW;
    const QPointF origin = scrolling() ? QPointF(0, pushed) : inner.topLeft();
    for (size_t i = 0; i < kids.size() && i < offsets.size(); ++i) {
        kids[i]->place(origin.x() + offsets[i].x(), origin.y() + offsets[i].y());
    }
    if (rows && content) {
        rows->lay();
        // Short content kept at its end sits at the end.
        const double length = content->property("contentHeight").toDouble();
        content->setProperty("topMargin", keepAtEnd ? std::max(0.0, inner.height() - length) : 0.0);
        if (keepAtEnd && pinned) {
            QMetaObject::invokeMethod(content, "positionViewAtEnd");
        }
    } else if (scrolling() && content) {
        const double length = extent + pushed;
        content->setProperty("contentWidth", vertical ? inner.width() : length);
        content->setProperty("contentHeight", vertical ? length : inner.height());
        if (keepAtEnd && pinned) {
            content->setProperty("contentY", std::max(0.0, length - inner.height()));
        }
    }
}

void Node::clicked()
{
    host->click(handlers[UI_EVENT_CLICK]);
}

void Node::pressedLong()
{
    host->click(handlers[UI_EVENT_LONG_PRESS]);
}

void Node::edited()
{
    if (!quiet) {
        host->text(handlers[UI_EVENT_TEXT_CHANGE], content->property("text").toString());
    }
}

// Where a scrolling view is: kept at its end while it's there, and the app
// told when it reaches or leaves its start or end.
void Node::moved()
{
    if (!content) {
        return;
    }
    const bool vertical = type != UI_NODE_HORIZONTAL_SCROLL_VIEW;
    const double at = content->property(vertical ? "contentY" : "contentX").toDouble();
    const double room = vertical ? content->height() : content->width();
    const double length = content->property(vertical ? "contentHeight" : "contentWidth").toDouble();
    // A list knows where its ends are, from rows it may not have made.
    const bool end = rows ? content->property("atYEnd").toBool() : at + room >= length - 1;
    const bool start = rows ? content->property("atYBeginning").toBool() : at <= 0;
    if (!host->laying) {
        pinned = end;
    }
    const int now = end ? 2 : start ? 0 : 1;
    if (handlers[UI_EVENT_SCROLLED] >= 0 && now != position) {
        position = now;
        host->scroll(handlers[UI_EVENT_SCROLLED], now);
    }
}

// A tap, or a long press: held, or with the secondary button.
void Node::mousePressEvent(QMouseEvent *event)
{
    if (event->button() == Qt::RightButton) {
        if (handlers[UI_EVENT_LONG_PRESS] >= 0) {
            host->click(handlers[UI_EVENT_LONG_PRESS]);
        }
        return;
    }
    held = false;
    if (handlers[UI_EVENT_LONG_PRESS] >= 0) {
        hold.start();
    }
}

void Node::mouseReleaseEvent(QMouseEvent *event)
{
    hold.stop();
    if (!held && event->button() == Qt::LeftButton && contains(event->position())
        && handlers[UI_EVENT_CLICK] >= 0) {
        host->click(handlers[UI_EVENT_CLICK]);
    }
}

// A scrolling view took the press over, as the user drags it.
void Node::mouseUngrabEvent()
{
    hold.stop();
}

// The root lays the window out before it's drawn.
void Node::updatePolish()
{
    if (this == host->root) {
        host->layout();
    }
}
