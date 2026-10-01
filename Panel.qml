import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon and panel for a local Immich server. All data comes from
// backend/immich-photos as JSON; nothing here talks to Immich or Docker.
Panel {
  id: root
  moduleName: "io.github.badr-emil.immich-photos"
  ipcTarget: "io.github.badr-emil.immich-photos"

  property var status: null
  property bool failed: false
  property string page: "main"
  property string busyAction: ""
  property string actionError: ""
  property var storageCheck: null
  property var backup: null
  property string keyMessage: ""
  property bool copied: false
  property string qrUrl: ""

  readonly property string pluginPath: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  )
  readonly property string backend: pluginPath + "backend/immich-photos"
  readonly property string qrFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-immich-photos/"
    + serverUrl.replace(/[^A-Za-z0-9]/g, "_") + ".png"
  readonly property int refreshInterval: Math.max(5, Number(setting("refreshIntervalSec", 15)) || 15) * 1000
  readonly property bool showCount: setting("showCount", true) === true

  readonly property string serverState: failed ? "error" : (status ? String(status.state) : "loading")
  readonly property bool online: serverState === "online" || serverState === "busy"
  readonly property bool installed: status !== null && status.installed === true
  readonly property int pendingJobs: status && status.jobs ? Number(status.jobs.pending) || 0 : 0
  readonly property var busyQueues: status && status.jobs && status.jobs.queues ? status.jobs.queues : []
  readonly property string serverUrl: status && status.server.url ? String(status.server.url) : ""
  readonly property bool qrReady: serverUrl !== "" && qrUrl === serverUrl
  readonly property bool hasKey: status !== null && status.capabilities.apiKey === true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var numberLocale: Qt.locale()

  readonly property string heroStatusText: {
    if (serverState === "online") return "Online"
    if (serverState === "busy") return "Online · processing " + pendingJobs
    if (serverState === "stopped") return "Stopped"
    if (serverState === "problem") return "Server problem"
    if (serverState === "not-installed") return "Not set up"
    if (serverState === "no-docker") return "Docker missing"
    if (serverState === "error") return "Unavailable"
    return "Checking"
  }

  readonly property string problemText: {
    if (serverState === "stopped") {
      return status.docker.daemonActive
        ? "Immich is not reachable. Its containers are stopped."
        : "Immich is not reachable. The Docker service is not running."
    }
    if (serverState === "problem") {
      if (status.server.portHolder === "foreign")
        return "Port " + status.server.port + " is held by a program of another user, not by Immich. Nothing is sent to it."
      if (status.server.portHolder !== "trusted")
        return "The port is open, but its listener cannot be confirmed as Docker's or yours. Nothing is sent to it."
      return status.server.maintenanceMode
        ? "Immich is in maintenance mode. Open the web interface to end it."
        : "The port is open but Immich does not answer. The server may still be starting."
    }
    if (serverState === "not-installed") return "Immich is not set up on this PC yet. Setup runs in a terminal and asks before every system change."
    if (serverState === "no-docker") return "Docker is not installed: omarchy pkg add docker docker-compose"
    if (serverState === "error") return "The plugin backend did not return a valid answer."
    return ""
  }

  function noteText(note) {
    switch (String(note.code)) {
    case "no-admin": return "No admin account yet. Open the gallery and create one."
    case "no-key": return "Photo and job counts need an API key. Add one under Settings."
    case "key-rejected": return "Immich rejects the API key. Create a new one and add it under Settings."
    case "key-permissions": return "The API key lacks the permission to read statistics."
    case "not-mounted": return "The disk for the storage location is not mounted."
    case "no-media-folder": return "The media folder does not exist."
    case "low-space": return "Storage is running low."
    }
    return String(note.text || "")
  }

  // "thumbnailGeneration" -> "Thumbnail generation"
  function queueLabel(name) {
    var words = String(name || "").replace(/([a-z0-9])([A-Z])/g, "$1 $2").toLowerCase()
    return words.charAt(0).toUpperCase() + words.slice(1)
  }

  function formatBytes(value) {
    if (value === null || value === undefined) return "–"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var number = Number(value)
    var index = 0
    while (number >= 1024 && index < units.length - 1) {
      number /= 1024
      index++
    }
    return number.toLocaleString(root.numberLocale, "f", number >= 100 || index === 0 ? 0 : 1) + " " + units[index]
  }

  function formatCount(value) {
    return Number(value).toLocaleString(root.numberLocale, "f", 0)
  }

  // Immich refreshes a device's timestamp at most once an hour, so anything
  // finer than hours would be invented precision.
  function formatLastSeen(iso) {
    var then = new Date(iso)
    if (isNaN(then.getTime())) return ""
    var hours = Math.floor((Date.now() - then.getTime()) / 3600000)
    if (hours < 1) return "within the last hour"
    if (hours < 24) return "about " + hours + (hours === 1 ? " hour ago" : " hours ago")
    var days = Math.floor(hours / 24)
    return days + (days === 1 ? " day ago" : " days ago")
  }

  function formatDate(iso) {
    var date = new Date(iso)
    return isNaN(date.getTime()) ? "" : date.toLocaleString(root.numberLocale, Locale.ShortFormat)
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function applyStatus(output) {
    try {
      var result = JSON.parse(String(output).trim())
      if (!result || !result.server || !result.capabilities) throw new Error("incomplete")
      status = result
      failed = false
    } catch (error) {
      failed = true
    }
    if (opened && serverUrl !== "" && serverUrl !== qrUrl && !qrProcess.running) qrProcess.running = true
  }

  function serverAction(action) {
    if (actionProcess.running) return
    actionError = ""
    busyAction = action
    actionProcess.command = [backend, "server", action]
    actionProcess.running = true
  }

  function openGallery() {
    Quickshell.execDetached([backend, "open"])
    close()
  }

  function copyAddress() {
    if (serverUrl === "") return
    Quickshell.execDetached(["wl-copy", serverUrl])
    copied = true
    copiedReset.restart()
  }

  function inTerminal(args) {
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      Util.shellQuote(backend) + " " + args
    ])
    close()
  }

  function runInstaller() {
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      Util.shellQuote(pluginPath + "scripts/install.sh")
    ])
    close()
  }

  function checkStorage() {
    if (!storageProcess.running) storageProcess.running = true
  }

  function checkBackup() {
    if (!backupProcess.running) backupProcess.running = true
  }

  function saveKey() {
    var key = keyField.text.trim()
    if (key === "" || keyProcess.running) return
    keyMessage = "Checking…"
    keyProcess.secret = key
    keyProcess.command = [backend, "api-key", "set"]
    keyProcess.running = true
  }

  function clearKey() {
    if (keyProcess.running) return
    keyProcess.secret = ""
    keyProcess.command = [backend, "api-key", "clear"]
    keyProcess.running = true
  }

  function show(name) {
    page = name
    if (name === "storage") checkStorage()
    if (name === "backup") checkBackup()
  }

  onOpenedChanged: {
    if (opened) {
      page = "main"
      actionError = ""
      keyMessage = ""
      refresh()
    } else {
      keyField.text = ""
    }
  }

  implicitWidth: button.implicitWidth + (countLabel.visible ? countLabel.implicitWidth + Style.spacing.sm : 0)
  implicitHeight: button.implicitHeight

  Process {
    id: statusProcess
    command: [root.backend, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.failed = true
    }
  }

  Process {
    id: actionProcess
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.actionError = exitCode === 126 || exitCode === 127
          ? "Cancelled: the password prompt was not confirmed."
          : (String(actionStderr.text).trim().split("\n")[0] || "The action failed.")
      }
      root.busyAction = ""
      root.refresh()
    }
  }

  Process {
    id: qrProcess
    command: [root.backend, "address", "--qr-file", root.qrFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.qrUrl = String(text).trim()
    }
  }

  Process {
    id: storageProcess
    command: [root.backend, "storage", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.storageCheck = JSON.parse(String(text).trim()) } catch (error) { root.storageCheck = null }
      }
    }
  }

  Process {
    id: backupProcess
    command: [root.backend, "backup", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.backup = JSON.parse(String(text).trim()) } catch (error) { root.backup = null }
      }
    }
  }

  // The key goes to the backend on stdin, never as an argument, so it does
  // not show up in the process list.
  Process {
    id: keyProcess
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      if (secret !== "") write(secret + "\n")
      secret = ""
    }
    stderr: StdioCollector { id: keyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.keyMessage = ""
        keyField.text = ""
      } else {
        var reason = String(keyStderr.text)
        root.keyMessage = reason.indexOf("rejected") >= 0
          ? "Immich rejects this key. Nothing was saved."
          : "This does not look like an Immich API key. Nothing was saved."
      }
      root.refresh()
    }
  }

  Timer {
    interval: root.busyAction !== "" || root.opened || root.pendingJobs > 0 ? 2000 : root.refreshInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // omarchy-shell io.github.badr-emil.immich-photos.page go setup
  IpcHandler {
    target: root.ipcTarget + ".page"

    function go(name: string): void {
      if (["main", "setup", "storage", "backup", "settings"].indexOf(name) < 0) return
      root.open()
      root.show(name)
    }
  }

  Timer {
    id: copiedReset
    interval: 2000
    onTriggered: root.copied = false
  }

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: root.serverState === "problem" || root.serverState === "error" ? "󰀦" : "󰋹"
          color: root.serverState === "problem" || root.serverState === "error" ? root.urgent : button.foreground
          opacity: root.online || root.serverState === "problem" || root.serverState === "error" ? 1 : 0.5
          font.family: button.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
    tooltipText: root.opened ? "" : "Immich Photos · " + root.heroStatusText
      + (root.serverUrl !== "" && root.online ? "\n" + root.serverUrl : "")
      + "\n\nLeft: panel · Right: open gallery"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.online) root.openGallery()
      else root.toggle()
    }
  }

  // Jobs the server still has to work through after an upload. What is left
  // on the phone is known only to the phone, so it is not shown.
  Text {
    id: countLabel
    visible: root.showCount && root.pendingJobs > 0 && !(root.bar && root.bar.vertical)
    anchors.left: button.right
    anchors.leftMargin: -Style.spacing.xs
    anchors.verticalCenter: button.verticalCenter
    text: String(root.pendingJobs)
    color: button.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption

    MouseArea {
      anchors.fill: parent
      onClicked: root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: keyField.activeFocus
      onCloseRequested: root.page === "main" ? root.close() : root.show("main")
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰋹"
            color: root.foreground
            opacity: root.online ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroActions.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.page === "setup" ? "Connect phone"
                : root.page === "storage" ? "Storage"
                : root.page === "backup" ? "Backup"
                : root.page === "settings" ? "Settings"
                : "Immich Photos"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: root.serverState === "problem" || root.serverState === "error" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              visible: root.page !== "main"
              iconText: "󰁍"
              tooltipText: "Back"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.show("main")
            }

            PanelActionButton {
              visible: root.page === "main" && root.online
              iconText: "󰏌"
              tooltipText: "Open gallery"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openGallery()
            }

            PanelActionButton {
              visible: root.page === "main"
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }
        }

        // ---------- Problem and running action ----------
        Hint {
          visible: root.problemText !== "" && root.busyAction === ""
          text: root.problemText
          color: root.urgent
        }

        Hint {
          visible: root.busyAction !== ""
          text: root.busyAction === "stop" ? "Stopping Immich…"
            : root.busyAction === "restart" ? "Restarting Immich…"
            : "Starting Immich. This can take a minute…"
        }

        Hint {
          visible: root.actionError !== ""
          text: root.actionError
          color: root.urgent
        }

        Button {
          visible: root.page === "main" && root.serverState === "stopped" && root.busyAction === ""
          width: parent.width
          iconText: "󰐊"
          text: "Start Immich"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.serverAction("start")
        }

        Button {
          visible: root.page === "main" && root.serverState === "not-installed" && root.busyAction === ""
          width: parent.width
          iconText: "󰆍"
          text: "Set up Immich"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.runInstaller()
        }

        // ---------- Main page ----------
        Column {
          visible: root.page === "main" && root.installed
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: root.status ? root.status.notes : []
            Hint {
              required property var modelData
              text: root.noteText(modelData)
            }
          }

          Column {
            visible: root.status !== null && root.status.library !== null
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: root.status && root.status.library && root.status.library.scope === "user"
                ? "LIBRARY · YOUR ACCOUNT" : "LIBRARY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            InfoRow {
              label: "Photos"
              value: root.status && root.status.library ? root.formatCount(root.status.library.photos) : ""
            }

            InfoRow {
              label: "Videos"
              value: root.status && root.status.library ? root.formatCount(root.status.library.videos) : ""
            }

            InfoRow {
              visible: root.status !== null && root.status.lastActivity !== null
              label: "Phone last seen"
              value: root.status && root.status.lastActivity ? root.formatLastSeen(root.status.lastActivity) : ""
            }
          }

          // What the server is working on right now, refreshed every two seconds
          // while the panel is open or work is pending.
          Column {
            visible: root.status !== null && root.status.jobs !== null
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: root.pendingJobs > 0 ? "JOBS · " + root.formatCount(root.pendingJobs) + " PENDING" : "JOBS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            InfoRow {
              visible: root.pendingJobs === 0
              label: "Server"
              value: "idle, nothing to process"
            }

            Repeater {
              model: root.busyQueues.slice(0, 4)
              InfoRow {
                required property var modelData
                label: root.queueLabel(modelData.name) + (modelData.paused ? " (paused)" : "")
                value: root.formatCount(modelData.active) + " running · " + root.formatCount(modelData.waiting) + " waiting"
              }
            }

            InfoRow {
              visible: root.busyQueues.length > 4
              label: "Other queues"
              value: String(root.busyQueues.length - 4)
            }

            InfoRow {
              visible: root.status !== null && root.status.jobs !== null && root.status.jobs.failed > 0
              label: "Failed so far"
              value: root.status && root.status.jobs ? root.formatCount(root.status.jobs.failed) : ""
            }
          }

          Column {
            visible: root.status !== null && root.status.storage !== null
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "STORAGE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            UsageBar {
              storage: root.status ? root.status.storage : null
            }

            InfoRow {
              visible: root.status !== null && root.status.storage !== null && root.status.storage.libraryBytes !== null
              label: "Of which Immich"
              value: root.status && root.status.storage ? root.formatBytes(root.status.storage.libraryBytes) : ""
            }

            InfoRow {
              label: "Location"
              value: root.status && root.status.storage ? String(root.status.storage.path) : ""
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Button {
              visible: root.online
              width: parent.width
              leftAlign: true
              iconText: "󰋹"
              text: "Open gallery"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openGallery()
            }

            Button {
              width: parent.width
              leftAlign: true
              iconText: "󰐲"
              text: "Connect phone"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.show("setup")
            }

            Button {
              width: parent.width
              leftAlign: true
              iconText: "󰋊"
              text: "Storage"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.show("storage")
            }

            Button {
              width: parent.width
              leftAlign: true
              iconText: "󰁯"
              text: "Backup status"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.show("backup")
            }

            Button {
              width: parent.width
              leftAlign: true
              iconText: "󰒓"
              text: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.show("settings")
            }
          }
        }

        // ---------- Phone setup ----------
        Column {
          visible: root.page === "setup"
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.foreground }

          Hint {
            visible: root.serverUrl === ""
            text: "This PC has no address in the local network. Connect it to the Wi-Fi your phone uses."
            color: root.urgent
          }

          Column {
            visible: root.serverUrl !== ""
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SERVER ADDRESS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.serverUrl
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.WrapAnywhere
            }

            Button {
              width: parent.width
              leftAlign: true
              iconText: root.copied ? "󰄬" : "󰆏"
              text: root.copied ? "Copied" : "Copy address"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.copyAddress()
            }

            // QR codes are scanned dark on light, whatever the theme.
            Rectangle {
              visible: root.qrReady
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(170)
              height: width
              color: "white"

              Image {
                anchors.fill: parent
                anchors.margins: Style.space(6)
                source: root.qrReady ? "file://" + root.qrFile : ""
                cache: false
                smooth: false
                fillMode: Image.PreserveAspectFit
              }
            }

            Hint {
              text: "The QR code contains only this address, no password."
            }
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "HOW TO"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Hint {
            color: root.foreground
            text: "1. Install the Immich app on your phone (App Store or Google Play)\n"
              + "2. Enter the server address or scan the QR code\n"
              + "3. Log in with your Immich account\n"
              + "4. Open Backup, choose albums, turn Backup on"
          }

          Hint {
            text: "The phone has to be in the same Wi-Fi. iOS and Android decide when apps may work in the background. "
              + "The backup is reliable while the Immich app is open."
          }
        }

        // ---------- Storage ----------
        Column {
          visible: root.page === "storage"
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.foreground }

          Hint {
            visible: root.storageCheck === null
            text: storageProcess.running ? "Checking storage location…" : "No storage location known."
          }

          Column {
            visible: root.storageCheck !== null
            width: parent.width
            spacing: Style.space(6)

            InfoRow {
              label: "Location"
              value: root.storageCheck ? String(root.storageCheck.path) : ""
            }

            UsageBar {
              storage: root.storageCheck
            }

            InfoRow {
              label: "Free"
              value: root.storageCheck ? root.formatBytes(root.storageCheck.freeBytes) : ""
            }

            InfoRow {
              visible: root.status !== null && root.status.storage !== null && root.status.storage.libraryBytes !== null
              label: "Of which Immich"
              value: root.status && root.status.storage ? root.formatBytes(root.status.storage.libraryBytes) : ""
            }

            InfoRow {
              label: "Filesystem"
              value: root.storageCheck ? String(root.storageCheck.filesystem || "unknown") : ""
            }

            InfoRow {
              label: "Disk"
              value: root.storageCheck && root.storageCheck.mounted
                ? "mounted at " + root.storageCheck.mountPoint : "not mounted"
              alert: root.storageCheck !== null && !root.storageCheck.mounted
            }

            InfoRow {
              label: "Check"
              value: root.storageCheck && root.storageCheck.ok ? "suitable" : "not suitable"
              alert: root.storageCheck !== null && !root.storageCheck.ok
            }

            Repeater {
              model: root.storageCheck ? root.storageCheck.errors : []
              Hint {
                required property string modelData
                text: modelData
                color: root.urgent
              }
            }
          }

          Button {
            width: parent.width
            leftAlign: true
            iconText: "󰑐"
            text: storageProcess.running ? "Checking…" : "Check storage location"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.checkStorage()
          }

          Hint {
            text: "The location of an existing library is not changed here. "
              + "Moving it follows the steps in docs/storage.md: stop, copy, verify, switch."
          }
        }

        // ---------- Backup ----------
        Column {
          visible: root.page === "backup"
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.foreground }

          InfoRow {
            label: "Photos and videos"
            value: root.backup && root.backup.media.configured ? "configured" : "not configured"
            alert: root.backup !== null && !root.backup.media.configured
          }

          InfoRow {
            label: "Database dumps"
            value: root.backup && root.backup.database.configured
              ? root.backup.database.count + ", latest " + root.formatDate(root.backup.database.latest)
              : "none yet"
          }

          InfoRow {
            label: "Last verified backup"
            value: root.backup && root.backup.lastVerified ? root.formatDate(root.backup.lastVerified) : "never"
          }

          Button {
            width: parent.width
            leftAlign: true
            iconText: "󰑐"
            text: backupProcess.running ? "Checking…" : "Check backup"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.checkBackup()
          }

          Hint {
            color: root.urgent
            visible: root.backup !== null && !root.backup.media.configured
            text: "Your photos exist on this one disk only. If it fails, they are gone."
          }

          Hint {
            text: "Immich dumps its database every night, but onto the same disk as the photos. "
              + "That does not replace a backup of the photos and videos. This version cannot set up "
              + "a backup target yet; see docs/backup.md."
          }
        }

        // ---------- Settings ----------
        Column {
          visible: root.page === "settings"
          width: parent.width
          spacing: Style.space(6)

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "SERVER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          InfoRow {
            visible: root.status !== null && root.status.server.version !== null
            label: "Immich"
            value: root.status && root.status.server.version ? "v" + root.status.server.version : ""
          }

          InfoRow {
            label: "Docker"
            value: root.status && root.status.docker.daemonActive ? "running" : "not running"
            alert: root.status !== null && !root.status.docker.daemonActive
          }

          InfoRow {
            label: "Database"
            value: root.status && root.status.database.status === "reachable"
              ? (root.status.database.inferred ? "reachable (server answers)" : "reachable")
              : "unknown"
          }

          Button {
            visible: !root.online
            enabled: root.busyAction === "" && root.installed
            width: parent.width
            leftAlign: true
            iconText: "󰐊"
            text: "Start"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.serverAction("start")
          }

          Button {
            visible: root.online
            enabled: root.busyAction === ""
            width: parent.width
            leftAlign: true
            iconText: "󰜉"
            text: "Restart"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.serverAction("restart")
          }

          Button {
            visible: root.online
            enabled: root.busyAction === ""
            width: parent.width
            leftAlign: true
            iconText: "󰓛"
            text: "Stop"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.serverAction("stop")
          }

          Button {
            enabled: root.installed
            width: parent.width
            leftAlign: true
            iconText: "󰈙"
            text: "Show logs"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.inTerminal("server logs")
          }

          Button {
            width: parent.width
            leftAlign: true
            iconText: "󰆍"
            text: "Diagnostics"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.inTerminal("diagnostics")
          }

          Hint {
            visible: root.status !== null && !root.status.capabilities.dockerDirect
            text: "Start, stop and logs need administrator rights. A password prompt will appear."
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: root.hasKey ? "API KEY · STORED" : "API KEY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: keyField
              Layout.fillWidth: true
              foreground: root.foreground
              password: true
              placeholderText: root.hasKey ? "Enter a new key" : "Paste the key from Immich"
              inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
              onAccepted: root.saveKey()
              Keys.onEscapePressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            PanelActionButton {
              iconText: "󰄬"
              tooltipText: "Check and save key"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: keyField.text.trim() !== ""
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.saveKey()
            }
          }

          Hint {
            visible: root.keyMessage !== ""
            text: root.keyMessage
            color: root.keyMessage.indexOf("…") >= 0 ? root.dim : root.urgent
          }

          Button {
            visible: root.hasKey
            width: parent.width
            leftAlign: true
            iconText: "󰌆"
            text: "Remove key"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.clearKey()
          }

          Hint {
            text: "In Immich: Account Settings → API Keys → New API Key. Required permissions: "
              + "asset.statistics, server.statistics, queue.read, session.read; for the photo browser also "
              + "asset.read, asset.view, asset.update, asset.delete, album.read, album.create, albumAsset.create. "
              + "The key is stored only in ~/.config/omarchy-immich-photos/api-key (readable by you alone)."
          }
        }
      }
    }
  }

  component Hint: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  component InfoRow: Item {
    id: infoRow
    property string label: ""
    property string value: ""
    property bool alert: false

    width: parent ? parent.width : 0
    implicitHeight: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight) + Style.spacing.xs

    Text {
      id: infoLabel
      anchors.left: parent.left
      anchors.top: parent.top
      textFormat: Text.PlainText
      text: infoRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: infoValue
      anchors.right: parent.right
      anchors.top: parent.top
      width: parent.width - infoLabel.implicitWidth - Style.space(12)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: infoRow.value
      color: infoRow.alert ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WrapAnywhere
    }
  }

  // Fill level of the disk that holds the library, as `df` would report it.
  component UsageBar: Column {
    id: usageBar
    property var storage: null
    readonly property bool known: storage !== null && storage !== undefined
      && storage.totalBytes !== null && storage.totalBytes > 0
    readonly property real fraction: known ? Math.max(0, Math.min(1, storage.usedBytes / storage.totalBytes)) : 0

    visible: known
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Rectangle {
      width: parent.width
      height: Style.space(6)
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, 0.15)

      Rectangle {
        width: Math.max(usageBar.fraction > 0 ? Style.space(2) : 0, parent.width * usageBar.fraction)
        height: parent.height
        radius: parent.radius
        color: usageBar.fraction > 0.9 ? root.urgent : root.foreground
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: usageBar.known
        ? root.formatBytes(usageBar.storage.usedBytes) + " / " + root.formatBytes(usageBar.storage.totalBytes)
          + " used"
        : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
