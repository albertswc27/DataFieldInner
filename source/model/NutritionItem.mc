import Toybox.Lang;

/*
 * NutritionItem - Represents a single nutrition item in a plan.
 * Runtime state is tracked to avoid silent auto-consumption and to support
 * explicit session state transitions (pending, due, consumed, skipped, missed).
 */
class NutritionItem {
    const STATE_PENDING = "pending";
    const STATE_DUE = "due";
    const STATE_CONSUMED = "consumed";
    const STATE_SKIPPED = "skipped";
    const STATE_MISSED = "missed";

    var id as String;
    var name as String;
    var scheduledTime as Number;  // Seconds from session start
    var nutrients as Dictionary<String, Number>;
    var iconKey as String or Null;
    var state as String = "pending";
    var dueAt as Number?;
    var resolvedAt as Number?;
    var alertSent as Boolean = false;

    function initialize(id as String, name as String, scheduledTime as Number, 
                       nutrients as Dictionary<String, Number>, iconKey as String or Null) {
        self.id = id;
        self.name = name;
        self.scheduledTime = scheduledTime >= 0 ? scheduledTime : 0;
        self.nutrients = nutrients != null ? nutrients : {} as Dictionary<String, Number>;
        self.iconKey = iconKey;
        resetRuntimeState();
    }

    function resetRuntimeState() as Void {
        state = STATE_PENDING;
        dueAt = null;
        resolvedAt = null;
        alertSent = false;
    }

    function isResolved() as Boolean {
        return state == STATE_CONSUMED || state == STATE_SKIPPED || state == STATE_MISSED;
    }

    function markDue(elapsedSeconds as Number) as Void {
        if (state == STATE_PENDING) {
            state = STATE_DUE;
            dueAt = elapsedSeconds;
            resolvedAt = null;
            alertSent = false;
        }
    }

    function markConsumed(elapsedSeconds as Number) as Void {
        state = STATE_CONSUMED;
        resolvedAt = elapsedSeconds;
    }

    function markSkipped(elapsedSeconds as Number) as Void {
        state = STATE_SKIPPED;
        resolvedAt = elapsedSeconds;
    }

    function markMissed(elapsedSeconds as Number) as Void {
        state = STATE_MISSED;
        resolvedAt = elapsedSeconds;
    }

    function needsAlert() as Boolean {
        return state == STATE_DUE && !alertSent;
    }

    function markAlertSent() as Void {
        alertSent = true;
    }

    function getNutrient(key as String) as Number {
        if (nutrients != null && nutrients.hasKey(key)) {
            var value = nutrients[key];
            if (value instanceof Number) {
                return value as Number;
            }
        }
        return 0;
    }
}
