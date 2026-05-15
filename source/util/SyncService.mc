import Toybox.Communications;
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

/*
 * SyncService handles downloading nutrition plans from the InnerFuelPlan
 * web app server. Uses the same pairingCode as the main watch-app.
 */
class SyncService {
    private const MIN_SYNC_INTERVAL_MS = 300000; // 5 minutes
    private const PLANS_PROPERTY_KEY = "nutritionPlans";
    private const ACTIVE_PLAN_PROPERTY_KEY = "nutritionPlan";
    private const SELECTED_PLAN_ID_PROPERTY_KEY = "selectedPlanId";
    private const SELECTED_PLAN_STORAGE_KEY = "ifpSelectedPlanDict";
    private const MAX_PROPERTY_JSON_CHARS = 10000;
    // ETag enviado en `If-None-Match` para que el backend responda 304 si el
    // plan no ha cambiado desde la Ãºltima sync. CIQ no expone headers de
    // respuesta, asÃ­ que el backend duplica el etag dentro del body en 200.
    private const SYNC_ETAG_STORAGE_KEY = "garminSyncEtag";

    // Singleton instance
    private static var _instance as SyncService?;

    // Callback for sync completion
    private var _callback as Method?;

    // Sync state
    private var _isSyncing as Boolean;
    private var _lastSyncTime as Number?;
    private var _pendingPairingCodes as Array<String>;
    private var _activePairingCode as String;
    private var _apiUrl as String;
    private var _lastSyncedPlan as NutritionPlan?;

    function initialize() {
        _callback = null;
        _isSyncing = false;
        _lastSyncTime = null;
        _pendingPairingCodes = [] as Array<String>;
        _activePairingCode = "";
        _apiUrl = "https://us-central1-fanteinner-4fd38.cloudfunctions.net";
        _lastSyncedPlan = null;
    }

    static function getInstance() as SyncService {
        if (_instance == null) {
            _instance = new SyncService();
        }
        return _instance as SyncService;
    }

    /*
     * Check if communications are available on this device.
     */
    function isAvailable() as Boolean {
        return Communications has :makeWebRequest;
    }

    /*
     * Download plans from the server using the configured pairingCode.
     * Callback receives (success as Boolean, message as String).
     */
    function downloadPlans(callback as Method?, force as Boolean) as Void {
        _callback = callback;

        if (_isSyncing) {
            System.println("Sync already in progress");
            finishSync(false, "Sync en curso");
            return;
        }

        var nowMs = System.getTimer();
        if (!force && _lastSyncTime != null && (nowMs - _lastSyncTime) < MIN_SYNC_INTERVAL_MS) {
            finishSync(true, "Sync reciente");
            return;
        }

        // Check communications availability
        if (!isAvailable()) {
            System.println("Communications not available");
            finishSync(false, "No comm");
            return;
        }

        var rawPairingCode = Application.Properties.getValue("pairingCode");
        var pairingCodeText = "";
        if (rawPairingCode != null) {
            pairingCodeText = rawPairingCode.toString();
        }

        _pendingPairingCodes = buildPairingCodeCandidates(pairingCodeText);
        if (_pendingPairingCodes.size() == 0) {
            System.println("No pairing code configured");
            finishSync(false, "Sin codigo");
            return;
        }

        var apiUrlValue = Application.Properties.getValue("apiUrl");
        if (apiUrlValue != null && !apiUrlValue.toString().equals("")) {
            _apiUrl = apiUrlValue.toString();
        } else {
            _apiUrl = "https://us-central1-fanteinner-4fd38.cloudfunctions.net";
        }

        _isSyncing = true;
        requestNextPairingCode();
    }

    /*
     * Callback for HTTP response.
     */
    function onReceivePlans(responseCode as Number, data as Dictionary or String or Null) as Void {
        System.println("Response code: " + responseCode + " (code=" + _activePairingCode + ")");

        // 304 Not Modified: el plan no ha cambiado desde el Ãºltimo sync.
        // Mantener cache local intacto.
        if (responseCode == 304) {
            _lastSyncTime = System.getTimer();
            System.println("Plan unchanged (304); keeping cached payload");
            reportSyncResult(true, responseCode, getCachedPlanCount(), getSelectedPlanIdSafe(), "");
            finishSync(true, "Sin cambios");
            return;
        }

        if (responseCode >= 200 && responseCode < 300 && data != null) {
            // Guardar nuevo ETag si el backend lo devuelve dentro del body.
            // CIQ Communications no expone los headers de respuesta al callback.
            if (data instanceof Dictionary) {
                var dataDict = data as Dictionary;
                if (dataDict.hasKey("etag")) {
                    var etagValue = dataDict["etag"];
                    if (etagValue != null && etagValue instanceof String) {
                        try {
                            Application.Storage.setValue(
                                SYNC_ETAG_STORAGE_KEY,
                                etagValue as String
                            );
                        } catch (etagEx) {
                            System.println("ETag write failed: " + etagEx.getErrorMessage());
                        }
                    }
                }
            }

            var payload = extractPlansPayload(data);
            if (payload != null && payload.hasKey("plans")) {
                var plansArray = payload["plans"] as Array<Dictionary>;
                if (plansArray.size() > 0) {
                    var activePlanId = getDictionaryString(payload, "activePlanId", "");
                    persistPlans(plansArray, activePlanId);
                    _lastSyncTime = System.getTimer();
                    System.println("Plans synced successfully: " + plansArray.size().format("%d"));
                    reportSyncResult(true, responseCode, plansArray.size(), activePlanId, "");
                    finishSync(true, "Sincronizado (" + plansArray.size().format("%d") + ")");
                    return;
                }
            }

            // Successful response but no plans. Try alternate code format if available.
            if (hasMorePairingCodes()) {
                System.println("No plans for code " + _activePairingCode + ", trying next candidate");
                requestNextPairingCode();
                return;
            }

            reportSyncResult(false, responseCode, 0, "", "no_plans");
            finishSync(false, "Sin planes");
            return;
        }

        // Cualquier error: invalidar ETag para forzar full-sync en el prÃ³ximo intento.
        if (responseCode >= 400) {
            try {
                Application.Storage.deleteValue(SYNC_ETAG_STORAGE_KEY);
            } catch (delEx) {
                // ignore
            }
        }

        // Error response. Retry with alternate code format if available.
        if (hasMorePairingCodes()) {
            System.println("Sync failed for code " + _activePairingCode + ", trying next candidate");
            requestNextPairingCode();
            return;
        }

        reportSyncResult(false, responseCode, 0, "", "http_" + responseCode.format("%d"));
        finishSync(false, "Error " + responseCode);
    }

    private function requestNextPairingCode() as Void {
        if (_pendingPairingCodes.size() == 0) {
            finishSync(false, "Sin planes");
            return;
        }

        _activePairingCode = _pendingPairingCodes[0];
        _pendingPairingCodes.remove(_activePairingCode);

        try {
            var url = appendSyncTraceParams(_apiUrl + "/getPlans?code=" + _activePairingCode);
            var headers = {} as Dictionary<String, String>;
            try {
                var storedEtag = Application.Storage.getValue(SYNC_ETAG_STORAGE_KEY);
                if (storedEtag != null && storedEtag instanceof String) {
                    var etagText = storedEtag as String;
                    if (!etagText.equals("")) {
                        headers.put("If-None-Match", etagText);
                    }
                }
            } catch (etagEx) {
                System.println("ETag read failed: " + etagEx.getErrorMessage());
            }

            var options = {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :headers => headers
            };

            System.println("Downloading plans from: " + url);
            Communications.makeWebRequest(url, {}, options, method(:onReceivePlans));
        } catch (e) {
            _isSyncing = false;
            System.println("Error making request: " + e.getErrorMessage());
            finishSync(false, "Error");
        }
    }

    private function hasMorePairingCodes() as Boolean {
        return _pendingPairingCodes.size() > 0;
    }

    private function finishSync(success as Boolean, message as String) as Void {
        _isSyncing = false;
        _pendingPairingCodes = [] as Array<String>;
        _activePairingCode = "";

        if (_callback != null) {
            _callback.invoke(success, message);
        }
    }

    private function persistPlans(plansArray as Array<Dictionary>, activePlanIdHint as String) as Void {
        // Persist full plans payload for future plan switching.
        writePropertyJsonIfSafe(
            PLANS_PROPERTY_KEY,
            convertPlansEnvelopeToJson(plansArray),
            "plans envelope"
        );

        // Persist selected plan as legacy single-plan key for compatibility.
        var selectedPlan = resolveSelectedPlan(plansArray, activePlanIdHint);
        if (selectedPlan != null) {
            var selectedPlanId = getDictionaryString(selectedPlan, "id", "");
            writePropertyJsonIfSafe(
                ACTIVE_PLAN_PROPERTY_KEY,
                convertPlanToJson(selectedPlan),
                "active plan"
            );

            _lastSyncedPlan = buildPlanFromDictionary(selectedPlan);
            if (_lastSyncedPlan != null) {
                try {
                    Application.Storage.setValue(SELECTED_PLAN_STORAGE_KEY, selectedPlan);
                } catch (storageEx) {
                    System.println("Storage.setValue failed: " + storageEx.getErrorMessage());
                }
            }

            if (!selectedPlanId.equals("")) {
                Application.Properties.setValue(SELECTED_PLAN_ID_PROPERTY_KEY, selectedPlanId);
            }
        }
    }

    private function writePropertyJsonIfSafe(key as String, jsonText as String, label as String) as Void {
        try {
            if (jsonText != null && jsonText.length() <= MAX_PROPERTY_JSON_CHARS) {
                Application.Properties.setValue(key, jsonText);
                return;
            }

            Application.Properties.setValue(key, "");
            var sizeText = jsonText == null ? "null" : jsonText.length().format("%d");
            System.println("Skip " + key + " write (" + label + " too large: " + sizeText + " chars)");
        } catch (ex) {
            System.println("Property write failed for " + key + ": " + ex.getErrorMessage());
        }
    }

    function onReportSyncComplete(responseCode as Number, data as Dictionary or String or Null) as Void {
        System.println("Sync telemetry response: " + responseCode);
    }

    private function reportSyncResult(
        success as Boolean,
        responseCode as Number,
        planCount as Number,
        activePlanId as String,
        errorCode as String
    ) as Void {
        if (_activePairingCode == null || _activePairingCode.equals("")) {
            return;
        }

        try {
            var payload = buildDeviceInfo();
            payload["code"] = _activePairingCode;
            payload["status"] = success ? "success" : "failure";
            payload["responseCode"] = responseCode;
            payload["planCount"] = planCount;
            payload["activePlanId"] = activePlanId == null ? "" : activePlanId;
            payload["errorCode"] = errorCode == null ? "" : errorCode;

            var options = {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                :headers => {
                    "Content-Type" => Communications.REQUEST_CONTENT_TYPE_URL_ENCODED
                }
            };

            Communications.makeWebRequest(
                _apiUrl + "/reportGarminSync",
                payload,
                options,
                method(:onReportSyncComplete)
            );
        } catch (ex) {
            System.println("Sync telemetry failed: " + ex.getErrorMessage());
        }
    }

    private function appendSyncTraceParams(baseUrl as String) as String {
        var info = buildDeviceInfo();
        var url = baseUrl + "&dfBuild=" + sanitizeQueryValue(BuildInfo.getBuild());

        if (info.hasKey("devicePart")) {
            url += "&devicePart=" + sanitizeQueryValue(info["devicePart"]);
        }
        if (info.hasKey("firmware")) {
            url += "&fw=" + sanitizeQueryValue(info["firmware"]);
        }
        if (info.hasKey("ciq")) {
            url += "&ciq=" + sanitizeQueryValue(info["ciq"]);
        }

        return url;
    }

    private function buildDeviceInfo() as Dictionary {
        var info = {
            "dfBuild" => BuildInfo.getBuild()
        } as Dictionary;

        try {
            var settings = System.getDeviceSettings();
            if (settings != null) {
                if (settings has :partNumber && settings.partNumber != null) {
                    info["devicePart"] = settings.partNumber.toString();
                }
                if (settings has :firmwareVersion && settings.firmwareVersion != null) {
                    info["firmware"] = formatVersionValue(settings.firmwareVersion);
                }
                if (settings has :monkeyVersion && settings.monkeyVersion != null) {
                    info["ciq"] = formatVersionValue(settings.monkeyVersion);
                }
            }
        } catch (ex) {
            System.println("Device info unavailable: " + ex.getErrorMessage());
        }

        return info;
    }

    private function formatVersionValue(value) as String {
        if (value == null) {
            return "";
        }

        if (value instanceof Array) {
            var parts = value as Array;
            var text = "";
            for (var i = 0; i < parts.size(); i++) {
                if (i > 0) {
                    text += ".";
                }
                text += parts[i].toString();
            }
            return text;
        }

        return value.toString();
    }

    private function sanitizeQueryValue(value) as String {
        if (value == null) {
            return "";
        }

        var text = value.toString();
        var output = "";
        var allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_";
        for (var i = 0; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);
            if (allowed.find(ch) != null) {
                output += ch;
            }
        }
        return output;
    }

    private function getCachedPlanCount() as Number {
        if (_lastSyncedPlan != null && (_lastSyncedPlan as NutritionPlan).hasItems()) {
            return 1;
        }

        try {
            var stored = Application.Storage.getValue(SELECTED_PLAN_STORAGE_KEY);
            if (stored != null && stored instanceof Dictionary) {
                return 1;
            }
        } catch (ex) {
            // ignore
        }

        return 0;
    }

    private function getSelectedPlanIdSafe() as String {
        try {
            var value = Application.Properties.getValue(SELECTED_PLAN_ID_PROPERTY_KEY);
            if (value != null) {
                return value.toString();
            }
        } catch (ex) {
            // ignore
        }
        return "";
    }

    function getLastSyncedPlan() as NutritionPlan? {
        return _lastSyncedPlan;
    }

    function loadPersistedSelectedPlan() as NutritionPlan? {
        try {
            var stored = Application.Storage.getValue(SELECTED_PLAN_STORAGE_KEY);
            if (stored != null && stored instanceof Dictionary) {
                return buildPlanFromDictionary(stored as Dictionary);
            }
        } catch (ex) {
            System.println("Storage.getValue failed: " + ex.getErrorMessage());
        }

        return null;
    }

    private function buildPlanFromDictionary(planDict as Dictionary or Null) as NutritionPlan? {
        if (planDict == null) {
            return null;
        }

        var planId = getDictionaryString(planDict, "id", "unknown");
        var planName = getDictionaryString(planDict, "name", "Plan");

        var itemList = [] as Array<NutritionItem>;
        if (planDict.hasKey("items") && planDict["items"] instanceof Array) {
            var rawItems = planDict["items"] as Array;
            for (var i = 0; i < rawItems.size(); i++) {
                if (rawItems[i] instanceof Dictionary) {
                    var parsedItem = buildItemFromDictionary(rawItems[i] as Dictionary, i);
                    if (parsedItem != null) {
                        itemList.add(parsedItem);
                    }
                }
            }
        }

        if (itemList.size() == 0) {
            return null;
        }

        var targetCHO = 0;
        var targetNa = 0;
        for (var j = 0; j < itemList.size(); j++) {
            targetCHO += itemList[j].getNutrient("cho");
            targetNa += itemList[j].getNutrient("na");
        }

        return new NutritionPlan(planId, planName, itemList, targetCHO, targetNa);
    }

    private function buildItemFromDictionary(itemDict as Dictionary, index as Number) as NutritionItem? {
        var itemId = getDictionaryString(itemDict, "id", "item-" + index.format("%d"));
        var itemName = getDictionaryString(itemDict, "name", "Item " + index.format("%d"));

        if (!itemDict.hasKey("scheduledTime") || !(itemDict["scheduledTime"] instanceof Number)) {
            return null;
        }

        var scheduledTime = itemDict["scheduledTime"] as Number;
        var cho = 0;
        var na = 0;

        if (itemDict.hasKey("nutrients") && itemDict["nutrients"] instanceof Dictionary) {
            var nutrients = itemDict["nutrients"] as Dictionary;
            cho = getNumberFromKeys(nutrients, ["cho", "carbs", "carbohydrates", "choGrams", "carbsG"]);
            na = getNumberFromKeys(nutrients, ["na", "sodium", "sodiumMg", "naMg", "sodiumMilligrams"]);
        }

        // Alternative top-level nutrient encodings from web payloads.
        if (cho <= 0) {
            cho = getNumberFromKeys(itemDict, ["cho", "carbs", "carbohydrates", "choGrams", "carbsG"]);
        }
        if (na <= 0) {
            na = getNumberFromKeys(itemDict, ["na", "sodium", "sodiumMg", "naMg", "sodiumMilligrams"]);
        }

        // Nested macro blocks occasionally used by web APIs.
        if (itemDict.hasKey("macros") && itemDict["macros"] instanceof Dictionary) {
            var macros = itemDict["macros"] as Dictionary;
            if (cho <= 0) {
                cho = getNumberFromKeys(macros, ["cho", "carbs", "carbohydrates"]);
            }
            if (na <= 0) {
                na = getNumberFromKeys(macros, ["na", "sodium", "sodiumMg"]);
            }
        }

        var rawIconKey = getDictionaryString(itemDict, "iconKey", "");
        var rawProductKey = getFirstStringFromKeys(itemDict, [
            "productId", "productSlug", "productCode", "slug", "sku", "code"
        ]);
        if ((rawProductKey == null || rawProductKey.equals("")) && itemDict.hasKey("product") && itemDict["product"] instanceof Dictionary) {
            var productDict = itemDict["product"] as Dictionary;
            rawProductKey = getFirstStringFromKeys(productDict, ["id", "slug", "code", "sku", "productId"]);
        }

        var normalizedIconKey = ProductCatalogMapper.normalizeIconKey(
            rawIconKey.equals("") ? null : rawIconKey,
            rawProductKey,
            itemName
        );

        var enrichedNutrients = ProductCatalogMapper.fillMissingNutrients(
            itemName,
            rawProductKey,
            normalizedIconKey,
            cho,
            na
        );

        if ((enrichedNutrients["cho"] as Number) != cho || (enrichedNutrients["na"] as Number) != na) {
            System.println("Enriched nutrients for " + itemName + ": CHO " + enrichedNutrients["cho"] + " / Na " + enrichedNutrients["na"]);
        }

        return new NutritionItem(itemId, itemName, scheduledTime, enrichedNutrients, normalizedIconKey);
    }

    private function extractPlansPayload(data as Dictionary or String or Null) as Dictionary? {
        if (data == null) {
            return null;
        }

        if (data instanceof Dictionary) {
            return extractPlansPayloadFromDictionary(data as Dictionary);
        }

        if (data instanceof String) {
            return extractPlansPayloadFromString(data as String);
        }
    }

    private function extractPlansPayloadFromDictionary(responseDict as Dictionary) as Dictionary? {
        var activePlanId = getDictionaryString(responseDict, "activePlanId", "");
        if (activePlanId.equals("")) {
            activePlanId = getDictionaryString(responseDict, "activePlan", "");
        }

        var plansArray = extractPlansArray(responseDict);

        // Support nested payloads: { data: { plans: [...] , activePlanId: ... } }
        if (plansArray == null && responseDict.hasKey("data") && responseDict["data"] instanceof Dictionary) {
            var nested = responseDict["data"] as Dictionary;
            plansArray = extractPlansArray(nested);
            if (activePlanId.equals("")) {
                activePlanId = getDictionaryString(nested, "activePlanId", "");
                if (activePlanId.equals("")) {
                    activePlanId = getDictionaryString(nested, "activePlan", "");
                }
            }
        }

        // Support single-plan payloads: { plan: { ... } }
        if (plansArray == null && responseDict.hasKey("plan") && responseDict["plan"] instanceof Dictionary) {
            plansArray = [responseDict["plan"] as Dictionary] as Array<Dictionary>;
        }

        if (plansArray == null) {
            return null;
        }

        return {
            "plans" => plansArray,
            "activePlanId" => activePlanId
        };
    }

    private function extractPlansPayloadFromString(jsonText as String) as Dictionary? {
        if (jsonText == null || jsonText.length() < 2) {
            return null;
        }

        var parsedPlans = NutritionPlanParser.parsePlans(jsonText);
        if (parsedPlans.size() == 0) {
            return null;
        }

        var plansArray = [] as Array<Dictionary>;
        for (var i = 0; i < parsedPlans.size(); i++) {
            plansArray.add(convertParsedPlanToDictionary(parsedPlans[i]));
        }

        return {
            "plans" => plansArray,
            "activePlanId" => ""
        };
    }

    private function convertParsedPlanToDictionary(plan as NutritionPlan) as Dictionary {
        var itemDicts = [] as Array<Dictionary>;

        for (var i = 0; i < plan.items.size(); i++) {
            var item = plan.items[i];
            var itemDict = {
                "id" => item.id,
                "name" => item.name,
                "scheduledTime" => item.scheduledTime,
                "nutrients" => {
                    "cho" => item.getNutrient("cho"),
                    "na" => item.getNutrient("na")
                }
            } as Dictionary;

            if (item.iconKey != null) {
                itemDict["iconKey"] = item.iconKey as String;
            }

            itemDicts.add(itemDict);
        }

        return {
            "id" => plan.id,
            "name" => plan.name,
            "items" => itemDicts,
            "targetCHO" => plan.targetCHO,
            "targetNa" => plan.targetNa
        };
    }

    private function extractPlansArray(responseDict as Dictionary) as Array<Dictionary>? {
        if (!responseDict.hasKey("plans")) {
            return null;
        }

        var rawPlans = responseDict["plans"];
        if (rawPlans == null) {
            return null;
        }

        if (rawPlans instanceof Dictionary) {
            return [rawPlans as Dictionary] as Array<Dictionary>;
        }

        if (!(rawPlans instanceof Array)) {
            return null;
        }

        var planArray = rawPlans as Array;
        var filtered = [] as Array<Dictionary>;
        for (var i = 0; i < planArray.size(); i++) {
            if (planArray[i] instanceof Dictionary) {
                filtered.add(planArray[i] as Dictionary);
            }
        }

        return filtered;
    }

    private function resolveSelectedPlan(
        plansArray as Array<Dictionary>,
        activePlanIdHint as String
    ) as Dictionary? {
        if (plansArray.size() == 0) {
            return null;
        }

        var targetPlanId = activePlanIdHint;
        if (targetPlanId == null || targetPlanId.equals("")) {
            var propertyPlanId = Application.Properties.getValue(SELECTED_PLAN_ID_PROPERTY_KEY);
            if (propertyPlanId != null) {
                targetPlanId = propertyPlanId.toString();
            } else {
                targetPlanId = "";
            }
        }

        if (!targetPlanId.equals("")) {
            for (var i = 0; i < plansArray.size(); i++) {
                var planId = getDictionaryString(plansArray[i], "id", "");
                if (planId.equals(targetPlanId)) {
                    return plansArray[i];
                }
            }
        }

        return plansArray[0];
    }

    private function getDictionaryString(dict as Dictionary, key as String, fallback as String) as String {
        if (!dict.hasKey(key)) {
            return fallback;
        }

        var value = dict[key];
        if (value == null) {
            return fallback;
        }

        var text = value.toString();
        return text.equals("") ? fallback : text;
    }

    private function getFirstStringFromKeys(dict as Dictionary, keys as Array<String>) as String? {
        for (var i = 0; i < keys.size(); i++) {
            var key = keys[i];
            if (!dict.hasKey(key)) {
                continue;
            }
            var value = dict[key];
            if (value == null) {
                continue;
            }
            var text = value.toString();
            if (!text.equals("")) {
                return text;
            }
        }
        return null;
    }

    private function getNumberFromKeys(dict as Dictionary, keys as Array<String>) as Number {
        for (var i = 0; i < keys.size(); i++) {
            var key = keys[i];
            if (!dict.hasKey(key)) {
                continue;
            }
            var value = dict[key];
            if (value == null) {
                continue;
            }
            if (value instanceof Number) {
                return value as Number;
            }
            try {
                return value.toString().toNumber();
            } catch (ex) {
                // Continue trying alternate keys.
            }
        }
        return 0;
    }

    private function buildPairingCodeCandidates(rawCode as String or Null) as Array<String> {
        var candidates = [] as Array<String>;
        if (rawCode == null) {
            return candidates;
        }

        var compactSpaces = removeWhitespace(rawCode).toUpper();
        if (compactSpaces.equals("")) {
            return candidates;
        }

        addCandidate(candidates, compactSpaces);

        var alnumOnly = keepAlphaNumeric(compactSpaces);
        addCandidate(candidates, alnumOnly);

        if (alnumOnly.length() == 6) {
            var hyphenized = alnumOnly.substring(0, 3) + "-" + alnumOnly.substring(3, 6);
            addCandidate(candidates, hyphenized);
        }

        return candidates;
    }

    private function addCandidate(candidates as Array<String>, candidate as String) as Void {
        if (candidate == null || candidate.equals("")) {
            return;
        }

        for (var i = 0; i < candidates.size(); i++) {
            if (candidates[i].equals(candidate)) {
                return;
            }
        }

        candidates.add(candidate);
    }

    private function removeWhitespace(input as String) as String {
        var output = "";

        for (var i = 0; i < input.length(); i++) {
            var ch = input.substring(i, i + 1);
            if (ch.equals(" ") || ch.equals("\t") || ch.equals("\n") || ch.equals("\r")) {
                continue;
            }
            output += ch;
        }

        return output;
    }

    private function keepAlphaNumeric(input as String) as String {
        var output = "";

        for (var i = 0; i < input.length(); i++) {
            var ch = input.substring(i, i + 1);
            if (isAlphaNumeric(ch)) {
                output += ch;
            }
        }

        return output;
    }

    private function isAlphaNumeric(ch as String) as Boolean {
        var digits = "0123456789";
        if (digits.find(ch) != null) {
            return true;
        }

        var letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        return letters.find(ch) != null;
    }

    /*
     * Convert plans array into JSON envelope: { "plans": [ ... ] }
     */
    private function convertPlansEnvelopeToJson(plans as Array<Dictionary>) as String {
        var result = "{\"plans\":[";
        for (var i = 0; i < plans.size(); i++) {
            if (i > 0) {
                result += ",";
            }
            result += convertPlanToJson(plans[i]);
        }
        result += "]}";
        return result;
    }

    /*
     * Convert a Dictionary plan to a JSON string.
     * Simple serialization for Garmin storage.
     */
    private function convertPlanToJson(plan as Dictionary) as String {
        var result = "{";

        // ID
        if (plan.hasKey("id")) {
            result += "\"id\":" + asJsonString(plan["id"]) + ",";
        }

        // Name
        if (plan.hasKey("name")) {
            result += "\"name\":" + asJsonString(plan["name"]) + ",";
        }

        // Items array
        if (plan.hasKey("items")) {
            result += "\"items\":[";
            if (plan["items"] instanceof Array) {
                var items = plan["items"] as Array;
                var emittedCount = 0;
                for (var i = 0; i < items.size(); i++) {
                    if (!(items[i] instanceof Dictionary)) {
                        continue;
                    }
                    if (emittedCount > 0) {
                        result += ",";
                    }
                    var item = items[i] as Dictionary;
                    result += convertItemToJson(item);
                    emittedCount += 1;
                }
            }
            result += "],";
        }

        // Target CHO
        if (plan.hasKey("targetCHO")) {
            result += "\"targetCHO\":" + asNumberOrDefault(plan["targetCHO"], 0) + ",";
        } else {
            result += "\"targetCHO\":0,";
        }

        // Target Na
        if (plan.hasKey("targetNa")) {
            result += "\"targetNa\":" + asNumberOrDefault(plan["targetNa"], 0);
        } else {
            result += "\"targetNa\":0";
        }

        result += "}";
        return result;
    }

    /*
     * Convert an item Dictionary to JSON string.
     */
    private function convertItemToJson(item as Dictionary) as String {
        var result = "{";

        // ID
        result += "\"id\":" + asJsonString(item.hasKey("id") ? item["id"] : "0") + ",";

        // Name
        result += "\"name\":" + asJsonString(item.hasKey("name") ? item["name"] : "Item") + ",";

        // Optional product icon key (used by alert classification/UI)
        if (item.hasKey("iconKey")) {
            result += "\"iconKey\":" + asJsonString(item["iconKey"]) + ",";
        }

        // Scheduled time
        var time = 0;
        if (item.hasKey("scheduledTime")) {
            time = asNumberOrDefault(item["scheduledTime"], 0);
        }
        result += "\"scheduledTime\":" + time + ",";

        // Nutrients
        result += "\"nutrients\":{";
        if (item.hasKey("nutrients") && item["nutrients"] instanceof Dictionary) {
            var nutrients = item["nutrients"] as Dictionary;
            var cho = nutrients.hasKey("cho") ? asNumberOrDefault(nutrients["cho"], 0) : 0;
            var na = nutrients.hasKey("na") ? asNumberOrDefault(nutrients["na"], 0) : 0;
            result += "\"cho\":" + cho + ",\"na\":" + na;
        } else {
            result += "\"cho\":0,\"na\":0";
        }
        result += "}";

        result += "}";
        return result;
    }

    private function asJsonString(value) as String {
        if (value == null) {
            return "\"\"";
        }
        return "\"" + escapeJson(value.toString()) + "\"";
    }

    private function asNumberOrDefault(value, fallback as Number) as Number {
        if (value == null) {
            return fallback;
        }
        if (value instanceof Number) {
            return value as Number;
        }
        try {
            return value.toString().toNumber();
        } catch (e) {
            return fallback;
        }
    }

    private function escapeJson(input as String) as String {
        var output = "";

        for (var i = 0; i < input.length(); i++) {
            var ch = input.substring(i, i + 1);
            if (ch.equals("\\")) {
                output += "\\\\";
            } else if (ch.equals("\"")) {
                output += "\\\"";
            } else if (ch.equals("\n")) {
                output += "\\n";
            } else if (ch.equals("\r")) {
                output += "\\r";
            } else if (ch.equals("\t")) {
                output += "\\t";
            } else {
                output += ch;
            }
        }

        return output;
    }

    /*
     * Get last sync time (milliseconds since app start, or null if never synced).
     */
    function getLastSyncTime() as Number? {
        return _lastSyncTime;
    }

    /*
     * Check if currently syncing.
     */
    function isSyncing() as Boolean {
        return _isSyncing;
    }
}
