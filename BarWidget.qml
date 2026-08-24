import QtQuick
import qs.Commons
import qs.Ui

// Monochrome bar pill using the shell's own BarIconButton, so the glyph picks
// up theme foreground, hover/active states and tooltip chrome exactly like
// first-party widgets (audio, microphone, ...).
BarWidget {
  id: root
  moduleName: "clipbasket.clipboard"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // The bar's popout coordinator calls open/close/toggle by name, so all three
  // are feature-checked the same way: the Loader's item is null until the panel
  // has been created, and a bar that calls into a widget mid-load must get a
  // no-op rather than a TypeError that takes the whole bar down with it.
  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey();
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close();
  }
  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle();
  }
  // Kept as an alias: `toggle` is the documented contract name, and this is
  // what the widget called it before.
  function togglePanel() { root.toggle(); }
  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch();
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0ea"
    active: root.opened
    tooltipText: "Clipbasket"
    // Left button only. A right-click on a bar widget is the bar's own context
    // gesture, and a middle-click is a paste on X11-shaped muscle memory --
    // neither should toggle a clipboard panel.
    onPressed: function (mouseButton) {
      if (mouseButton !== Qt.LeftButton) return;
      root.toggle();
    }
  }
}
