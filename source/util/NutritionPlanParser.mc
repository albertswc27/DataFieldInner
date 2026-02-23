import Toybox.Lang;
import Toybox.System;

/*
 * NutritionPlanParser parses JSON-like strings without depending on a JSON
 * module (not available on all CIQ SDK/API combinations).
 *
 * Supported roots:
 * - Single plan object: { id, name, items, ... }
 * - Plans envelope: { plans: [ ... ] }
 * - Array of plan objects: [ ... ]
 */
class NutritionPlanParser {

    static function parse(jsonString as String) as NutritionPlan? {
        var plans = parsePlans(jsonString);
        if (plans.size() > 0) {
            return plans[0];
        }
        return null;
    }

    static function parsePlans(jsonString as String) as Array<NutritionPlan> {
        var parsedPlans = [] as Array<NutritionPlan>;
        if (jsonString == null || jsonString.length() < 2) {
            return parsedPlans;
        }

        var normalized = normalizeJson(jsonString);
        try {
            if (startsWith(normalized, "{")) {
                var plansArrayJson = extractArrayForKey(normalized, "plans");
                if (plansArrayJson != null) {
                    var planObjects = splitTopLevelObjects(plansArrayJson as String);
                    for (var i = 0; i < planObjects.size(); i++) {
                        var parsed = parsePlanObject(planObjects[i]);
                        if (parsed != null) {
                            parsedPlans.add(parsed);
                        }
                    }
                    return parsedPlans;
                }

                var singlePlan = parsePlanObject(normalized);
                if (singlePlan != null) {
                    parsedPlans.add(singlePlan);
                }
                return parsedPlans;
            }

            if (startsWith(normalized, "[")) {
                var objectList = splitTopLevelObjects(normalized);
                for (var j = 0; j < objectList.size(); j++) {
                    var plan = parsePlanObject(objectList[j]);
                    if (plan != null) {
                        parsedPlans.add(plan);
                    }
                }
            }
        } catch (e) {
            System.println("Parse plans error: " + e.getErrorMessage());
        }

        return parsedPlans;
    }

    private static function parsePlanObject(planJson as String) as NutritionPlan? {
        if (planJson == null || planJson.length() < 2) {
            return null;
        }

        var id = extractStringValue(planJson, "id");
        if (id == null || id.equals("")) {
            id = "unknown";
        }

        var name = extractStringValue(planJson, "name");
        if (name == null || name.equals("")) {
            name = "Plan";
        }

        var items = parseItems(planJson);
        var targetCHO = extractNumberValue(planJson, "targetCHO");
        var targetNa = extractNumberValue(planJson, "targetNa");

        // If targets are not provided, derive them from item nutrients.
        if (targetCHO == 0 && targetNa == 0 && items.size() > 0) {
            for (var i = 0; i < items.size(); i++) {
                targetCHO += items[i].getNutrient("cho");
                targetNa += items[i].getNutrient("na");
            }
        }

        return new NutritionPlan(id, name, items, targetCHO, targetNa);
    }

    static function parseItems(planJson as String) as Array<NutritionItem> {
        var items = [] as Array<NutritionItem>;
        var itemsArrayJson = extractArrayForKey(planJson, "items");
        if (itemsArrayJson == null) {
            return items;
        }

        var itemObjects = splitTopLevelObjects(itemsArrayJson as String);
        var maxItems = 240;
        var count = 0;
        for (var i = 0; i < itemObjects.size() && count < maxItems; i++) {
            var parsedItem = parseItem(itemObjects[i], i);
            if (parsedItem != null) {
                items.add(parsedItem);
                count += 1;
            }
        }

        return items;
    }

    static function parseItem(itemJson as String, index as Number) as NutritionItem? {
        var id = extractStringValue(itemJson, "id");
        if (id == null || id.equals("")) {
            id = index.format("%d");
        }

        var name = extractStringValue(itemJson, "name");
        if (name == null || name.equals("")) {
            name = "Item " + index.format("%d");
        }

        var scheduledTime = extractNumberValue(itemJson, "scheduledTime");

        var nutrientsJson = extractObjectForKey(itemJson, "nutrients");
        var cho = 0;
        var na = 0;
        if (nutrientsJson != null) {
            cho = extractNumberValue(nutrientsJson as String, "cho");
            na = extractNumberValue(nutrientsJson as String, "na");
        }

        // Support payloads where nutrients are top-level fields.
        cho = extractNumberValueOr(itemJson, "cho", cho);
        na = extractNumberValueOr(itemJson, "na", na);

        var iconKey = extractStringValue(itemJson, "iconKey");
        var nutrients = {"cho" => cho, "na" => na} as Dictionary<String, Number>;
        return new NutritionItem(id, name, scheduledTime, nutrients, iconKey);
    }

    static function extractStringValue(json as String, key as String) as String? {
        var normalized = normalizeJson(json);
        var searchKey = "\"" + key + "\":\"";
        var startIdx = normalized.find(searchKey);
        if (startIdx == null) {
            return null;
        }

        var valueStart = startIdx + searchKey.length();
        var i = valueStart;
        var escaped = false;
        while (i < normalized.length()) {
            var ch = normalized.substring(i, i + 1);
            if (escaped) {
                escaped = false;
            } else if (ch.equals("\\")) {
                escaped = true;
            } else if (ch.equals("\"")) {
                return unescapeJsonString(normalized.substring(valueStart, i));
            }
            i += 1;
        }

        return null;
    }

    static function extractNumberValue(json as String, key as String) as Number {
        return extractNumberValueOr(json, key, 0);
    }

    static function extractNumberValueOr(json as String, key as String, fallback as Number) as Number {
        var normalized = normalizeJson(json);
        var searchKey = "\"" + key + "\":";
        var startIdx = normalized.find(searchKey);
        if (startIdx == null) {
            return fallback;
        }

        var valueStart = startIdx + searchKey.length();
        var numberBuffer = "";
        var i = valueStart;
        while (i < normalized.length()) {
            var ch = normalized.substring(i, i + 1);
            var isNumChar = (
                ch.equals("-") ||
                ch.equals("+") ||
                ch.equals(".") ||
                ch.equals("e") ||
                ch.equals("E") ||
                isDigit(ch)
            );

            if (!isNumChar) {
                break;
            }
            numberBuffer += ch;
            i += 1;
        }

        if (numberBuffer.length() == 0) {
            return fallback;
        }

        try {
            return numberBuffer.toNumber();
        } catch (e) {
            return fallback;
        }
    }

    private static function extractArrayForKey(json as String, key as String) as String? {
        var normalized = normalizeJson(json);
        var searchKey = "\"" + key + "\":[";
        var startIdx = normalized.find(searchKey);
        if (startIdx == null) {
            return null;
        }

        var openIdx = startIdx + searchKey.length() - 1;
        return extractBalancedBlock(normalized, openIdx, "[", "]");
    }

    private static function extractObjectForKey(json as String, key as String) as String? {
        var normalized = normalizeJson(json);
        var searchKey = "\"" + key + "\":{";
        var startIdx = normalized.find(searchKey);
        if (startIdx == null) {
            return null;
        }

        var openIdx = startIdx + searchKey.length() - 1;
        return extractBalancedBlock(normalized, openIdx, "{", "}");
    }

    private static function extractBalancedBlock(
        text as String,
        openIndex as Number,
        openChar as String,
        closeChar as String
    ) as String? {
        if (openIndex < 0 || openIndex >= text.length()) {
            return null;
        }
        if (!text.substring(openIndex, openIndex + 1).equals(openChar)) {
            return null;
        }

        var depth = 0;
        var inString = false;
        var escaped = false;
        for (var i = openIndex; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);

            if (inString) {
                if (escaped) {
                    escaped = false;
                } else if (ch.equals("\\")) {
                    escaped = true;
                } else if (ch.equals("\"")) {
                    inString = false;
                }
                continue;
            }

            if (ch.equals("\"")) {
                inString = true;
            } else if (ch.equals(openChar)) {
                depth += 1;
            } else if (ch.equals(closeChar)) {
                depth -= 1;
                if (depth == 0) {
                    return text.substring(openIndex, i + 1);
                }
            }
        }

        return null;
    }

    private static function splitTopLevelObjects(arrayJson as String) as Array<String> {
        var objects = [] as Array<String>;
        if (arrayJson == null || arrayJson.length() < 2) {
            return objects;
        }

        var normalized = normalizeJson(arrayJson);
        if (!startsWith(normalized, "[") || !endsWith(normalized, "]")) {
            return objects;
        }

        var inString = false;
        var escaped = false;
        var objectDepth = 0;
        var objectStart = -1;

        for (var i = 1; i < normalized.length() - 1; i++) {
            var ch = normalized.substring(i, i + 1);

            if (inString) {
                if (escaped) {
                    escaped = false;
                } else if (ch.equals("\\")) {
                    escaped = true;
                } else if (ch.equals("\"")) {
                    inString = false;
                }
                continue;
            }

            if (ch.equals("\"")) {
                inString = true;
                continue;
            }

            if (ch.equals("{")) {
                if (objectDepth == 0) {
                    objectStart = i;
                }
                objectDepth += 1;
                continue;
            }

            if (ch.equals("}")) {
                objectDepth -= 1;
                if (objectDepth == 0 && objectStart >= 0) {
                    objects.add(normalized.substring(objectStart, i + 1));
                    objectStart = -1;
                }
            }
        }

        return objects;
    }

    private static function normalizeJson(input as String) as String {
        var output = "";
        var inString = false;
        var escaped = false;

        for (var i = 0; i < input.length(); i++) {
            var ch = input.substring(i, i + 1);

            if (inString) {
                output += ch;
                if (escaped) {
                    escaped = false;
                } else if (ch.equals("\\")) {
                    escaped = true;
                } else if (ch.equals("\"")) {
                    inString = false;
                }
                continue;
            }

            if (ch.equals("\"")) {
                inString = true;
                output += ch;
                continue;
            }

            if (
                ch.equals(" ") ||
                ch.equals("\n") ||
                ch.equals("\r") ||
                ch.equals("\t")
            ) {
                continue;
            }

            output += ch;
        }

        return output;
    }

    private static function unescapeJsonString(input as String) as String {
        var output = "";
        var escaped = false;
        for (var i = 0; i < input.length(); i++) {
            var ch = input.substring(i, i + 1);
            if (escaped) {
                if (ch.equals("n")) {
                    output += "\n";
                } else if (ch.equals("r")) {
                    output += "\r";
                } else if (ch.equals("t")) {
                    output += "\t";
                } else {
                    output += ch;
                }
                escaped = false;
                continue;
            }

            if (ch.equals("\\")) {
                escaped = true;
            } else {
                output += ch;
            }
        }
        return output;
    }

    private static function isDigit(ch as String) as Boolean {
        return ch.equals("0") || ch.equals("1") || ch.equals("2") || ch.equals("3") || ch.equals("4") ||
               ch.equals("5") || ch.equals("6") || ch.equals("7") || ch.equals("8") || ch.equals("9");
    }

    private static function startsWith(text as String, prefix as String) as Boolean {
        if (text == null || prefix == null) {
            return false;
        }
        if (text.length() < prefix.length()) {
            return false;
        }
        return text.substring(0, prefix.length()).equals(prefix);
    }

    private static function endsWith(text as String, suffix as String) as Boolean {
        if (text == null || suffix == null) {
            return false;
        }
        if (text.length() < suffix.length()) {
            return false;
        }
        var start = text.length() - suffix.length();
        return text.substring(start, text.length()).equals(suffix);
    }
}
