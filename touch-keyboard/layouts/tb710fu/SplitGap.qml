import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.VirtualKeyboard.Components

// 가로 화면에서 좌우 자판 사이의 빈 공간. gapRatio를 바꾸면 간격이 달라집니다(화면 폭 대비).
FillerKey {
    readonly property real gapRatio: 0.235
    visible: Screen.width > Screen.height
    weight: Screen.width * gapRatio
    Layout.fillWidth: false
}
