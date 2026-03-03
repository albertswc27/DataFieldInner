import Toybox.Lang;

/*
 * NutritionSessionEngine centralizes session timing, item state transitions,
 * nutrient accumulation and rolling intake-rate calculations.
 */
class NutritionSessionEngine {
    hidden var _plan as NutritionPlan?;
    hidden var _elapsedSeconds as Number;
    hidden var _toleranceSec as Number;
    hidden var _currentIndex as Number;
    hidden var _autoConsumePlannedItems as Boolean;
    hidden var _dueJitterGraceSec as Number;
    hidden var _alertCatchupGraceSec as Number;

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
        _dueJitterGraceSec = 10;
        _alertCatchupGraceSec = 45;
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

    function setDueJitterGraceSec(seconds as Number) as Void {
        if (seconds == null || seconds < 0) {
            return;
        }
        _dueJitterGraceSec = seconds;
    }

    function setAlertCatchupGraceSec(seconds as Number) as Void {
        if (seconds == null || seconds < 0) {
            return;
        }
        _alertCatchupGraceSec = seconds;
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
            // Guard against timer quantization/jitter (common in simulator and some devices).
            // With tolerance=0 we still allow a short due window so the item is not lost
            // if compute skips the exact scheduled second.
            var effectiveTolerance = getEffectivePostDueToleranceSec();
            var windowEnd = item.scheduledTime + effectiveTolerance;

            if (_elapsedSeconds < windowStart) {
                return;
            }

            // Auto-consume strategy:
            // if the item is already due and scheduled time is reached, auto-consume it.
            // This lets the UI emit the due alert first (important for non-interactive DataField UX).
            if (_autoConsumePlannedItems && item.state == "due" && _elapsedSeconds >= item.scheduledTime) {
                resolveConsumedItem(item, item.scheduledTime);
                _currentIndex += 1;
                continue;
            }

            if (_elapsedSeconds <= windowEnd) {
                var preDueState = item.state;
                item.markDue(_elapsedSeconds);
                if (preDueState != "due" && item.state == "due") {
                    System.println("LOG: item due id=" + item.id + " t=" + _elapsedSeconds + " (window)");
                }
                return;
            }

            // In DataField mode the view owns the alert/auto-consume UX. Keep a wider
            // catch-up due window so coarse simulator/device cadence does not skip the
            // notification path and mark items missed prematurely.
            if (!_autoConsumePlannedItems && !item.isResolved()) {
                var catchupEnd = item.scheduledTime + getEffectiveAlertCatchupSec();
                if (_elapsedSeconds <= catchupEnd) {
                    var preCatchupState = item.state;
                    item.markDue(_elapsedSeconds);
                    if (preCatchupState != "due" && item.state == "due") {
                        System.println("LOG: item due id=" + item.id + " t=" + _elapsedSeconds + " (wide-catchup)");
                    }
                    return;
                }
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

    /*
     * Returns consecutive due items that belong to the same minute bucket as the
     * current due item. This is used to handle stacked reminders (e.g. gel + salt)
     * without losing nutritional accumulation consistency.
     */
    function getCurrentDueMinuteBatch(maxItems as Number) as Array<NutritionItem> {
        var batch = [] as Array<NutritionItem>;

        if (_plan == null || _currentIndex >= _plan.items.size()) {
            return batch;
        }

        var first = getCurrentItem();
        if (first == null) {
            return batch;
        }
        if (first.state != "due") {
            var firstLatestDueSec = first.scheduledTime + getEffectiveAlertCatchupSec();
            var firstReadyByTime =
                first.state == "pending" &&
                _elapsedSeconds >= first.scheduledTime &&
                _elapsedSeconds <= firstLatestDueSec;
            if (!firstReadyByTime) {
                return batch;
            }
        }

        var limit = maxItems;
        if (limit <= 0) {
            limit = 8;
        }

        var minuteBucket = first.scheduledTime - (first.scheduledTime % 60);
        var effectiveTolerance = getEffectiveAlertCatchupSec();

        for (var i = _currentIndex; i < _plan.items.size() && batch.size() < limit; i++) {
            var item = _plan.items[i];
            if (item == null || item.isResolved()) {
                continue;
            }

            var itemBucket = item.scheduledTime - (item.scheduledTime % 60);
            if (itemBucket != minuteBucket) {
                break;
            }

            // Allow pending siblings in the same minute if they are already due by time,
            // so the UI can build a single batch alert before consuming them sequentially.
            if (item.state == "due") {
                batch.add(item);
                continue;
            }

            if (item.state == "pending") {
                var latestDueSec = item.scheduledTime + effectiveTolerance;
                if (_elapsedSeconds >= item.scheduledTime && _elapsedSeconds <= latestDueSec) {
                    batch.add(item);
                    continue;
                }
            }

            break;
        }

        return batch;
    }

    function markAlertSentForCurrentItem() as Void {
        var item = getCurrentItem();
        if (item != null && item.state == "due") {
            item.markAlertSent();
        }
    }

    /*
     * Recover current pending item into due state when timer jitter causes the UI to
     * hit/skip the scheduled second. Keeps notification flow robust in simulator and
     * on devices with coarse compute cadence.
     */
    function ensureCurrentItemDueIfReached() as Boolean {
        var item = getCurrentItem();
        if (item == null || item.isResolved()) {
            return false;
        }
        if (item.state == "due") {
            return true;
        }
        if (item.state != "pending") {
            return false;
        }
        if (_elapsedSeconds < item.scheduledTime) {
            return false;
        }

        var latestDueSec = item.scheduledTime + getEffectiveAlertCatchupSec();
        if (_elapsedSeconds > latestDueSec) {
            return false;
        }

        item.markDue(_elapsedSeconds);
        System.println("LOG: item due id=" + item.id + " t=" + _elapsedSeconds + " (catchup)");
        return true;
    }

    /*
     * Stronger due recovery for coarse compute cadence: if the current compute tick
     * crossed the scheduled time, allow the item to become due even if we are now
     * slightly past the nominal due window.
     */
    function ensureCurrentItemDueForNotification(previousElapsedSeconds as Number) as Boolean {
        var item = getCurrentItem();
        if (item == null || item.isResolved()) {
            return false;
        }
        if (item.state == "due") {
            return true;
        }
        if (item.state != "pending") {
            return false;
        }
        if (_elapsedSeconds < item.scheduledTime) {
            return false;
        }

        var crossedSchedule = previousElapsedSeconds < item.scheduledTime && _elapsedSeconds >= item.scheduledTime;
        if (!crossedSchedule) {
            return ensureCurrentItemDueIfReached();
        }

        item.markDue(_elapsedSeconds);
        System.println("LOG: item due id=" + item.id + " t=" + _elapsedSeconds + " (crossed)");
        return true;
    }

    // Reserved for future interactions (e.g. DataFieldAlert response handlers).
    function consumeCurrentDueItem() as Boolean {
        var item = getCurrentItem();
        if (item == null || item.state != "due") {
            return false;
        }

        System.println("LOG: item consumed (due) id=" + item.id + " t=" + _elapsedSeconds);
        resolveConsumedItem(item, _elapsedSeconds);

        _currentIndex += 1;
        evaluateTimeline();
        logNextItem("LOG: next item recalculated");
        return true;
    }

    function consumeCurrentDueItemById(itemId as String) as Boolean {
        var item = getCurrentItem();
        if (item == null || !item.id.equals(itemId)) {
            return false;
        }
        return consumeCurrentDueItem();
    }

    /*
     * DataField fallback for non-interactive auto-consume: if the current item is
     * pending but its scheduled time has been reached (within catch-up window),
     * promote to due and consume.
     */
    function consumeCurrentScheduledItemById(itemId as String) as Boolean {
        var item = getCurrentItem();
        if (item == null || !item.id.equals(itemId) || item.isResolved()) {
            return false;
        }
        if (_elapsedSeconds < item.scheduledTime) {
            return false;
        }

        var catchupEnd = item.scheduledTime + getEffectiveAlertCatchupSec();
        if (_elapsedSeconds > catchupEnd) {
            return false;
        }

        if (item.state == "pending") {
            item.markDue(_elapsedSeconds);
        }

        if (item.state != "due") {
            return false;
        }

        return consumeCurrentDueItem();
    }

    /*
     * DataField alert fallback: force consume the current item after an alert
     * even if simulator cadence/state ordering has left it in an unexpected state.
     * This preserves the non-interactive UX contract (alerted item => consumed).
     */
    function forceConsumeCurrentItemById(itemId as String) as Boolean {
        var item = getCurrentItem();
        if (item == null || !item.id.equals(itemId) || item.isResolved()) {
            return false;
        }
        if (_elapsedSeconds < item.scheduledTime) {
            return false;
        }

        System.println(
            "LOG: item consumed (forced) id=" + item.id +
            " state=" + item.state + " t=" + _elapsedSeconds
        );

        resolveConsumedItem(item, _elapsedSeconds);
        _currentIndex += 1;
        evaluateTimeline();
        logNextItem("LOG: next item recalculated");
        return true;
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

        System.println(
            "LOG: totals updated CHO=" + _consumedCHO +
            " Na=" + _consumedNa +
            " count=" + _consumedCount
        );
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

    private function getEffectivePostDueToleranceSec() as Number {
        var tolerance = _toleranceSec;
        if (tolerance < _dueJitterGraceSec) {
            tolerance = _dueJitterGraceSec;
        }
        return tolerance;
    }

    private function getEffectiveAlertCatchupSec() as Number {
        var catchup = _alertCatchupGraceSec;
        var postDueTolerance = getEffectivePostDueToleranceSec();
        if (catchup < postDueTolerance) {
            catchup = postDueTolerance;
        }
        return catchup;
    }

    private function logNextItem(prefix as String) as Void {
        var nextItem = getCurrentItem();
        if (nextItem == null) {
            System.println(prefix + " next=<none> (complete)");
            return;
        }
        System.println(
            prefix + " next=" + nextItem.id +
            " (" + nextItem.name + ")" +
            " t=" + nextItem.scheduledTime +
            " state=" + nextItem.state
        );
    }
}
