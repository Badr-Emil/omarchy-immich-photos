import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Keyboard-driven photo browser. Opened with
//   omarchy-shell shell toggle io.github.badr-emil.iphone-photos
// All data and every change go through `backend/iphone-photos gallery`, which
// talks to the Immich API; images are shown from its local cache.
Item {
  id: root

  property bool opened: false
  property var items: []
  property int index: 0
  property int nextPage: 1
  property bool loading: false
  // grid | view | confirm | albums | newAlbum
  property string mode: "grid"
  property string returnMode: "grid"
  property string error: ""
  property string notice: ""
  property var marked: ({})
  property int markedCount: 0
  property var previews: ({})
  property var albums: []
  property int albumIndex: 0
  property var lastTrashed: []

  readonly property string pluginPath: decodeURIComponent(
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  )
  readonly property string backend: pluginPath + "backend/iphone-photos"
  readonly property var current: items.length > 0 && index < items.length ? items[index] : null
  readonly property bool browsing: mode === "grid" || mode === "view"
  // A dialog keeps showing whatever was behind it.
  readonly property bool viewing: mode === "view" || (!browsing && returnMode === "view")

  readonly property color foreground: Color.popups.text
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.imagePicker.selectedBorder
  readonly property string fontFamily: Style.font.family

  // Lifecycle hooks called by omarchy-shell summon / hide / toggle.
  function open(payload) {
    opened = true
    mode = "grid"
    notice = ""
    if (items.length === 0 || error !== "") reload()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  function reload() {
    items = []
    index = 0
    nextPage = 1
    error = ""
    clearMarks()
    loadMore()
  }

  function loadMore() {
    if (loading || nextPage === 0) return
    loading = true
    listProcess.command = [backend, "gallery", "list", String(nextPage)]
    listProcess.running = true
  }

  function applyList(text) {
    loading = false
    var result = parse(text)
    if (!result) return
    items = items.concat(result.items || [])
    nextPage = result.nextPage || 0
  }

  // Backend answers are JSON; an `error` object carries a message for the user.
  function parse(text) {
    try {
      var result = JSON.parse(String(text).trim())
      if (result && result.error) {
        error = String(result.error.message || "The gallery backend reported an error.")
        return null
      }
      return result
    } catch (exception) {
      error = "The gallery backend did not return a valid answer."
      return null
    }
  }

  function select(next) {
    if (items.length === 0) return
    index = Math.max(0, Math.min(items.length - 1, next))
    grid.positionViewAtIndex(index, GridView.Contain)
    if (items.length - index < grid.columns * 4) loadMore()
    if (mode === "view") loadPreviews()
  }

  function clearMarks() {
    marked = ({})
    markedCount = 0
  }

  function toggleMark() {
    if (!current) return
    var next = ({})
    for (var id in marked) next[id] = true
    if (next[current.id]) delete next[current.id]
    else next[current.id] = true
    marked = next
    markedCount = Object.keys(next).length
  }

  // The marked photos, or the one under the cursor when nothing is marked.
  function targets() {
    var ids = Object.keys(marked)
    if (ids.length > 0) return ids
    return current ? [current.id] : []
  }

  function describe(count) {
    return count === 1 ? "1 item" : count + " items"
  }

  function loadPreviews() {
    if (previewProcess.running || !current) return
    var wanted = []
    for (var offset = 0; offset <= 2; offset++) {
      var candidates = offset === 0 ? [index] : [index + offset, index - offset]
      for (var i = 0; i < candidates.length; i++) {
        var item = items[candidates[i]]
        if (item && item.type === "image" && !previews[item.id]) wanted.push(item.id)
      }
    }
    if (wanted.length === 0) return
    previewProcess.command = [backend, "gallery", "preview"].concat(wanted)
    previewProcess.running = true
  }

  function applyPreviews(text) {
    var result = parse(text)
    if (!result || !result.previews) return
    var next = ({})
    for (var id in previews) next[id] = previews[id]
    for (var fresh in result.previews) next[fresh] = result.previews[fresh]
    previews = next
    loadPreviews()
  }

  function activate() {
    if (!current) return
    if (current.type === "video") {
      Quickshell.execDetached([backend, "gallery", "play", current.id])
      close()
    } else if (mode === "grid") {
      mode = "view"
      loadPreviews()
    } else {
      mode = "grid"
    }
  }

  function run(kind, args, ids) {
    if (actionProcess.running) return
    notice = ""
    actionProcess.kind = kind
    actionProcess.ids = ids
    actionProcess.command = [backend, "gallery"].concat(args)
    actionProcess.running = true
  }

  function removeFromList(ids) {
    var gone = ({})
    for (var i = 0; i < ids.length; i++) gone[ids[i]] = true
    items = items.filter(function(item) { return !gone[item.id] })
    index = Math.max(0, Math.min(items.length - 1, index))
    clearMarks()
    if (items.length === 0 && mode === "view") mode = "grid"
  }

  function askTrash() {
    if (targets().length === 0) return
    returnMode = mode
    mode = "confirm"
  }

  function trash() {
    var ids = targets()
    mode = returnMode
    run("trash", ["trash"].concat(ids), ids)
  }

  function undoTrash() {
    if (lastTrashed.length === 0) return
    run("restore", ["restore"].concat(lastTrashed), lastTrashed)
  }

  function toggleFavorite() {
    if (!current) return
    var ids = targets()
    run(current.favorite ? "unfavorite" : "favorite", ["favorite", current.favorite ? "off" : "on"].concat(ids), ids)
  }

  function archive() {
    var ids = targets()
    if (ids.length > 0) run("archive", ["archive", "on"].concat(ids), ids)
  }

  function chooseAlbum() {
    if (targets().length === 0 || albumsProcess.running) return
    returnMode = mode
    albumsProcess.running = true
  }

  function addToAlbum() {
    var album = albums[albumIndex]
    if (!album) return
    var ids = targets()
    mode = returnMode
    run("album:" + album.name, ["album-add", album.id].concat(ids), ids)
  }

  function createAlbum() {
    var name = albumName.text.trim()
    if (name === "") return
    var ids = targets()
    mode = returnMode
    run("album:" + name, ["album-create", name].concat(ids), ids)
  }

  function applyAction(kind, ids, text) {
    if (!parse(text)) return
    if (kind === "trash") {
      lastTrashed = ids
      removeFromList(ids)
      notice = "Moved " + describe(ids.length) + " to the Immich trash · u to undo"
    } else if (kind === "restore") {
      lastTrashed = []
      notice = "Restored " + describe(ids.length)
      reload()
    } else if (kind === "archive") {
      removeFromList(ids)
      notice = "Archived " + describe(ids.length)
    } else if (kind === "favorite" || kind === "unfavorite") {
      var changed = ({})
      for (var i = 0; i < ids.length; i++) changed[ids[i]] = true
      items = items.map(function(item) {
        if (!changed[item.id]) return item
        var copy = ({})
        for (var key in item) copy[key] = item[key]
        copy.favorite = kind === "favorite"
        return copy
      })
      clearMarks()
    } else if (kind.indexOf("album:") === 0) {
      clearMarks()
      notice = "Added " + describe(ids.length) + " to “" + kind.slice(6) + "”"
    }
  }

  function formatDate(iso) {
    var date = new Date(iso)
    return isNaN(date.getTime()) ? "" : date.toLocaleDateString(Qt.locale(), Locale.LongFormat)
  }

  function handleKey(event) {
    var key = event.key
    var shift = event.modifiers & Qt.ShiftModifier
    event.accepted = true

    if (mode === "confirm") {
      if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Y) trash()
      else if (key === Qt.Key_Escape || key === Qt.Key_N || key === Qt.Key_Q) mode = returnMode
      return
    }
    if (mode === "albums") {
      if (key === Qt.Key_Escape || key === Qt.Key_Q) mode = returnMode
      else if (key === Qt.Key_Down || key === Qt.Key_J) albumIndex = Math.min(albums.length - 1, albumIndex + 1)
      else if (key === Qt.Key_Up || key === Qt.Key_K) albumIndex = Math.max(0, albumIndex - 1)
      else if (key === Qt.Key_Return || key === Qt.Key_Enter) addToAlbum()
      else if (key === Qt.Key_N) {
        albumName.text = ""
        mode = "newAlbum"
        albumName.forceActiveFocus()
      }
      return
    }

    if (key === Qt.Key_Escape || key === Qt.Key_Q) {
      if (mode === "view") mode = "grid"
      else if (markedCount > 0) clearMarks()
      else close()
    } else if (error !== "") {
      if (key === Qt.Key_R) reload()
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) activate()
    else if (key === Qt.Key_Right || key === Qt.Key_L) select(index + 1)
    else if (key === Qt.Key_Left || key === Qt.Key_H) select(index - 1)
    else if (key === Qt.Key_Down || key === Qt.Key_J) select(index + (mode === "view" ? 1 : grid.columns))
    else if (key === Qt.Key_Up || key === Qt.Key_K) select(index - (mode === "view" ? 1 : grid.columns))
    else if (key === Qt.Key_PageDown) select(index + grid.columns * grid.visibleRows)
    else if (key === Qt.Key_PageUp) select(index - grid.columns * grid.visibleRows)
    else if (key === Qt.Key_Home || (key === Qt.Key_G && !shift)) select(0)
    else if (key === Qt.Key_End || (key === Qt.Key_G && shift)) select(items.length - 1)
    else if (key === Qt.Key_Space) {
      toggleMark()
      select(index + 1)
    } else if (key === Qt.Key_D || key === Qt.Key_Delete) askTrash()
    else if (key === Qt.Key_U) undoTrash()
    else if (key === Qt.Key_F) toggleFavorite()
    else if (key === Qt.Key_A) archive()
    else if (key === Qt.Key_M) chooseAlbum()
    else if (key === Qt.Key_R) reload()
    else if (key === Qt.Key_O) {
      Quickshell.execDetached([backend, "open"])
      close()
    } else event.accepted = false
  }

  Process {
    id: listProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyList(text)
    }
  }

  Process {
    id: previewProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPreviews(text)
    }
  }

  Process {
    id: albumsProcess
    command: [root.backend, "gallery", "albums"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parse(text)
        if (!result) return
        root.albums = result.albums || []
        root.albumIndex = 0
        root.mode = "albums"
      }
    }
  }

  Process {
    id: actionProcess
    property string kind: ""
    property var ids: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAction(actionProcess.kind, actionProcess.ids, text)
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-iphone-photos"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.imagePicker.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      id: card
      anchors.fill: parent
      anchors.margins: Style.space(36)
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: Math.max(1, Style.space(2))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }

      Item {
        id: keys
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        focus: true
        Keys.onPressed: function(event) { root.handleKey(event) }

        // ---------- Header ----------
        RowLayout {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: "󰋹"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            textFormat: Text.PlainText
            text: "iPhone Photos"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.current
              ? root.current.name + " · " + root.formatDate(root.current.date)
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: root.markedCount > 0
            textFormat: Text.PlainText
            text: root.markedCount + " marked"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.items.length === 0 ? ""
              : (root.index + 1) + " / " + root.items.length + (root.nextPage !== 0 ? "+" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ---------- Footer ----------
        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.error !== "" ? ""
            : root.notice !== "" ? root.notice
            : root.viewing
              ? "←→ browse · space mark · d trash · m album · f favorite · a archive · o Immich · esc back"
              : "↵ open · arrows / hjkl move · space mark · d trash · m album · f favorite · a archive · u undo · r reload · o Immich · esc close"
          color: root.notice !== "" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---------- Grid ----------
        GridView {
          id: grid
          readonly property int columns: Math.max(1, Math.floor(width / Style.space(190)))
          readonly property int visibleRows: Math.max(1, Math.floor(height / cellHeight))

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.bottom: footer.top
          anchors.topMargin: Style.space(12)
          anchors.bottomMargin: Style.space(10)
          visible: !root.viewing
          clip: true
          cellWidth: Math.floor(width / columns)
          cellHeight: cellWidth
          model: root.items.length
          currentIndex: root.index
          interactive: false
          cacheBuffer: cellHeight * 2
          highlightFollowsCurrentItem: false
          // An integer model resets the view when it changes; put the cursor back in sight.
          onCountChanged: Qt.callLater(function() { grid.positionViewAtIndex(root.index, GridView.Contain) })

          delegate: Item {
            id: cell
            required property int index
            readonly property var photo: root.items[index]
            readonly property bool selected: index === root.index
            readonly property bool isMarked: photo !== undefined && root.marked[photo.id] === true

            width: grid.cellWidth
            height: grid.cellHeight

            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.space(4)
              color: Util.alpha(root.foreground, 0.06)

              Image {
                anchors.fill: parent
                source: cell.photo && cell.photo.thumb ? Util.fileUrl(cell.photo.thumb) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: grid.cellWidth
                sourceSize.height: grid.cellHeight
              }

              Rectangle {
                anchors.fill: parent
                color: Util.alpha(Color.background, cell.isMarked ? 0.45 : 0)
              }

              Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: cell.selected ? root.accent : Color.imagePicker.unselectedBorder
                border.width: cell.selected ? Math.max(2, Style.space(3)) : 1
              }

              Badge {
                visible: cell.isMarked
                anchors.left: parent.left
                anchors.top: parent.top
                text: "󰗠"
                tint: root.accent
              }

              Badge {
                visible: cell.photo !== undefined && cell.photo.favorite === true
                anchors.right: parent.right
                anchors.top: parent.top
                text: "󰋑"
              }

              Badge {
                visible: cell.photo !== undefined && cell.photo.type === "video"
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                text: "󰐌" + (cell.photo && cell.photo.duration ? " " + cell.photo.duration : "")
              }
            }
          }
        }

        // ---------- Single photo ----------
        Item {
          anchors.fill: grid
          visible: root.viewing

          Image {
            anchors.fill: parent
            // The thumbnail fills in until the larger preview has been fetched.
            source: !root.current ? ""
              : Util.fileUrl(root.previews[root.current.id] || root.current.thumb || "")
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
          }

          Badge {
            visible: root.current !== null && root.current.favorite === true
            anchors.right: parent.right
            anchors.top: parent.top
            text: "󰋑"
          }

          Badge {
            visible: root.current !== null && root.marked[root.current.id] === true
            anchors.left: parent.left
            anchors.top: parent.top
            text: "󰗠"
            tint: root.accent
          }

          Badge {
            visible: root.current !== null && root.current.type === "video"
            anchors.centerIn: parent
            text: "󰐌  ↵ play"
          }
        }

        // ---------- Empty, loading, error ----------
        Text {
          anchors.centerIn: grid
          width: Math.min(grid.width, Style.space(520))
          visible: root.error !== "" || root.items.length === 0
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.error !== "" ? root.error + "\n\nr retry · esc close"
            : root.loading ? "Loading photos…" : "No photos yet."
          color: root.error !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        // ---------- Dialogs ----------
        Rectangle {
          anchors.centerIn: parent
          visible: !root.browsing
          width: Math.min(parent.width, Style.space(420))
          height: dialog.implicitHeight + Style.spacing.panelPadding * 2
          color: Color.popups.background
          border.color: Color.popups.border
          border.width: Math.max(1, Style.space(2))
          radius: Style.cornerRadius

          Column {
            id: dialog
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.spacing.panelPadding
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.mode === "confirm"
                ? "Move " + root.describe(root.targets().length) + " to the Immich trash?"
                : root.mode === "newAlbum" ? "New album for " + root.describe(root.targets().length)
                : "Add " + root.describe(root.targets().length) + " to an album"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              visible: root.mode === "confirm"
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Immich keeps trashed items for 30 days by default; u restores the last ones."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              visible: root.mode === "albums"
              width: parent.width
              spacing: Style.space(2)

              Text {
                visible: root.albums.length === 0
                textFormat: Text.PlainText
                text: "No albums yet."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.albums
                Rectangle {
                  required property var modelData
                  required property int index
                  // Keep the list short enough for the screen: a window around the cursor.
                  visible: Math.abs(index - root.albumIndex) <= 6
                  width: parent.width
                  height: albumLabel.implicitHeight + Style.spacing.controlPaddingY * 2
                  color: index === root.albumIndex ? Style.selectedFill : "transparent"
                  radius: Style.cornerRadius

                  Text {
                    id: albumLabel
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Style.spacing.controlPaddingX
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: "󰋪  " + modelData.name
                      + (modelData.count !== null && modelData.count !== undefined ? "  (" + modelData.count + ")" : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }

            TextField {
              id: albumName
              visible: root.mode === "newAlbum"
              width: parent.width
              foreground: root.foreground
              placeholderText: "Album name"
              onAccepted: root.createAlbum()
              Keys.onEscapePressed: function(event) {
                root.mode = "albums"
                keys.forceActiveFocus()
                event.accepted = true
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.mode === "confirm" ? "↵ or y move to trash · esc cancel"
                : root.mode === "newAlbum" ? "↵ create and add · esc back"
                : "↑↓ choose · ↵ add · n new album · esc cancel"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  onModeChanged: if (mode !== "newAlbum") keys.forceActiveFocus()

  component Badge: Item {
    property alias text: badgeText.text
    property color tint: root.foreground

    width: badgeText.implicitWidth + Style.space(10)
    height: badgeText.implicitHeight + Style.space(6)

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.72)
    }

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
