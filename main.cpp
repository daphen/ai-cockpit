#include <QGuiApplication>
#include <QQmlApplicationEngine>

// Standalone harness for testing TermView in isolation (the real cockpit runs
// through quickshell + the heidr_termplugin QML module, not this binary).
int main(int argc, char *argv[]) {
  QGuiApplication app(argc, argv);
  QQmlApplicationEngine engine;
  engine.loadFromModule("HeidrApp", "Main");
  if (engine.rootObjects().isEmpty()) return -1;
  return app.exec();
}
