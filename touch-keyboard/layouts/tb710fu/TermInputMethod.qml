// 두벌식 조합(preedit)과 터미널용 Ctrl. Qt 기본 Hangul 입력기는 주변 글자를 고쳐 쓰는 방식이라 터미널에서 깨집니다.
import QtQuick
import QtQuick.VirtualKeyboard as VKB
import "." as Tb

VKB.InputMethod {
    property bool hangul: false

    readonly property string choTable: "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
    readonly property string jungTable: "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"
    readonly property var jongTable: ["", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    readonly property var vowelJoin: ({ "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ" })
    readonly property var finalJoin: ({ "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ" })
    readonly property var latinOf: ({ "ㅂ": "q", "ㅃ": "q", "ㅈ": "w", "ㅉ": "w", "ㄷ": "e", "ㄸ": "e", "ㄱ": "r", "ㄲ": "r", "ㅅ": "t", "ㅆ": "t", "ㅛ": "y", "ㅕ": "u", "ㅑ": "i", "ㅐ": "o", "ㅒ": "o", "ㅔ": "p", "ㅖ": "p", "ㅁ": "a", "ㄴ": "s", "ㅇ": "d", "ㄹ": "f", "ㅎ": "g", "ㅗ": "h", "ㅓ": "j", "ㅏ": "k", "ㅣ": "l", "ㅋ": "z", "ㅌ": "x", "ㅊ": "c", "ㅍ": "v", "ㅠ": "b", "ㅜ": "n", "ㅡ": "m" })

    property string cho: ""
    property string jung: ""
    property string jong: ""

    function inputModes(locale) {
        return [hangul ? VKB.InputEngine.InputMode.Hangul : VKB.InputEngine.InputMode.Latin]
    }
    function setInputMode(locale, inputMode) { return true }
    function setTextCase(textCase) { return true }
    function selectionLists() { return [] }
    function clear() { cho = ""; jung = ""; jong = "" }
    function reset() { clear() }
    function update() { flush() }

    function composed() {
        if (cho && jung)
            return String.fromCharCode(0xAC00 + 588 * choTable.indexOf(cho) + 28 * jungTable.indexOf(jung) + jongTable.indexOf(jong))
        return cho || jung
    }
    function show() { inputContext.preeditText = composed() }
    function flush() {
        const text = composed()
        clear()
        if (text)
            inputContext.commit(text)
    }
    function splitFinal(f) {
        for (const pair in finalJoin)
            if (finalJoin[pair] === f)
                return [pair[0], pair[1]]
        return ["", f]
    }

    function consonant(c) {
        if (cho && jung && !jong && jongTable.indexOf(c) > 0) {
            jong = c
        } else if (jong && finalJoin[jong + c]) {
            jong = finalJoin[jong + c]
        } else {
            flush()
            cho = c
        }
        show()
    }
    function vowel(v) {
        if (jong) {
            const parts = splitFinal(jong)
            jong = parts[0]
            flush()
            cho = parts[1]
            jung = v
        } else if (jung && vowelJoin[jung + v]) {
            jung = vowelJoin[jung + v]
        } else if (jung) {
            flush()
            jung = v
        } else {
            jung = v
        }
        show()
    }
    function backspace() {
        if (jong) {
            jong = splitFinal(jong)[0]
        } else if (jung) {
            let base = ""
            for (const pair in vowelJoin)
                if (vowelJoin[pair] === jung)
                    base = pair[0]
            jung = base
        } else if (cho) {
            cho = ""
        } else {
            return false
        }
        show()
        return true
    }
    function controlChar(text) {
        const c = (latinOf[text] || text).toLowerCase()
        return /^[a-z@\[\\\]^_]$/.test(c) ? String.fromCharCode(c.charCodeAt(0) & 0x1f) : ""
    }

    function keyEvent(key, text, modifiers) {
        if (Tb.TermState.ctrl) {
            Tb.TermState.ctrl = false
            const control = controlChar(text)
            if (control) {
                flush()
                inputContext.commit(control)
                return true
            }
        }
        if (hangul) {
            if (key === Qt.Key_Backspace && backspace())
                return true
            if (text.length === 1 && choTable.indexOf(text) >= 0) {
                consonant(text)
                return true
            }
            if (text.length === 1 && jungTable.indexOf(text) >= 0) {
                vowel(text)
                return true
            }
        }
        flush()
        return false
    }
}
