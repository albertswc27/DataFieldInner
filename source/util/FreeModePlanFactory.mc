import Toybox.Lang;

/*
 * FreeModePlanFactory builds a synthetic plan with repeating reminders.
 * This lets the DataField run in "free mode" without a downloaded plan.
 */
class FreeModePlanFactory {
    static function build(
        intervalSec as Number,
        choPerItem as Number,
        naPerItem as Number,
        itemName as String,
        maxDurationSec as Number
    ) as NutritionPlan {
        var safeInterval = intervalSec;
        if (safeInterval <= 0) {
            safeInterval = 900; // 15 minutes
        }

        var safeDuration = maxDurationSec;
        if (safeDuration < safeInterval) {
            safeDuration = safeInterval * 12; // At least 12 reminders
        }

        var safeItemName = itemName;
        if (safeItemName == null || safeItemName.equals("")) {
            safeItemName = "Recordatorio";
        }

        var safeCHO = choPerItem >= 0 ? choPerItem : 0;
        var safeNa = naPerItem >= 0 ? naPerItem : 0;

        var items = [] as Array<NutritionItem>;
        var nextTime = safeInterval;
        var index = 1;
        while (nextTime <= safeDuration && items.size() < 240) {
            var itemId = "free-" + index.format("%d");
            var nutrients = {"cho" => safeCHO, "na" => safeNa} as Dictionary<String, Number>;
            items.add(new NutritionItem(itemId, safeItemName, nextTime, nutrients, null));
            nextTime += safeInterval;
            index += 1;
        }

        var totalCHO = safeCHO * items.size();
        var totalNa = safeNa * items.size();

        return new NutritionPlan(
            "free-mode",
            "Modo Libre",
            items,
            totalCHO,
            totalNa
        );
    }
}
