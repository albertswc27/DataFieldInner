import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.System;

class InnerDataField1App extends Application.AppBase {
    hidden var mSettingsVersion as Number = 0;
    function initialize() {
        AppBase.initialize();
        mSettingsVersion = 0;
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
        System.println("INNER DataField App started");
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
        System.println("INNER DataField App stopped");
    }

    function onSettingsChanged() as Void {
        mSettingsVersion += 1;
        System.println("INNER DataField settings changed (v=" + mSettingsVersion + ")");
    }

    function getSettingsVersion() as Number {
        return mSettingsVersion;
    }

    function onValidateProperty(key as String, value) as Lang.Boolean or Lang.String {
        if (key == null || key.equals("")) {
            return "Property key invalida";
        }

        if (key.equals("pairingCode")) {
            return validatePairingCode(value);
        }

        if (key.equals("apiUrl")) {
            return validateApiUrl(value);
        }

        if (key.equals("selectedPlanId")) {
            return validateSelectedPlanId(value);
        }

        if (key.equals("toleranceSec")) {
            return validateNumberRange("toleranceSec", value, 0, 300);
        }

        if (key.equals("freeIntervalSec")) {
            return validateNumberRange("freeIntervalSec", value, 60, 7200);
        }

        if (key.equals("freeCHO")) {
            return validateNumberRange("freeCHO", value, 0, 200);
        }

        if (key.equals("freeNa")) {
            return validateNumberRange("freeNa", value, 0, 2000);
        }

        if (key.equals("freeMaxDurationMin")) {
            return validateNumberRange("freeMaxDurationMin", value, 30, 1800);
        }

        if (key.equals("vibrationIntensity")) {
            return validateNumberRange("vibrationIntensity", value, 1, 3);
        }

        if (key.equals("vibrationEnabled")
            || key.equals("soundEnabled")
            || key.equals("showCountdown")
            || key.equals("showNutrients")
            || key.equals("useFreeMode")
            || key.equals("useQuickDemoPlan")
            || key.equals("autoAdvance")
            || key.equals("autoConsumePlannedItems")) {
            if (!(value instanceof Boolean)) {
                return key + " debe ser booleano";
            }
            return true;
        }

        if (key.equals("freeItemName")) {
            if (!(value instanceof String)) {
                return "freeItemName debe ser texto";
            }

            var name = trimWhitespace(value as String);
            if (name.equals("")) {
                return "freeItemName no puede estar vacio";
            }

            if (name.length() > 40) {
                return "freeItemName demasiado largo";
            }

            return true;
        }

        if (key.equals("nutritionPlan") || key.equals("nutritionPlans")) {
            if (!(value instanceof String)) {
                return key + " debe ser texto";
            }

            var payload = value as String;
            if (payload.length() > 60000) {
                return key + " supera tamano maximo";
            }

            return true;
        }

        return true;
    }

    //! Return the initial view of your application here
    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new InnerDataField1View() ];
    }


    private function validatePairingCode(value) as Lang.Boolean or Lang.String {
        if (!(value instanceof String)) {
            return "pairingCode debe ser texto";
        }

        var raw = (value as String);
        var normalized = normalizePairingCode(raw);
        if (normalized.equals("")) {
            return true; // allow clear/reset
        }

        if (normalized.length() != 6) {
            return "pairingCode debe tener 6 caracteres alfanumericos";
        }

        if (!isAlphaNumeric(normalized)) {
            return "pairingCode solo permite A-Z y 0-9";
        }

        return true;
    }

    private function validateApiUrl(value) as Lang.Boolean or Lang.String {
        if (!(value instanceof String)) {
            return "apiUrl debe ser texto";
        }

        var url = trimWhitespace(value as String);
        if (url.equals("")) {
            return true; // app falls back to default endpoint
        }

        if (url.length() > 250) {
            return "apiUrl demasiado larga";
        }

        var lower = url.toLower();
        if (!startsWithText(lower, "https://") && !startsWithText(lower, "http://")) {
            return "apiUrl debe comenzar por http:// o https://";
        }

        return true;
    }

    private function validateSelectedPlanId(value) as Lang.Boolean or Lang.String {
        if (!(value instanceof String)) {
            return "selectedPlanId debe ser texto";
        }

        var planId = trimWhitespace(value as String);
        if (planId.equals("")) {
            return true;
        }

        if (planId.length() > 128) {
            return "selectedPlanId demasiado largo";
        }

        for (var i = 0; i < planId.length(); i++) {
            var ch = planId.substring(i, i + 1);
            var isDash = ch.equals("-") || ch.equals("_");
            if (!isDash && !isAlphaNumeric(ch.toUpper())) {
                return "selectedPlanId contiene caracteres invalidos";
            }
        }

        return true;
    }

    private function validateNumberRange(
        key as String,
        value,
        minValue as Number,
        maxValue as Number
    ) as Lang.Boolean or Lang.String {
        if (!(value instanceof Number)) {
            return key + " debe ser numerico";
        }

        var numberValue = value as Number;
        if (numberValue < minValue || numberValue > maxValue) {
            return key + " fuera de rango";
        }

        return true;
    }

    private function normalizePairingCode(raw as String) as String {
        var output = "";
        var text = raw.toUpper();

        for (var i = 0; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);
            if (ch.equals(" ")
                || ch.equals("\t")
                || ch.equals("\n")
                || ch.equals("\r")
                || ch.equals("-")) {
                continue;
            }
            output += ch;
        }

        return output;
    }

    private function isAlphaNumeric(text as String) as Boolean {
        var letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        var digits = "0123456789";

        for (var i = 0; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);
            var isLetter = letters.find(ch) != null;
            var isDigit = digits.find(ch) != null;
            if (!isLetter && !isDigit) {
                return false;
            }
        }

        return true;
    }

    private function startsWithText(text as String, prefix as String) as Boolean {
        if (text == null || prefix == null) {
            return false;
        }

        if (text.length() < prefix.length()) {
            return false;
        }

        return text.substring(0, prefix.length()).equals(prefix);
    }

    private function trimWhitespace(text as String) as String {
        if (text == null || text.length() == 0) {
            return "";
        }

        var start = 0;
        var finish = text.length() - 1;

        while (start <= finish) {
            var left = text.substring(start, start + 1);
            if (!isWhitespace(left)) {
                break;
            }
            start += 1;
        }

        while (finish >= start) {
            var right = text.substring(finish, finish + 1);
            if (!isWhitespace(right)) {
                break;
            }
            finish -= 1;
        }

        if (finish < start) {
            return "";
        }

        return text.substring(start, finish + 1);
    }

    private function isWhitespace(ch as String) as Boolean {
        return ch.equals(" ")
            || ch.equals("\t")
            || ch.equals("\n")
            || ch.equals("\r");
    }
}

function getApp() as InnerDataField1App {
    return Application.getApp() as InnerDataField1App;
}
