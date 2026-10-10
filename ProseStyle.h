#pragma once

#include <QObject>
#include <QQuickTextDocument>
#include <QtQml/qqmlregistration.h>

class ProseStyle : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON

public:
  using QObject::QObject;
  Q_INVOKABLE void apply(QQuickTextDocument *document, const QString &boldFamily = QString());
};
