import QtQuick
import QtQuick.VirtualKeyboard
import QtQuick.VirtualKeyboard.Components
import QtQuick.VirtualKeyboard.Settings

Key {
    key: Qt.Key_Mode_switch
    displayText: "한/영"
    noKeyEvent: true
    functionKey: true
    highlighted: true
    showPreview: false
    onClicked: {
        InputContext.commit()
        VirtualKeyboardSettings.locale = InputContext.locale === "ko_KR" ? "en_US" : "ko_KR"
    }
}
