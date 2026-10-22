import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property real artworkScale: 0.9
  property color color: Commons.Color.foreground
  property bool warning: false
  property color badgeColor: Commons.Color.urgent

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // Three stacked shelves — a compact stand-in for Seafile’s sync libraries.
  Shape {
    anchors.centerIn: parent
    width: root.iconSize
    height: root.iconSize
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    scale: root.artworkScale

    Shelf { cy: height * 0.28; shelfWidth: width * 0.62 }
    Shelf { cy: height * 0.50; shelfWidth: width * 0.78 }
    Shelf { cy: height * 0.72; shelfWidth: width * 0.62 }
  }

  Rectangle {
    visible: root.warning
    width: Math.max(6, root.iconSize * 0.28)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
  }

  component Shelf: ShapePath {
    property real cy: 0
    property real shelfWidth: width * 0.7
    readonly property real shelfHeight: height * 0.14
    readonly property real cx: width * 0.5

    fillColor: root.color
    strokeWidth: 0
    startX: cx - shelfWidth / 2
    startY: cy - shelfHeight / 2
    PathLine { x: cx + shelfWidth / 2; y: cy - shelfHeight / 2 }
    PathLine { x: cx + shelfWidth / 2; y: cy + shelfHeight / 2 }
    PathLine { x: cx - shelfWidth / 2; y: cy + shelfHeight / 2 }
    PathLine { x: cx - shelfWidth / 2; y: cy - shelfHeight / 2 }
  }
}
