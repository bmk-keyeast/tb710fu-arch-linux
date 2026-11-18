import QtQuick
import QtQuick.Layouts
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components

KeyboardRow {
    Key { key: Qt.Key_Escape; displayText: "Esc"; weight: Screen.width > Screen.height ? 160 : 240; functionKey: true; highlighted: true; showPreview: false; }
    Key { key: Qt.Key_Tab; displayText: "Tab"; weight: Screen.width > Screen.height ? 160 : 240; functionKey: true; highlighted: true; showPreview: false; }
    Key {
        key: Qt.Key_Control
        weight: Screen.width > Screen.height ? 160 : 240
        displayText: TermState.ctrl ? "CTRL ●" : "Ctrl"
        noKeyEvent: true
        functionKey: true
        highlighted: true
        showPreview: false
        onClicked: TermState.ctrl = !TermState.ctrl
    }
    Key { key: Qt.Key_Slash; text: "/" }
    Key { key: Qt.Key_Minus; text: "-" }
    Key { key: Qt.Key_Bar; text: "|" }
    Key { key: Qt.Key_AsciiTilde; text: "~" }
    SplitGap { }
    Key { key: Qt.Key_Home; displayText: "Home"; weight: Screen.width > Screen.height ? 160 : 300; functionKey: true; highlighted: true; showPreview: false; }
    Key { key: Qt.Key_End; displayText: "End"; weight: Screen.width > Screen.height ? 160 : 240; functionKey: true; highlighted: true; showPreview: false; }
    Key { key: Qt.Key_Left; displayText: "←"; weight: Screen.width > Screen.height ? 160 : 160; functionKey: true; highlighted: true; showPreview: false; repeat: true; }
    Key { key: Qt.Key_Down; displayText: "↓"; weight: Screen.width > Screen.height ? 160 : 160; functionKey: true; highlighted: true; showPreview: false; repeat: true; }
    Key { key: Qt.Key_Up; displayText: "↑"; weight: Screen.width > Screen.height ? 160 : 160; functionKey: true; highlighted: true; showPreview: false; repeat: true; }
    Key { key: Qt.Key_Right; displayText: "→"; weight: Screen.width > Screen.height ? 160 : 160; functionKey: true; highlighted: true; showPreview: false; repeat: true; }
}
