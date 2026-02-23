import Toybox.Lang;

/*
 * NutritionSessionEngine centralizes session timing and item state transitions.
 * It intentionally avoids auto-consuming items; unresolved items become missed.
 */
class NutritionSessionEngine {
    hidden var _plan as NutritionPlan?;
    hidden var _elapsedSeconds as Number;
    hidden var _toleranceSec as Number;
    hidden var _currentIndex as Number;
    hidden var _autoConsumePlannedItems as Boolean;

    hidden var _consumedCHO as Number;
    hidden var _consumedNa as Number;
    hidden var _consumedCount as Number;
    hidden var _skippedCount as Number;
    hidden var _missedCount as Number;
    hidden var _consumptionHistory as Array<Dictionary>;

    function initialize() {
        _plan = null;
        _elapsedSeconds = 0;
        _toleranceSec = 30;
        _currentIndex = 0;
        _autoConsumePlannedItems = true;
        _consumedCHO = 0;
        _consumedNa = 0;
        _consumedCount = 0;
        _skippedCount = 0;
        _missedCount = 0;
        _consumptionHistory = [] as Array<Dictionary>;
    }

    function setToleranceSec(toleranceSec as Number) as Void {
        _toleranceSec = toleranceSec >= 0 ? toleranceSec : 0;
    }

    function setAutoConsumePlannedItems(enabled as Boolean) as Void {
        _autoConsumePlannedItems = enabled;
    }

    function setPlan(plan as NutritionPlan?) as Void {
        _plan = plan;
        resetSession();
    }

    function resetSession() as Void {
        _elapsedSeconds = 0;
        _currentIndex = 0;
        _consumedCHO = 0;
        _consumedNa = 0;
        _consumedCount = 0;
        _skippedCount = 0;
        _missedCount = 0;
        _consumptionHistory = [] as Array<Dictionary>;

        if (_plan != null) {
            _plan.resetRuntimeState();
        }
    }

    function updateElapsedSeconds(elapsedSeconds as Number) as Void {
        if (elapsedSeconds < 0) {
            return;
        }

        // New activity or timer reset.
        if (elapsedSeconds < _elapsedSeconds) {
            resetSession();
        }

        _elapsedSeconds = elapsedSeconds;
        evaluateTimeline();
    }

    /*
     * Resolve timeline state until the first actionable item.
     */
    private function evaluateTimeline() as Void {
        if (_plan == null || !_plan.hasItems()) {
            return;
        }

        var safety = 0;
        while (safety < 512) {
            safety += 1;
            advanceToNextActionable();

            var item = getCurrentItem();
            if (item == null) {
                return;
            }

            var windowStart = item.scheduledTime - _toleranceSec;
            if (windowStart < 0) {
                windowStart = 0;
            }
            var windowEnd = item.scheduledTime + _toleranceSec;

            if (_elapsedSeconds < windowStart) {
                return;
            }

            // Auto-consume strategy:
            // once scheduled time is reached, mark as consumed automatically.
            if (_autoConsumePlannedItems && _elapsedSeconds >= item.scheduledTime) {
                resolveConsumedItem(item, item.scheduledTime);
                _currentIndex += 1;
                continue;
            }

            if (_elapsedSeconds <= windowEnd) {
                item.markDue(_elapsedSeconds);
                return;
            }

            // Window has passed without explicit user action.
            if (!item.isResolved()) {
                item.markMissed(_elapsedSeconds);
                _missedCount += 1;
            }

            _currentIndex += 1;
        }
    }

    private function advanceToNextActionable() as Void {
        if (_plan == null) {
            return;
        }

        while (_currentIndex < _plan.items.size()) {
            var item = _plan.items[_currentIndex];
            if (item.isResolved()) {
                _currentIndex += 1;
            } else {
                return;
            }
        }
    }

    function getCurrentItem() as NutritionItem? {
        if (_plan == null || _currentIndex >= _plan.items.size()) {
            return null;
        }
        return _plan.items[_currentIndex];
    }

    function getPendingAlertItem() as NutritionItem? {
        var item = getCurrentItem();
        if (item != null && item.needsAlert()) {
            return item;
        }
        return null;
    }

    function markAlertSentForCurrentItem() as Void {
        var item = getCurrentItem();
        if (item != null && item.state == "due") {
            item.markAlertSent();
        }
    }

    // Reserved for future interactions (e.g. DataFieldAlert response handlers).
    function consumeCurrentDueItem() as Boolean {
        var item = getCurrentItem();
        if (item == null || item.state != "due") {
            return false;
        }

        resolveConsumedItem(item, _elapsedSeconds);

        _currentIndex += 1;
        evaluateTimeline();
        return true;
    }

    function consumeCurrentDueItemById(itemId as String) as Boolean {
        var item = getCurrentItem();
        if (item == null || !item.id.equals(itemId)) {
            return false;
        }
        return consumeCurrentDueItem();
    }

    // Reserved for future interactions (e.g. DataFieldAlert response handlers).
    function skipCurrentDueItem() as Boolean {
        var item = getCurrentItem();
        if (item == null || item.state != "due") {
            return false;
        }

        item.markSkipped(_elapsedSeconds);
        _skippedCount += 1;

        _currentIndex += 1;
        evaluateTimeline();
        return true;
    }

    function skipCurrentDueItemById(itemId as String) as Boolean {
        var item = getCurrentItem();
        if (item == null || !item.id.equals(itemId)) {
            return false;
        }
        return skipCurrentDueItem();
    }

    function getPlan() as NutritionPlan? {
        return _plan;
    }

    function getElapsedSeconds() as Number {
        return _elapsedSeconds;
    }

    function getCurrentIndexOneBased() as Number {
        if (_plan == null || _plan.items.size() == 0) {
            return 0;
        }
        var index = _currentIndex + 1;
        return index > _plan.items.size() ? _plan.items.size() : index;
    }

    function getConsumedCHO() as Number {
        return _consumedCHO;
    }

    function getConsumedNa() as Number {
        return _consumedNa;
    }

    function getConsumedCount() as Number {
        return _consumedCount;
    }

    function getSkippedCount() as Number {
        return _skippedCount;
    }

    function getMissedCount() as Number {
        return _missedCount;
    }

    function getCHORate(elapsedSeconds as Number) as Float {
        return calculateRollingRate(elapsedSeconds, "cho");
    }

    function getNaRate(elapsedSeconds as Number) as Float {
        return calculateRollingRate(elapsedSeconds, "na");
    }

    function isComplete() as Boolean {
        return _plan != null && _currentIndex >= _plan.items.size();
    }

    private function resolveConsumedItem(item as NutritionItem, consumedAt as Number) as Void {
        if (item == null || item.isResolved()) {
            return;
        }

        item.markConsumed(consumedAt);
        _consumedCount += 1;

        var cho = item.getNutrient("cho");
        var na = item.getNutrient("na");
        _consumedCHO += cho;
        _consumedNa += na;

        _consumptionHistory.add({
            "time" => consumedAt,
            "cho" => cho,
            "na" => na
        });
    }

    private function calculateRollingRate(elapsedSeconds as Number, nutrientKey as String) as Float {
        if (elapsedSeconds <= 0) {
            return 0.0;
        }

        var windowSeconds = 3600;
        var minWindowSeconds = 1800;
        var windowEnd = elapsedSeconds;
        var windowStart = elapsedSeconds - windowSeconds;
        if (windowStart < 0) {
            windowStart = 0;
        }

        var totalInWindow = 0.0;
        var firstConsumptionTime = -1;

        for (var i = 0; i < _consumptionHistory.size(); i++) {
            var entry = _consumptionHistory[i] as Dictionary;
            var time = entry["time"] as Number;

            if (time >= windowStart && time <= windowEnd) {
                totalInWindow += (entry[nutrientKey] as Number).toFloat();
                if (firstConsumptionTime < 0 || time < firstConsumptionTime) {
                    firstConsumptionTime = time;
                }
            }
        }

        if (totalInWindow <= 0.0) {
            return 0.0;
        }

        var effectiveDurationSec = elapsedSeconds - firstConsumptionTime;
        if (effectiveDurationSec < minWindowSeconds) {
            effectiveDurationSec = minWindowSeconds;
        }
        if (effectiveDurationSec > windowSeconds) {
            effectiveDurationSec = windowSeconds;
        }

        var effectiveDurationHours = effectiveDurationSec.toFloat() / 3600.0;
        return totalInWindow / effectiveDurationHours;
    }
}
