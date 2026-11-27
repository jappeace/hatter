// The app's icons, its Android vector drawables (<name>.xml), drawn as SVG
// the way the browser's icons.mjs writes them. Tinted ones take the colour
// they're drawn in, as Android tints them with the theme's.

#include <QFile>
#include <QPainter>
#include <QSvgRenderer>
#include <QXmlStreamReader>

#include "platform.h"

namespace {

QString resources;

QString attribute(const QXmlStreamAttributes &attributes, const char *name)
{
    return attributes.value(QStringLiteral("http://schemas.android.com/apk/res/android"),
                            QLatin1String(name))
        .toString();
}

// Android's #AARRGGBB or #RRGGBB, as SVG's colour and opacity.
QString paint(const QString &value, const char *what)
{
    const QColor colour(value.startsWith(QLatin1Char('#')) ? value : QStringLiteral("#000000"));
    return QStringLiteral(" %1=\"%2\" %1-opacity=\"%3\"")
        .arg(QLatin1String(what), colour.name(QColor::HexRgb), QString::number(colour.alphaF()));
}

struct Vector {
    QSizeF size;
    QByteArray svg;
};

Vector read(const QString &name, const QColor &tint)
{
    QFile file(resources + QLatin1Char('/') + name + QStringLiteral(".xml"));
    if (resources.isEmpty() || !file.open(QIODevice::ReadOnly)) {
        return {};
    }
    QXmlStreamReader xml(&file);
    Vector vector;
    QString paths;
    bool tinted = false;
    // Every path, also those in groups, whose transforms aren't drawn.
    while (!xml.atEnd()) {
        if (xml.readNext() != QXmlStreamReader::StartElement) {
            continue;
        }
        const QXmlStreamAttributes a = xml.attributes();
        if (xml.name() == QLatin1String("vector")) {
            tinted = !attribute(a, "tint").isEmpty();
            vector.size = {attribute(a, "width").remove(QStringLiteral("dp")).toDouble(),
                           attribute(a, "height").remove(QStringLiteral("dp")).toDouble()};
            paths = QStringLiteral("viewBox=\"0 0 %1 %2\">")
                        .arg(attribute(a, "viewportWidth"), attribute(a, "viewportHeight"));
            continue;
        }
        if (xml.name() == QLatin1String("path")) {
            const auto colour = [&](const QString &value, const char *what) {
                return tinted ? paint(tint.name(QColor::HexArgb), what) : paint(value, what);
            };
            const QString fill = attribute(a, "fillColor"), stroke = attribute(a, "strokeColor");
            paths += QStringLiteral("<path d=\"%1\"").arg(attribute(a, "pathData"));
            paths += fill.isEmpty() ? QStringLiteral(" fill=\"none\"") : colour(fill, "fill");
            if (!stroke.isEmpty()) {
                const QString width = attribute(a, "strokeWidth");
                const QString cap = attribute(a, "strokeLineCap");
                const QString join = attribute(a, "strokeLineJoin");
                paths += colour(stroke, "stroke")
                    + QStringLiteral(" stroke-width=\"%1\" stroke-linecap=\"%2\" stroke-linejoin=\"%3\"")
                          .arg(width.isEmpty() ? QStringLiteral("1") : width,
                               cap.isEmpty() ? QStringLiteral("butt") : cap,
                               join.isEmpty() ? QStringLiteral("miter") : join);
            }
            paths += QStringLiteral("/>");
        }
    }
    if (!vector.size.isValid() || paths.isEmpty()) {
        return {};
    }
    vector.svg = (QStringLiteral("<svg xmlns=\"http://www.w3.org/2000/svg\" ") + paths + QStringLiteral("</svg>"))
                     .toUtf8();
    return vector;
}

} // namespace

QSizeF iconSize(const QString &name)
{
    return read(name, Qt::black).size;
}

QImage icon(const QString &name, const QSize &size, const QColor &colour)
{
    const Vector vector = read(name, colour);
    QSvgRenderer renderer(vector.svg);
    if (!renderer.isValid() || size.isEmpty()) {
        return {};
    }
    QImage image(size, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    QPainter painter(&image);
    renderer.render(&painter);
    return image;
}

extern "C" void hatter_qt_set_resources(const char *dir)
{
    resources = QString::fromUtf8(dir);
}
