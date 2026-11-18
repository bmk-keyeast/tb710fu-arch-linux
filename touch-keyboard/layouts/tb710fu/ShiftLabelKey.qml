import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

Key {
    key: Qt.Key_Shift
    displayText: InputContext.capsLockActive ? "⇪" : InputContext.shiftActive ? "⬆" : "⇧"
    noKeyEvent: true
    functionKey: true
    highlighted: true
    showPreview: false
    enabled: InputContext.priv.shiftHandler.toggleShiftEnabled
    onClicked: InputContext.priv.shiftHandler.toggleShift()
}
