import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Two views in one panel: the clip list, and a settings page reached from the
// cog in the footer. Only settings that mean something on Linux/Wayland are
// present -- macOS-only concepts (Accessibility permission, app-managed
// updates, app-owned theming) are deliberately absent, with a note saying why.
Panel {
  id: root
  moduleName: "dev.clipbasket.demo"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var entries: []
  property string query: ""
  property string filter: "All"
  property bool settingsOpen: false

  // Demo settings state. A real glue plugin would read/write the app's own
  // config file here instead.
  property bool launchAtLogin: true
  property bool ignoreConfidential: true
  property bool closeAfterAction: true
  property bool openAtCursor: true
  property int maxClips: 100000

  readonly property var filters: ["All", "Text", "Links", "Images", "Files", "Saved"]
  readonly property string statePath: "~/.local/state/clipbasket-demo/settings.json"

  function shq(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'"; }
  function refresh() { probe.running = true; settingsProbe.running = true; }
  function openFromHotkey() { root.controller.show(); refresh(); }

  onOpenedChanged: {
    if (root.opened) refresh();
    else root.settingsOpen = false;
  }

  function persist() {
    var payload = JSON.stringify({
      launchAtLogin: root.launchAtLogin,
      ignoreConfidential: root.ignoreConfidential,
      closeAfterAction: root.closeAfterAction,
      openAtCursor: root.openAtCursor,
      maxClips: root.maxClips
    });
    if (root.bar) root.bar.run("mkdir -p ~/.local/state/clipbasket-demo && printf %s " + root.shq(payload) + " > " + root.statePath);
  }

  function matches(entry) {
    if (!entry) return false;
    var text = String(entry.text || "");
    if (root.query.length > 0 && text.toLowerCase().indexOf(root.query.toLowerCase()) === -1) return false;
    switch (root.filter) {
      case "Text":   return entry.type === "text" && !/^https?:\/\//i.test(text);
      case "Links":  return /^https?:\/\//i.test(text);
      case "Images": return entry.type !== "text";
      case "Files":  return /^\//.test(text);
      case "Saved":  return false;
      default:       return true;
    }
  }

  readonly property var visibleEntries: {
    var out = [];
    for (var i = 0; i < root.entries.length; i++) if (matches(root.entries[i])) out.push(root.entries[i]);
    return out;
  }

  Process {
    id: probe
    command: ["sh", "-c", "jq -c '[.[0:60][] | {type: .type, text: ((.text // \"(image)\") | .[0:200])}]' ~/.local/state/omarchy/clipboard-history.json 2>/dev/null || echo '[]'"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: { try { root.entries = JSON.parse(text.trim()); } catch (e) { root.entries = []; } }
    }
  }

  Process {
    id: settingsProbe
    command: ["sh", "-c", "cat ~/.local/state/clipbasket-demo/settings.json 2>/dev/null || echo '{}'"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var s = JSON.parse(text.trim());
          if ("launchAtLogin" in s) root.launchAtLogin = s.launchAtLogin;
          if ("ignoreConfidential" in s) root.ignoreConfidential = s.ignoreConfidential;
          if ("closeAfterAction" in s) root.closeAfterAction = s.closeAfterAction;
          if ("openAtCursor" in s) root.openAtCursor = s.openAtCursor;
          if ("maxClips" in s) root.maxClips = s.maxClips;
        } catch (e) {}
      }
    }
  }

  // ---- Reusable toggle, styled after the macOS switches in the real product.
  component Toggle: Rectangle {
    id: sw
    property bool checked: false
    signal toggled
    width: Style.space(38)
    height: Style.space(20)
    radius: height / 2
    color: checked ? root.barForeground : Qt.rgba(1, 1, 1, 0.14)
    Behavior on color { ColorAnimation { duration: 120 } }

    Rectangle {
      width: parent.height - 4
      height: width
      radius: width / 2
      y: 2
      x: sw.checked ? parent.width - width - 2 : 2
      color: sw.checked ? Color.background : Qt.rgba(1, 1, 1, 0.75)
      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: { sw.checked = !sw.checked; sw.toggled(); }
    }
  }

  // ---- Reusable settings row
  component SettingRow: Item {
    property string title: ""
    property string subtitle: ""
    default property alias control: holder.data
    width: parent ? parent.width - Style.space(28) : 0
    x: Style.space(14)
    height: Math.max(Style.space(34), col.implicitHeight + Style.space(10))

    Column {
      id: col
      anchors.left: parent.left
      anchors.right: holder.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      Text {
        width: parent.width
        text: parent.parent.title
        color: root.barForeground
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        visible: text.length > 0
        text: parent.parent.subtitle
        color: root.barForeground
        opacity: 0.4
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Item {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component SectionHeader: Text {
    color: root.barForeground
    opacity: 0.4
    x: Style.space(14)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(560), root.settingsOpen ? settingsView.implicitHeight : listView.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: { if (root.settingsOpen) root.settingsOpen = false; else root.close(); }
      onTabRequested: function (direction) { root.switchPanel(direction); }

      // ================= CLIP LIST =================
      Column {
        id: listView
        width: parent.width
        spacing: Style.space(10)
        visible: !root.settingsOpen

        Item { width: 1; height: Style.space(12) }

        // Subtle brand: small glyph + wordmark, with the settings cog as the
        // trailing action. The clip count lives in the footer, so it is not
        // repeated here.
        Item {
          width: parent.width - Style.space(28)
          x: Style.space(14)
          height: Style.space(22)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf0ea"
              color: root.barForeground
              opacity: 0.85
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Clipbasket"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf013"
            color: root.barForeground
            opacity: cogArea.containsMouse ? 0.95 : 0.45
            font.family: Style.font.family
            font.pixelSize: Style.font.body

            MouseArea {
              id: cogArea
              anchors.fill: parent
              anchors.margins: -8
              hoverEnabled: true
              onClicked: root.settingsOpen = true
            }
          }
        }

        Rectangle {
          width: parent.width - Style.space(28)
          x: Style.space(14)
          height: Style.space(30)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.05)
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, searchInput.activeFocus ? 0.22 : 0.10)

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: ""
              color: root.barForeground
              opacity: 0.4
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextInput {
              id: searchInput
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(36)
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              selectByMouse: true
              onTextChanged: root.query = text
              Text {
                anchors.fill: parent
                visible: searchInput.text.length === 0
                text: "Search"
                color: root.barForeground
                opacity: 0.35
                font: searchInput.font
                verticalAlignment: Text.AlignVCenter
              }
            }
          }
        }

        Row {
          x: Style.space(14)
          spacing: Style.space(6)

          Repeater {
            model: root.filters

            Rectangle {
              readonly property bool selected: root.filter === modelData
              height: Style.space(22)
              width: chipText.implicitWidth + Style.space(18)
              radius: height / 2
              color: selected ? root.barForeground : Qt.rgba(1, 1, 1, 0.05)
              border.width: 1
              border.color: Qt.rgba(1, 1, 1, selected ? 0 : 0.12)

              Text {
                id: chipText
                anchors.centerIn: parent
                text: modelData
                color: parent.selected ? Color.background : root.barForeground
                opacity: parent.selected ? 1 : 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea { anchors.fill: parent; onClicked: root.filter = modelData }
            }
          }
        }

        SectionHeader { text: "NOW" }

        Column {
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.visibleEntries

            Rectangle {
              width: listView.width - Style.space(20)
              x: Style.space(10)
              height: Style.space(46)
              radius: 8
              color: rowHover.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(10)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(30)
                  height: Style.space(30)
                  radius: 6
                  color: Qt.rgba(1, 1, 1, 0.06)
                  border.width: 1
                  border.color: Qt.rgba(1, 1, 1, 0.10)

                  Text {
                    anchors.centerIn: parent
                    text: modelData.type === "text" ? "" : ""
                    color: root.barForeground
                    opacity: 0.6
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(52) - (rowHover.containsMouse ? Style.space(60) : 0)
                  spacing: 2

                  Text {
                    width: parent.width
                    text: String(modelData.text).replace(/\s+/g, " ").trim()
                    color: root.barForeground
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    text: modelData.type === "text" ? "Text" : "Image"
                    color: root.barForeground
                    opacity: 0.4
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: rowHover.containsMouse
                width: copyText.implicitWidth + Style.space(18)
                height: Style.space(22)
                radius: height / 2
                color: root.barForeground

                Text {
                  id: copyText
                  anchors.centerIn: parent
                  text: "Copy"
                  color: Color.background
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                  if (root.bar) root.bar.run("printf %s " + root.shq(modelData.text) + " | wl-copy");
                  if (root.closeAfterAction) root.close();
                }
              }
            }
          }

          Text {
            visible: root.visibleEntries.length === 0
            x: Style.space(16)
            text: root.entries.length === 0 ? "No clips yet — copy something." : "No matches."
            color: root.barForeground
            opacity: 0.45
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        // ---- Footer: count, shortcut, and the settings cog (lower right)
        Item {
          width: parent.width - Style.space(28)
          x: Style.space(14)
          height: Style.space(24)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.entries.length + (root.entries.length === 1 ? " clip" : " clips")
            color: root.barForeground
            opacity: 0.4
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Ctrl+Alt+V"
              color: root.barForeground
              opacity: 0.4
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: false
              anchors.verticalCenter: parent.verticalCenter
              text: ""
              color: root.barForeground
              opacity: cogHover.containsMouse ? 0.9 : 0.45
              font.family: Style.font.family
              font.pixelSize: Style.font.body

              MouseArea {
                id: cogHover
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                onClicked: root.settingsOpen = true
              }
            }
          }
        }

        Item { width: 1; height: Style.space(8) }
      }

      // ================= SETTINGS =================
      Column {
        id: settingsView
        width: parent.width
        spacing: Style.space(8)
        visible: root.settingsOpen

        Item { width: 1; height: Style.space(12) }

        Item {
          width: parent.width - Style.space(28)
          x: Style.space(14)
          height: Style.space(24)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: ""
              color: root.barForeground
              opacity: backHover.containsMouse ? 0.9 : 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Settings"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          MouseArea {
            id: backHover
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.settingsOpen = false
          }
        }

        SectionHeader { text: "GENERAL" }

        SettingRow {
          title: "Launch at login"
          subtitle: "Started by Hyprland via exec-once"
          Toggle {
            checked: root.launchAtLogin
            onToggled: { root.launchAtLogin = checked; root.persist(); }
          }
        }

        SettingRow {
          title: "Global shortcut"
          subtitle: "Owned by the compositor on Wayland — set it in bindings.lua"
          Rectangle {
            width: shortcutText.implicitWidth + Style.space(16)
            height: Style.space(22)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.12)
            Text {
              id: shortcutText
              anchors.centerIn: parent
              text: "Ctrl+Alt+V"
              color: root.barForeground
              opacity: 0.75
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        SectionHeader { text: "HISTORY" }

        SettingRow {
          title: "Maximum saved clips"
          subtitle: "500 ≈ 2 weeks, 1000 ≈ 1 month"
          Rectangle {
            width: Style.space(76)
            height: Style.space(24)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, maxInput.activeFocus ? 0.25 : 0.12)
            TextInput {
              id: maxInput
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: String(root.maxClips)
              color: root.barForeground
              horizontalAlignment: Text.AlignRight
              validator: IntValidator { bottom: 50; top: 1000000 }
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              selectByMouse: true
              onEditingFinished: { root.maxClips = parseInt(text) || root.maxClips; root.persist(); }
            }
          }
        }

        SettingRow {
          title: "Ignore confidential copies"
          subtitle: "Skip x-kde-passwordManagerHint and CLIPBOARD_STATE=sensitive"
          Toggle {
            checked: root.ignoreConfidential
            onToggled: { root.ignoreConfidential = checked; root.persist(); }
          }
        }

        SectionHeader { text: "BEHAVIOR" }

        SettingRow {
          title: "Close popup after action"
          subtitle: "Hide the popup after copying a clip"
          Toggle {
            checked: root.closeAfterAction
            onToggled: { root.closeAfterAction = checked; root.persist(); }
          }
        }

        SettingRow {
          title: "Open at cursor"
          subtitle: "Needs a Hyprland window rule using cursor_x/cursor_y"
          Toggle {
            checked: root.openAtCursor
            onToggled: { root.openAtCursor = checked; root.persist(); }
          }
        }

        SectionHeader { text: "ABOUT" }

        SettingRow {
          title: "Version"
          subtitle: "dev.clipbasket.demo — plugin proof of concept"
          Rectangle {
            width: verText.implicitWidth + Style.space(14)
            height: Style.space(20)
            radius: 4
            color: Qt.rgba(1, 1, 1, 0.06)
            Text {
              id: verText
              anchors.centerIn: parent
              text: "0.2.0"
              color: root.barForeground
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          x: Style.space(14)
          width: parent.width - Style.space(28)
          wrapMode: Text.WordWrap
          text: "Updates, theme and paste-permission settings are absent by design: pacman owns updates, Omarchy owns theming, and Wayland needs no accessibility grant."
          color: root.barForeground
          opacity: 0.35
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item { width: 1; height: Style.space(10) }
      }
    }
  }
}
