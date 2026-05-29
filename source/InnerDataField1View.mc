import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

/*
 * InnerDataField1View renders nutrition guidance inside native Garmin activities.
 * Session progression is delegated to NutritionSessionEngine.
 */
class InnerDataField1View extends WatchUi.DataField {
    hidden var mEngine as NutritionSessionEngine;

    hidden var mToleranceSec as Number = 30;
    hidden var mVibrationEnabled as Boolean = true;
    hidden var mSoundEnabled as Boolean = true;
    hidden var mShowCountdown as Boolean = true;
    hidden var mShowNutrients as Boolean = true;
    hidden var mAutoConsumePlannedItems as Boolean = true;
    hidden var mUseFreeMode as Boolean = false;
    hidden var mUseQuickDemoPlan as Boolean = false;
    hidden var mFreeIntervalSec as Number = 900;
    hidden var mFreeCHO as Number = 25;
    hidden var mFreeNa as Number = 150;
    hidden var mFreeItemName as String = "Recordatorio";
    hidden var mFreeMaxDurationMin as Number = 480;
    hidden var mSelectedPlanId as String = "";

    hidden var mSyncAttempted as Boolean = false;
    hidden var mSyncSuccess as Boolean = false;
    hidden var mSyncInProgress as Boolean = false;
    hidden var mSyncErrorMessage as String = "";
    hidden var mLastBackgroundSyncSec as Number = -9999;
    hidden var mBackgroundSyncIntervalSec as Number = 120;
    // Periodic mid-activity refresh even when a real plan is loaded (every 30 min).
    hidden var mLastMidActivitySyncSec as Number = -9999;
    private const MID_ACTIVITY_SYNC_INTERVAL_SEC = 1800;

    // Alert retry/fallback state for due items.
    hidden var mLastAlertItemId as String = "";
    hidden var mLastAlertAtSec as Number = -9999;
    hidden var mAlertRepeatSec as Number = 8;
    hidden var mDueIconCacheItemId as String = "";
    hidden var mDueIconCache;
    hidden var mLastSettingsVersion as Number = -1;
    hidden var mRecentAutoConsumeItemName as String = "";
    hidden var mRecentAutoConsumeItemCategory as String = "";
    hidden var mRecentAutoConsumeCHO as Number = 0;
    hidden var mRecentAutoConsumeNa as Number = 0;
    hidden var mRecentAutoConsumeAtSec as Number = -9999;
    hidden var mRecentAutoConsumeAtMs as Number = -1;
    hidden var mRecentAutoConsumeNoticeSec as Number = 5;
    hidden var mRecentAutoConsumeBatchCount as Number = 1;
    hidden var mRecentAutoConsumeBatchNames as String = "";
    hidden var mRecentAutoConsumeIcon;
    hidden var mRecentAutoConsumeSequence as Array<Dictionary> = [] as Array<Dictionary>;
    hidden var mRecentAutoConsumeSequenceStepSec as Number = 5;
    hidden var mRecentAutoConsumeCommitted as Boolean = false;
    hidden var mPendingAutoConsumeEntries as Array<Dictionary> = [] as Array<Dictionary>;
    hidden var mPendingAutoConsumeQueuedAtSec as Number = -9999;
    hidden var mTimerRunning as Boolean = false;
    hidden var mSessionStarted as Boolean = false;
    // Stagger same-minute siblings: space alerts ~30s apart so each product
    // gets its own vibration and overlay instead of one combined batch.
    hidden var mSameMinuteStaggerSec as Number = 30;
    hidden var mLastAlertMinuteBucket as Number = -1;
    // TEMP QA: visual timing trace for batch overlay duration validation.
    hidden var mDebugOverlayTiming as Boolean = false;
    // Ambient temperature cached from Activity.Info (null if device has no sensor).
    hidden var mAmbientTemp as Float or Null = null;

    function initialize() {
        DataField.initialize();

        mEngine = new NutritionSessionEngine();
        loadSettings();
        if (!loadPlanFromSyncCache()) {
            loadPlanFromProperties();
        }
        if (!mUseFreeMode && !mUseQuickDemoPlan) {
            attemptSync(false);
        } else {
            mSyncAttempted = true;
            mSyncSuccess = true;
        }
        mLastSettingsVersion = readSettingsVersion();

        System.println("INNER DataField initialized build=" + BuildInfo.getBuild());
    }

    function onLayout(dc as Graphics.Dc) as Void {
        // Dynamic layout.
    }

    function compute(info as Activity.Info) as Void {
        var previousElapsedSeconds = mEngine.getElapsedSeconds();
        if (info != null && info has :elapsedTime && info.elapsedTime != null) {
            var elapsedSeconds = (info.elapsedTime / 1000).toNumber();
            if (mTimerRunning) {
                mEngine.updateElapsedSeconds(elapsedSeconds);
            }
        }
        // Cache ambient temperature only if the device provides it.
        if (info != null && info has :ambientTemperature && info.ambientTemperature != null) {
            mAmbientTemp = info.ambientTemperature as Float;
        }
        maybeRefreshFromSettings();

        if (!mTimerRunning) {
            // Freeze countdown and suppress notifications/sync while activity timer is stopped.
            return;
        }

        maybeCommitPendingAutoConsume();

        // DataField alerts are informational and can be disabled by user/device.
        // Retry while item is due and keep the on-field "AHORA" fallback visible.
        var currentItem = mEngine.getCurrentItem();
        if (currentItem != null && currentItem.state != "due"
            && mEngine.ensureCurrentItemDueForNotification(previousElapsedSeconds)) {
            currentItem = mEngine.getCurrentItem();
        }
        var shouldProcessOverdueItem = false;
        if (currentItem != null && !currentItem.isResolved()) {
            shouldProcessOverdueItem = mEngine.getElapsedSeconds() >= currentItem.scheduledTime;
        }

        if (currentItem != null && (currentItem.state == "due" || shouldProcessOverdueItem)) {
            maybeNotifyDueItem(currentItem);
        }

        maybeRetryPlanSync();
    }

    // DataFieldAlert does not accept user input; keep methods as compatibility no-op hooks.
    function onAlertConsumed(itemId as String) as Void {
        if (mEngine.consumeCurrentDueItemById(itemId)) {
            System.println("DataField alert consumed: " + itemId);
        }
    }

    function onAlertSkipped(itemId as String) as Void {
        if (mEngine.skipCurrentDueItemById(itemId)) {
            System.println("DataField alert skipped: " + itemId);
        }
    }

    function onTimerReset() as Void {
        mEngine.resetSession();
        resetAlertTracking();
        mTimerRunning = false;
        mSessionStarted = false;
    }

    function onTimerStart() as Void {
        mTimerRunning = true;

        if (mSessionStarted) {
            System.println("Timer resumed; keeping session state");
            return;
        }

        mSessionStarted = true;

        // Reload in case settings/plan changed while activity was not running.
        loadSettings();
        if (!loadPlanFromSyncCache()) {
            loadPlanFromProperties();
        }
        resetAlertTracking();
        mLastSettingsVersion = readSettingsVersion();
        if (!mUseFreeMode && !mUseQuickDemoPlan) {
            // Try to refresh from web at activity start (pairing code required).
            attemptSync(true);
        }
    }

    function onTimerStop() as Void {
        mTimerRunning = false;
        System.println("Timer stopped/paused; countdown frozen at t=" + mEngine.getElapsedSeconds());
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var plan = mEngine.getPlan();

        var bgColor = getBackgroundColor();
        dc.setColor(bgColor, bgColor);
        dc.fillRectangle(0, 0, width, height);

        var textColor = Graphics.COLOR_WHITE;
        if (plan == null || !plan.hasItems()) {
            drawNoPlan(dc, width, height, textColor);
            return;
        }

        if (mEngine.isComplete()) {
            drawCompleted(dc, width, height, textColor);
            return;
        }

        if (hasRecentAutoConsumeNotice()) {
            drawRecentAutoConsumeOverlay(dc, width, height);
            return;
        }

        drawHUD(dc, width, height, textColor);
    }

    private function attemptSync(force as Boolean) as Void {
        if (mUseFreeMode || mUseQuickDemoPlan) {
            return;
        }

        if (mSyncInProgress) {
            return;
        }

        if (mSyncAttempted && !force) {
            return;
        }

        if (!hasPairingCodeConfigured()) {
            mSyncAttempted = true;
            mSyncSuccess = false;
            mSyncErrorMessage = "No pairing code";
            // Do NOT fallback to free mode — show "Sin Plan" screen so the user
            // knows they need to configure the pairing code.
            return;
        }

        mSyncInProgress = true;
        SyncService.getInstance().downloadPlans(method(:onSyncComplete), force);
    }

    function onSyncComplete(success as Boolean, message as String) as Void {
        mSyncInProgress = false;
        mSyncAttempted = true;
        mSyncSuccess = success;
        mSyncErrorMessage = message;

        if (success) {
            System.println("Sync successful: " + message);
        } else {
            System.println("Sync failed: " + message);
        }

        var loadedFromSyncCache = false;
        if (success) {
            loadedFromSyncCache = loadPlanFromSyncCache();
        }

        if (!loadedFromSyncCache) {
            loadPlanFromProperties();
        }

        if (success && !hasRealPlanLoaded()) {
            success = false;
            mSyncSuccess = false;
            mSyncErrorMessage = "Sync sin plan";
        }

        if (!success) {
            fallbackToFreeModeIfNoPlan(message);
        }
    }

    private function maybeRefreshFromSettings() as Void {
        var currentVersion = readSettingsVersion();
        if (currentVersion <= mLastSettingsVersion) {
            return;
        }

        mLastSettingsVersion = currentVersion;
        System.println("Settings refresh (v=" + currentVersion + ")");

        // Snapshot plan-affecting fields before reload to detect meaningful changes.
        var prevFreeMode = mUseFreeMode;
        var prevQuickDemo = mUseQuickDemoPlan;
        var prevSelectedPlanId = mSelectedPlanId;

        loadSettings();

        // Only reset session state and alert tracking when the plan itself changes.
        // Display-only setting changes (vibration, sound, countdown, nutrients) must
        // not disrupt an in-progress overlay or consume sequence.
        var planAffectingChange = (prevFreeMode != mUseFreeMode)
            || (prevQuickDemo != mUseQuickDemoPlan)
            || !prevSelectedPlanId.equals(mSelectedPlanId);

        if (planAffectingChange) {
            mSyncAttempted = false;
            mSyncSuccess = false;
            mSyncErrorMessage = "";
            loadPlanFromProperties();
            resetAlertTracking();
        }

        if (!mUseFreeMode && !mUseQuickDemoPlan) {
            if (planAffectingChange) {
                mSyncAttempted = false;
                mSyncSuccess = false;
            }
            // Always attempt sync on any settings change — may be a pairing code update.
            attemptSync(true);
        } else if (planAffectingChange) {
            mSyncAttempted = true;
            mSyncSuccess = true;
        }
    }

    private function readSettingsVersion() as Number {
        try {
            var app = getApp();
            if (app != null && app has :getSettingsVersion) {
                return app.getSettingsVersion();
            }
        } catch (ex) {
            // Keep last known version if app handle is not available.
        }

        return mLastSettingsVersion;
    }

    private function loadPlanFromProperties() as Void {
        var plan = null;

        // No pairing code and not in special mode → stay on "Sin Plan" screen.
        if (!mUseFreeMode && !mUseQuickDemoPlan && !hasPairingCodeConfigured()) {
            return;
        }

        try {
            if (mUseQuickDemoPlan) {
                plan = QuickDemoPlanFactory.buildOneMinuteDemo();
                System.println("Quick demo plan loaded (1-min alerts)");
                if (plan != null) {
                    System.println("Quick demo item count: " + plan.getItemCount());
                    var q2 = plan.getItemAt(1);
                    var q2b = plan.getItemAt(2);
                    if (q2 != null && q2b != null) {
                        System.println(
                            "Quick demo batch marker: " +
                            q2.name + " @" + q2.scheduledTime + "s + " +
                            q2b.name + " @" + q2b.scheduledTime + "s"
                        );
                    }
                }
            } else if (mUseFreeMode) {
                plan = FreeModePlanFactory.build(
                    mFreeIntervalSec,
                    mFreeCHO,
                    mFreeNa,
                    mFreeItemName,
                    mFreeMaxDurationMin * 60
                );
            } else {
                // Multi-plan offline desde Storage (sin el limite de 10000 chars de
                // las propiedades string): permite seleccionar/cambiar de plan con
                // selectedPlanId aunque el envelope JSON no quepa en una propiedad.
                var storedPlans = SyncService.getInstance().loadPersistedAllPlans();
                if (storedPlans != null && storedPlans.size() > 0) {
                    plan = selectPlan(storedPlans, mSelectedPlanId);
                }

                if (plan == null) {
                    plan = SyncService.getInstance().loadPersistedSelectedPlan();
                }

                // Fast path: use pre-selected single plan JSON first.
                if (plan == null) {
                    var planJson = Application.Properties.getValue("nutritionPlan");
                    if (planJson != null && planJson instanceof String && !planJson.equals("")) {
                        var planStr = planJson as String;
                        if (planStr.length() > 10 && planStr.length() <= 10000) {
                            plan = NutritionPlanParser.parse(planStr);
                        } else if (planStr.length() > 10000) {
                            System.println("Skip nutritionPlan parse (payload too large)");
                        }
                    }
                }

                // Fallback: parse plans envelope only if needed and within safe size.
                if (plan == null) {
                    var plansJson = Application.Properties.getValue("nutritionPlans");
                    if (plansJson != null && plansJson instanceof String && !plansJson.equals("")) {
                        var plansStr = plansJson as String;
                        if (plansStr.length() > 10 && plansStr.length() <= 10000) {
                            var parsedPlans = NutritionPlanParser.parsePlans(plansStr);
                            plan = selectPlan(parsedPlans, mSelectedPlanId);
                        } else if (plansStr.length() > 10000) {
                            System.println("Skip nutritionPlans parse (payload too large)");
                        }
                    }
                }
            }
        } catch (ex) {
            System.println("Error loading plan: " + ex.getErrorMessage());
        }

        mEngine.setPlan(plan);
        mEngine.setToleranceSec(mToleranceSec);
        resetAlertTracking();
    }

    private function loadPlanFromSyncCache() as Boolean {
        if (mUseFreeMode || mUseQuickDemoPlan) {
            return false;
        }

        // Skip cache if no pairing code configured (shows "Sin Plan" screen).
        if (!hasPairingCodeConfigured()) {
            return false;
        }

        var plan = SyncService.getInstance().getLastSyncedPlan();
        if (plan == null) {
            plan = SyncService.getInstance().loadPersistedSelectedPlan();
        }

        if (plan == null || !plan.hasItems()) {
            return false;
        }

        mEngine.setPlan(plan);
        mEngine.setToleranceSec(mToleranceSec);
        resetAlertTracking();
        return true;
    }

    private function selectPlan(plans as Array<NutritionPlan>, selectedPlanId as String) as NutritionPlan? {
        if (plans.size() == 0) {
            return null;
        }

        if (selectedPlanId != null && !selectedPlanId.equals("")) {
            for (var i = 0; i < plans.size(); i++) {
                if (plans[i].id.equals(selectedPlanId)) {
                    return plans[i];
                }
            }
        }

        return plans[0];
    }

    private function hasPlanLoaded() as Boolean {
        var plan = mEngine.getPlan();
        return plan != null && plan.hasItems();
    }

    private function hasRealPlanLoaded() as Boolean {
        var plan = mEngine.getPlan();
        return plan != null && plan.hasItems() && !plan.id.equals("free-mode");
    }

    private function fallbackToFreeModeIfNoPlan(reason as String) as Void {
        if (hasPlanLoaded()) {
            return;
        }

        var fallbackPlan = FreeModePlanFactory.build(
            mFreeIntervalSec,
            mFreeCHO,
            mFreeNa,
            mFreeItemName,
            mFreeMaxDurationMin * 60
        );

        if (fallbackPlan != null && fallbackPlan.hasItems()) {
            mEngine.setPlan(fallbackPlan);
            mEngine.setToleranceSec(mToleranceSec);
            mSyncSuccess = false;
            mSyncErrorMessage = "Fallback free mode (" + reason + ")";
            System.println("Fallback to free mode: " + reason);
        }
    }

    private function loadSettings() as Void {
        try {
            var toleranceValue = Application.Properties.getValue("toleranceSec");
            if (toleranceValue != null) {
                mToleranceSec = toleranceValue as Number;
            }

            var vibrationValue = Application.Properties.getValue("vibrationEnabled");
            if (vibrationValue != null) {
                mVibrationEnabled = vibrationValue as Boolean;
            }

            var soundValue = Application.Properties.getValue("soundEnabled");
            if (soundValue != null) {
                mSoundEnabled = soundValue as Boolean;
            }

            var countdownValue = Application.Properties.getValue("showCountdown");
            if (countdownValue != null) {
                mShowCountdown = countdownValue as Boolean;
            }

            var nutrientsValue = Application.Properties.getValue("showNutrients");
            if (nutrientsValue != null) {
                mShowNutrients = nutrientsValue as Boolean;
            }

            var autoConsumeValue = Application.Properties.getValue("autoConsumePlannedItems");
            if (autoConsumeValue != null) {
                mAutoConsumePlannedItems = autoConsumeValue as Boolean;
            }

            var freeModeValue = Application.Properties.getValue("useFreeMode");
            if (freeModeValue != null) {
                mUseFreeMode = freeModeValue as Boolean;
            }

            var quickDemoPlanValue = Application.Properties.getValue("useQuickDemoPlan");
            if (quickDemoPlanValue != null) {
                mUseQuickDemoPlan = quickDemoPlanValue as Boolean;
            }

            var freeIntervalValue = Application.Properties.getValue("freeIntervalSec");
            if (freeIntervalValue != null) {
                mFreeIntervalSec = freeIntervalValue as Number;
            }

            var freeCHOValue = Application.Properties.getValue("freeCHO");
            if (freeCHOValue != null) {
                mFreeCHO = freeCHOValue as Number;
            }

            var freeNaValue = Application.Properties.getValue("freeNa");
            if (freeNaValue != null) {
                mFreeNa = freeNaValue as Number;
            }

            var freeNameValue = Application.Properties.getValue("freeItemName");
            if (freeNameValue != null && freeNameValue instanceof String) {
                mFreeItemName = freeNameValue as String;
            }

            var freeMaxDurationValue = Application.Properties.getValue("freeMaxDurationMin");
            if (freeMaxDurationValue != null) {
                mFreeMaxDurationMin = freeMaxDurationValue as Number;
            }

            var selectedPlanValue = Application.Properties.getValue("selectedPlanId");
            if (selectedPlanValue != null) {
                mSelectedPlanId = selectedPlanValue.toString();
            }
        } catch (ex) {
            System.println("Error loading settings: " + ex.getErrorMessage());
        }

        if (mUseQuickDemoPlan) {
            // Para iteraciones visuales rápidas: alerta exacta al minuto (sin pre-alerta).
            mUseFreeMode = false;
            mToleranceSec = 0;
        }

        mEngine.setToleranceSec(mToleranceSec);
        mEngine.setDueJitterGraceSec(10);
        // 90s accommodates up to 3 same-minute items with 30s stagger between each.
        mEngine.setAlertCatchupGraceSec(90);
        // DataField UX needs "alert -> visual overlay -> consume". If the engine
        // auto-consumes on timeline evaluation, it can race ahead before the view
        // shows the alert/overlay (especially in simulator timer jitter).
        mEngine.setAutoConsumePlannedItems(false);
    }

    private function triggerAlert(item as NutritionItem) as Void {
        try {
            if (mVibrationEnabled) {
                AlertHelper.triggerVibration(item);
            }
            if (mSoundEnabled) {
                AlertHelper.triggerSound();
            }
            // Backlight siempre: refuerza el aviso en cualquier pantalla
            // (Edge con auto-dim agresivo no muestra la vibración/tono visualmente).
            AlertHelper.triggerBacklight();
        } catch (ex) {
            System.println("triggerAlert error: " + ex.getErrorMessage());
        }
    }

    private function showDueItemAlert(item as NutritionItem, alertMeta) as Boolean {
        if (!(WatchUi.DataField has :showAlert)) {
            return false;
        }

        try {
            WatchUi.DataField.showAlert(new NutritionDataFieldAlert(self, item, mAutoConsumePlannedItems, alertMeta));
            return true;
        } catch (ex) {
            System.println("showAlert failed: " + ex.getErrorMessage());
            return false;
        }
    }

    private function showDueBatchAlert(items as Array<NutritionItem>) as Boolean {
        if (items == null || items.size() == 0) {
            return false;
        }

        var totalCHO = 0;
        var totalNa = 0;
        var names = "";
        var namesAdded = 0;

        for (var i = 0; i < items.size(); i++) {
            var batchItem = items[i];
            totalCHO += batchItem.getNutrient("cho");
            totalNa += batchItem.getNutrient("na");

            if (namesAdded < 3) {
                if (!names.equals("")) {
                    names += " + ";
                }
                names += truncateText(batchItem.name, 12);
                namesAdded += 1;
            }
        }

        var extraCount = items.size() - namesAdded;
        if (extraCount > 0) {
            names += " +" + extraCount;
        }

        var alertMeta = {
            "batchMode" => true,
            "batchCount" => items.size(),
            "batchTotalCHO" => totalCHO,
            "batchTotalNa" => totalNa,
            "batchNames" => names
        };

        return showDueItemAlert(items[0], alertMeta);
    }

    private function buildBatchSummaryForItems(items as Array<NutritionItem>) as Dictionary {
        var totalCHO = 0;
        var totalNa = 0;
        var names = "";
        var namesAdded = 0;
        var entries = [] as Array<Dictionary>;

        for (var i = 0; i < items.size(); i++) {
            var it = items[i];

            var cho = it.getNutrient("cho");
            var na = it.getNutrient("na");
            var categoryLabel = ProductClassifier.getCategoryLabel(it);
            var icon = ProductIconResolver.loadForItem(it);

            totalCHO += cho;
            totalNa += na;

            if (namesAdded < 3) {
                if (!names.equals("")) {
                    names += " + ";
                }
                names += truncateText(it.name, 12);
                namesAdded += 1;
            }

            entries.add({
                "id" => it.id,
                "name" => it.name,
                "category" => categoryLabel,
                "cho" => cho,
                "na" => na,
                "icon" => icon
            });
        }

        var extraCount = items.size() - namesAdded;
        if (extraCount > 0) {
            names += " +" + extraCount;
        }

        return {
            "count" => items.size(),
            "cho" => totalCHO,
            "na" => totalNa,
            "names" => names,
            "entries" => entries
        };
    }

    private function hasPendingAutoConsumeQueue() as Boolean {
        return mPendingAutoConsumeEntries != null && mPendingAutoConsumeEntries.size() > 0;
    }

    private function queueAutoConsumeEntries(entries as Array<Dictionary> or Null) as Void {
        mPendingAutoConsumeEntries = [] as Array<Dictionary>;
        if (entries == null) {
            mPendingAutoConsumeQueuedAtSec = -9999;
            return;
        }

        for (var i = 0; i < entries.size(); i++) {
            var dictEntry = entries[i];
            try {
                if (!dictEntry.hasKey("id")) {
                    System.println("queueAutoConsumeEntries: skipped entry without id");
                    continue;
                }
                mPendingAutoConsumeEntries.add(dictEntry);
            } catch (ex) {
                System.println("queueAutoConsumeEntries cast error: " + ex.getErrorMessage());
            }
        }

        mPendingAutoConsumeQueuedAtSec = mEngine.getElapsedSeconds();
        mRecentAutoConsumeCommitted = false;
        System.println(
            "Queued pending auto-consume entries: " + mPendingAutoConsumeEntries.size() +
            " (t=" + mPendingAutoConsumeQueuedAtSec + "s)"
        );
    }

    private function getPendingAutoConsumeDelaySec() as Number {
        var delay = mRecentAutoConsumeNoticeSec;
        if (mRecentAutoConsumeSequence != null && mRecentAutoConsumeSequence.size() > 1) {
            delay = mRecentAutoConsumeSequence.size() * mRecentAutoConsumeSequenceStepSec;
        }
        if (delay < 5) {
            delay = 5;
        }
        return delay;
    }

    private function maybeCommitPendingAutoConsume() as Void {
        if (!mAutoConsumePlannedItems || !hasPendingAutoConsumeQueue()) {
            return;
        }

        var elapsedSeconds = mEngine.getElapsedSeconds();
        if ((elapsedSeconds - mPendingAutoConsumeQueuedAtSec) < getPendingAutoConsumeDelaySec()) {
            return;
        }

        var result = consumePendingAutoConsumeQueue();

        var consumedCount = result.hasKey("count") ? result["count"] as Number : 0;
        var totalCHO = result.hasKey("cho") ? result["cho"] as Number : 0;
        var totalNa = result.hasKey("na") ? result["na"] as Number : 0;

        if (consumedCount > 0) {
            mRecentAutoConsumeCommitted = true;
            if (consumedCount > 1) {
                System.println(
                    "Committed pending batch auto-consume: " + consumedCount +
                    " items, +" + totalCHO + "g CHO, +" + totalNa + "mg Na"
                );
                logNutritionMetrics("Post batch auto-consume");
            } else {
                System.println(
                    "Committed pending auto-consume: +" + totalCHO +
                    "g CHO, +" + totalNa + "mg Na"
                );
                logNutritionMetrics("Post auto-consume");
            }
        }

        if (!hasPendingAutoConsumeQueue()) {
            mPendingAutoConsumeQueuedAtSec = -9999;
            return;
        }

        // Fail-safe: avoid getting stuck forever if simulator cadence is pathological.
        if ((elapsedSeconds - mPendingAutoConsumeQueuedAtSec) > 60) {
            System.println("Pending auto-consume timeout; clearing queue");
            mPendingAutoConsumeEntries = [] as Array<Dictionary>;
            mPendingAutoConsumeQueuedAtSec = -9999;
        }
    }

    private function consumePendingAutoConsumeQueue() as Dictionary {
        var consumedCount = 0;
        var totalCHO = 0;
        var totalNa = 0;
        var remaining = [] as Array<Dictionary>;

        for (var i = 0; i < mPendingAutoConsumeEntries.size(); i++) {
            var entry = mPendingAutoConsumeEntries[i];
            if (entry == null || !entry.hasKey("id")) {
                System.println("consumePendingAutoConsumeQueue: skipped invalid entry");
                continue;
            }

            var itemId = entry["id"].toString();
            var consumed = mEngine.consumeCurrentDueItemById(itemId);
            if (!consumed) {
                consumed = mEngine.consumeCurrentScheduledItemById(itemId);
            }

            if (!consumed) {
                System.println(
                    "consumePendingAutoConsumeQueue: not consumed yet id=" + itemId +
                    " (t=" + mEngine.getElapsedSeconds() + "s)"
                );
                remaining.add(entry);
                continue;
            }

            consumedCount += 1;
            if (entry.hasKey("cho")) {
                totalCHO += entry["cho"] as Number;
            }
            if (entry.hasKey("na")) {
                totalNa += entry["na"] as Number;
            }
        }

        mPendingAutoConsumeEntries = remaining;

        return {
            "count" => consumedCount,
            "cho" => totalCHO,
            "na" => totalNa
        };
    }

    private function maybeNotifyDueItem(item as NutritionItem) as Void {
        if (mAutoConsumePlannedItems && hasRecentAutoConsumeNotice()) {
            // Keep the current overlay visible for its full slot duration.
            // Without this, a second due item in the same minute can overwrite
            // the first overlay before 5s have elapsed.
            return;
        }

        if (mAutoConsumePlannedItems && hasPendingAutoConsumeQueue()) {
            return;
        }

        var elapsedSeconds = mEngine.getElapsedSeconds();
        var isNewItem = !item.id.equals(mLastAlertItemId);
        var shouldNotify = isNewItem;
        if (!mAutoConsumePlannedItems) {
            shouldNotify = isNewItem || ((elapsedSeconds - mLastAlertAtSec) >= mAlertRepeatSec);
        }

        if (!shouldNotify) {
            return;
        }

        // Stagger same-minute siblings: space alerts ~30s apart so the athlete
        // sees each product individually with its own vibration.
        if (mAutoConsumePlannedItems) {
            var itemBucket = item.scheduledTime - (item.scheduledTime % 60);
            if (itemBucket == mLastAlertMinuteBucket && (elapsedSeconds - mLastAlertAtSec) < mSameMinuteStaggerSec) {
                return;
            }
        }

        System.println(
            "Due notify: " + item.name +
            " (id=" + item.id +
            ", t=" + elapsedSeconds + ")"
        );

        mEngine.markAlertSentForCurrentItem();
        triggerAlert(item);
        // Aviso global: lanzar el popup nativo DataFieldAlert SIEMPRE (también en
        // modo auto-consume). Es la única vía CIQ para que el aviso aparezca
        // sobre la pantalla activa cuando el usuario está mirando otro data
        // field, el mapa o el resumen — caso de uso real del ciclista.
        // El overlay propio del campo sigue actuando como refuerzo al volver.
        var shown = showDueItemAlert(item, null);
        if (mAutoConsumePlannedItems) {
            System.println("Auto-consume: native DataFieldAlert + in-field overlay");
        } else if (!shown) {
            System.println("Native DataField alert unavailable; using AHORA fallback");
        }

        if (mAutoConsumePlannedItems) {
            rememberAutoConsumeNotice(item);
            var consumedSingle = mEngine.consumeCurrentDueItemById(item.id);
            if (!consumedSingle) {
                consumedSingle = mEngine.consumeCurrentScheduledItemById(item.id);
            }
            if (!consumedSingle) {
                consumedSingle = mEngine.forceConsumeCurrentItemById(item.id);
            }
            if (consumedSingle) {
                mRecentAutoConsumeCommitted = true;
                System.println(
                    "Immediate auto-consume: " + item.id +
                    " +" + item.getNutrient("cho") + "g CHO, +" +
                    item.getNutrient("na") + "mg Na"
                );
                logNutritionMetrics("Post auto-consume");
            } else {
                mRecentAutoConsumeCommitted = false;
                var currentAfterAlert = mEngine.getCurrentItem();
                var currentDesc = currentAfterAlert == null ? "<none>" : (currentAfterAlert.id + " state=" + currentAfterAlert.state);
                System.println("Immediate auto-consume failed for item: " + item.id + " current=" + currentDesc);
            }

            mPendingAutoConsumeEntries = [] as Array<Dictionary>;
            mPendingAutoConsumeQueuedAtSec = -9999;
        }

        mLastAlertItemId = item.id;
        mLastAlertAtSec = elapsedSeconds;
        mLastAlertMinuteBucket = item.scheduledTime - (item.scheduledTime % 60);
    }

    private function autoConsumeCurrentDueMinuteBatch(items as Array<NutritionItem> or Null) as Dictionary or Null {
        if (items == null || items.size() == 0) {
            return null;
        }

        var count = 0;
        var totalCHO = 0;
        var totalNa = 0;
        var names = "";
        var entries = [] as Array<Dictionary>;

        for (var i = 0; i < items.size(); i++) {
            var expected = items[i];
            var current = mEngine.getCurrentItem();
            if (current == null) {
                break;
            }

            if (!current.id.equals(expected.id)) {
                System.println(
                    "Batch consume order mismatch: expected=" + expected.id +
                    ", current=" + current.id
                );
            }

            if (current.state != "due") {
                mEngine.ensureCurrentItemDueIfReached();
                current = mEngine.getCurrentItem();
            }

            if (current == null || current.state != "due" || !current.id.equals(expected.id)) {
                System.println("Batch consume skipped item: " + expected.id);
                continue;
            }

            var cho = current.getNutrient("cho");
            var na = current.getNutrient("na");
            var categoryLabel = ProductClassifier.getCategoryLabel(current);
            var icon = ProductIconResolver.loadForItem(current);

            if (names.length() < 42) {
                if (!names.equals("")) {
                    names += " + ";
                }
                names += truncateText(current.name, 10);
            }

            var consumed = mEngine.consumeCurrentDueItemById(current.id);
            if (!consumed) {
                consumed = mEngine.consumeCurrentScheduledItemById(current.id);
            }
            if (!consumed) {
                consumed = mEngine.forceConsumeCurrentItemById(current.id);
            }
            if (!consumed) {
                System.println("Batch consume failed for item: " + current.id);
                continue;
            }

            entries.add({
                "name" => current.name,
                "category" => categoryLabel,
                "cho" => cho,
                "na" => na,
                "icon" => icon
            });

            count += 1;
            totalCHO += cho;
            totalNa += na;
        }

        if (count <= 0) {
            return null;
        }

        return {
            "count" => count,
            "cho" => totalCHO,
            "na" => totalNa,
            "names" => names,
            "entries" => entries
        };
    }

    private function logNutritionMetrics(prefix as String) as Void {
        var elapsedSeconds = mEngine.getElapsedSeconds();
        var choRate = mEngine.getCHORate(elapsedSeconds);
        var naRate = mEngine.getNaRate(elapsedSeconds);

        System.println(
            prefix + ": CHO=" + mEngine.getConsumedCHO() +
            "g, Na=" + mEngine.getConsumedNa() +
            "mg, CHO/h=" + choRate.format("%.0f") +
            ", Na/h=" + naRate.format("%.0f") +
            " (t=" + elapsedSeconds + "s)"
        );
    }

    private function maybeRetryPlanSync() as Void {
        if (mUseFreeMode || mUseQuickDemoPlan || mSyncInProgress) {
            return;
        }

        if (!hasPairingCodeConfigured()) {
            return;
        }

        var elapsedSeconds = mEngine.getElapsedSeconds();

        // Fallback retry: re-sync aggressively when stuck with no real plan.
        if (isUsingFallbackFreePlan()) {
            if ((elapsedSeconds - mLastBackgroundSyncSec) >= mBackgroundSyncIntervalSec) {
                mLastBackgroundSyncSec = elapsedSeconds;
                System.println("Background sync retry (fallback)...");
                attemptSync(true);
            }
            return;
        }

        // Mid-activity refresh: re-sync every 30 min even with a real plan loaded.
        // Picks up plan edits made on the Inner web app during an activity.
        if (hasRealPlanLoaded()) {
            if ((elapsedSeconds - mLastMidActivitySyncSec) >= MID_ACTIVITY_SYNC_INTERVAL_SEC) {
                mLastMidActivitySyncSec = elapsedSeconds;
                System.println("Mid-activity plan refresh (t=" + elapsedSeconds + "s)");
                attemptSync(true);
            }
        }
    }

    private function isUsingFallbackFreePlan() as Boolean {
        var plan = mEngine.getPlan();
        if (plan == null || !plan.hasItems()) {
            return false;
        }
        return !mUseFreeMode && plan.id.equals("free-mode");
    }

    private function hasPairingCodeConfigured() as Boolean {
        var pairingCode = Application.Properties.getValue("pairingCode");
        if (pairingCode == null) {
            return false;
        }

        var text = pairingCode.toString();
        var normalized = "";
        for (var i = 0; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);
            if (ch.equals(" ") || ch.equals("\t") || ch.equals("\n") || ch.equals("\r") || ch.equals("-")) {
                continue;
            }
            normalized += ch;
        }
        return !normalized.equals("");
    }

    private function getBackgroundColor() as Graphics.ColorType {
        // Tema oscuro unificado: los iconos PNG tienen fondo negro propio,
        // así que fundir el fondo del campo con ese tono evita la "caja negra"
        // y mejora el contraste de las métricas en marcha (típico data field
        // Garmin de ciclismo: fondo oscuro + texto claro + acentos por categoría).
        var plan = mEngine.getPlan();
        if (plan == null || !plan.hasItems()) {
            return 0x0B1220;
        }

        if (mEngine.isComplete()) {
            return 0x0E1A1A;
        }

        var currentItem = mEngine.getCurrentItem();
        if (currentItem == null) {
            return 0x0B1220;
        }

        if (currentItem.state == "due") {
            return 0x1A0F00;
        }

        var timeToItem = currentItem.scheduledTime - mEngine.getElapsedSeconds();
        if (timeToItem <= 30) {
            return 0x16100A;
        }

        return 0x0B1220;
    }

    private function drawNoPlan(dc as Graphics.Dc, width as Number, height as Number, textColor as Graphics.ColorType) as Void {
        var message = "Sin Plan";
        var detail = "Vincula tu cuenta en";
        var detail2 = "innerfuelplan.com";
        if (mSyncInProgress) {
            message = "Sincronizando";
            detail = "Descargando plan desde INNER";
            detail2 = "";
        } else if (mSyncAttempted && !mSyncSuccess) {
            message = "Sync pendiente";
            detail = buildSyncHintText();
            detail2 = "";
        } else if (mUseQuickDemoPlan) {
            message = "Demo Rapido";
            detail = "Avisos cada 1 min (sin sync web)";
            detail2 = "";
        } else if (mUseFreeMode) {
            message = "Modo Libre";
            detail = "Recordatorios periodicos activos";
            detail2 = "";
        } else if (!hasPairingCodeConfigured()) {
            detail = "Configura pairing code en";
            detail2 = "Garmin Connect IQ";
        }

        var centerX = width / 2;

        // ── INNER logo (centred, upper area) ────────────────────────────────
        var logo = WatchUi.loadResource(Rez.Drawables.InnerLogo);
        if (logo != null) {
            var logoW = logo.getWidth();
            var logoH = logo.getHeight();
            var logoTargetW = (width * 0.50).toNumber();
            var logoScale = logoTargetW.toFloat() / logoW.toFloat();
            var logoTargetH = (logoH * logoScale).toNumber();
            var logoY = (height * 0.18).toNumber();
            if (dc has :drawScaledBitmap) {
                var logoX = (centerX - logoTargetW / 2).toNumber();
                dc.drawScaledBitmap(logoX, logoY, logoTargetW, logoTargetH, logo);
            } else {
                var logoX = (centerX - logoW / 2).toNumber();
                dc.drawBitmap(logoX, logoY, logo);
            }
        }

        // ── Status message ──────────────────────────────────────────────────
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            height * 0.52,
            Graphics.FONT_MEDIUM,
            message,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Detail line(s) ──────────────────────────────────────────────────
        dc.setColor(0xCBD5E1, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            height * 0.65,
            Graphics.FONT_XTINY,
            truncateText(detail, 30),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
        if (!detail2.equals("")) {
            dc.setColor(0x3B82F6, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                centerX,
                height * 0.73,
                Graphics.FONT_XTINY,
                detail2,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        dc.setColor(0x9CA3AF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            height * 0.91,
            Graphics.FONT_XTINY,
            truncateText(BuildInfo.getBuild(), 30),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawCompleted(dc as Graphics.Dc, width as Number, height as Number, textColor as Graphics.ColorType) as Void {
        var cardX = (width * 0.05).toNumber();
        var cardY = (height * 0.08).toNumber();
        var cardW = (width * 0.90).toNumber();
        var cardH = (height * 0.84).toNumber();

        var completedBg = getBackgroundColor();
        dc.setColor(completedBg, completedBg);
        dc.fillRectangle(cardX, cardY, cardW, cardH);
        dc.setColor(0xCFEAD7, Graphics.COLOR_TRANSPARENT);
        if (dc has :drawRectangle) {
            dc.drawRectangle(cardX, cardY, cardW, cardH);
        }

        dc.setColor(0x1D7A39, Graphics.COLOR_TRANSPARENT);
        drawProgressBar(dc, width, height, 1.0, 0x55C27E);

        dc.drawText(
            width / 2,
            height * 0.19,
            Graphics.FONT_SMALL,
            "PLAN COMPLETADO",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var elapsedSeconds = mEngine.getElapsedSeconds();
        var choRate = mEngine.getCHORate(elapsedSeconds);
        var naRate = mEngine.getNaRate(elapsedSeconds);
        var totals = "CHO " + mEngine.getConsumedCHO() + "g (" + choRate.format("%.0f") + "/h)";
        var states = "OK " + mEngine.getConsumedCount() + "  SKIP " + mEngine.getSkippedCount() + "  MISS " + mEngine.getMissedCount();

        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);

        dc.drawText(
            width / 2,
            height * 0.40,
            Graphics.FONT_XTINY,
            "Resumen de nutricion",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.drawText(
            width / 2,
            height * 0.52,
            Graphics.FONT_XTINY,
            totals,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.drawText(
            width / 2,
            height * 0.74,
            Graphics.FONT_XTINY,
            "Na " + mEngine.getConsumedNa() + "mg (" + naRate.format("%.0f") + "mg/h)",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.86,
            Graphics.FONT_XTINY,
            truncateText(states, 28),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawHUD(dc as Graphics.Dc, width as Number, height as Number, textColor as Graphics.ColorType) as Void {
        var plan = mEngine.getPlan();
        var item = mEngine.getCurrentItem();
        if (plan == null || item == null) {
            return;
        }

        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        drawContentCard(dc, width, height);

        // ── Progress & header ────────────────────────────────────────────────
        var resolvedCount = mEngine.getConsumedCount() + mEngine.getSkippedCount() + mEngine.getMissedCount();
        var progressRatio = plan.getItemCount() > 0
            ? (resolvedCount.toFloat() / plan.getItemCount().toFloat())
            : 0.0;
        if (progressRatio < 0.0) { progressRatio = 0.0; }
        if (progressRatio > 1.0) { progressRatio = 1.0; }

        var itemAccent = getPrimaryAccentColor(item);
        drawProgressBar(dc, width, height, progressRatio, itemAccent);

        // Plan name + item counter on one compact line.
        var headerName = mUseFreeMode ? "MODO LIBRE" : plan.name;
        if (mUseQuickDemoPlan) { headerName = BuildInfo.getBuild(); }
        headerName = truncateText(headerName, 14);
        var headerText = headerName + "  " + mEngine.getCurrentIndexOneBased() + "/" + plan.getItemCount();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.09,
            pickFont(height, "label"),
            headerText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Status chip (sync / mode badge) below header.
        drawStatusChip(dc, width, height, buildTopStatusText(), itemAccent);

        // ── Due state takes over the lower zones ─────────────────────────────
        var countdownText = buildCountdownText(item);
        if (countdownText.equals("AHORA")) {
            drawDueNow(dc, width, height, item, textColor, itemAccent);
            return;
        }

        // ── Item icon + name ─────────────────────────────────────────────────
        drawItemIconSmall(dc, width, height, item);

        var itemName = truncateText(item.name, 18);
        var itemFont = height > 200 ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL;
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.40,
            itemFont,
            itemName,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Metrics ──────────────────────────────────────────────────────────
        if (mShowNutrients) {
            drawPrimaryNutritionRateBlock(dc, width, height, item, textColor);
        }

        // ── Countdown arc ────────────────────────────────────────────────────
        drawBottomCountdown(dc, width, height, countdownText, item, textColor, itemAccent);

        // ── Temperature indicator (only when device provides sensor data) ─────
        if (mAmbientTemp != null) {
            drawTemperatureIndicator(dc, width, height, mAmbientTemp as Float);
        }
    }

    /*
     * Small item icon centered between the header and item name.
     * Skipped on very small fields (<= 130px) where the icon would not be legible.
     */
    private function drawItemIconSmall(dc as Graphics.Dc, width as Number, height as Number, item as NutritionItem) as Void {
        if (height < 140) {
            return;
        }

        var icon = getCachedDueIcon(item);
        if (icon == null) {
            return;
        }

        // Icono grande sin caja (los PNG vienen con fondo oscuro propio que
        // se funde con el fondo dark del campo). Tamaño responsive: ~22% del
        // lado menor de la pantalla; mínimo 48 px (visible), máximo 110 px
        // (legible en marcha) en pantallas grandes tipo Edge 1040.
        var minSide = width < height ? width : height;
        var targetSize = (minSide * 0.22).toNumber();
        if (targetSize < 48) { targetSize = 48; }
        if (targetSize > 110) { targetSize = 110; }

        var x = ((width / 2) - (targetSize / 2)).toNumber();
        var y = (height * 0.22).toNumber();

        try {
            if (dc has :drawScaledBitmap) {
                dc.drawScaledBitmap(x, y, targetSize, targetSize, icon);
            } else {
                var ox = ((width / 2) - (icon.getWidth() / 2)).toNumber();
                dc.drawBitmap(ox, y, icon);
            }
        } catch (ex) {
            // Icon draw failures are non-fatal; fall through silently.
        }
    }

    private function drawPrimaryNutritionRateBlock(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        item as NutritionItem,
        textColor as Graphics.ColorType
    ) as Void {
        var elapsedSeconds = mEngine.getElapsedSeconds();
        var choRate = mEngine.getCHORate(elapsedSeconds);
        var naRate = mEngine.getNaRate(elapsedSeconds);
        var consumedCHO = mEngine.getConsumedCHO();
        var consumedNa = mEngine.getConsumedNa();

        var row1Y = (height * 0.52).toNumber();
        var row2Y = (height * 0.60).toNumber();
        var centerX = width / 2;

        // Compact centered rows: "CHO 118g/h · 59g" and "Na 730mg/h · 365mg"
        var mFont = Graphics.FONT_XTINY;
        var choLine = choRate.format("%.0f") + "g/h  " + consumedCHO + "g";
        var naLine = naRate.format("%.0f") + "mg/h  " + consumedNa + "mg";

        // Rate labels
        dc.setColor(0xCBD5E1, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, row1Y, mFont,
            "CHO " + choLine,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0xCBD5E1, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, row2Y, mFont,
            "Na " + naLine,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

    }


    private function drawBottomCountdown(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        countdownText as String,
        item as NutritionItem,
        textColor as Graphics.ColorType,
        accentColor as Graphics.ColorType
    ) as Void {
        var footerLabel = "PROXIMA TOMA";
        if (mAutoConsumePlannedItems && hasPendingAutoConsumeQueue()) {
            footerLabel = "PROCESANDO...";
        } else if (!mShowCountdown) {
            footerLabel = "CUENTA ATRAS OFF";
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.73,
            pickFont(height, "label"),
            footerLabel,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Circular countdown arc ────────────────────────────────────────────
        var arcR = (height * 0.105).toNumber();
        if (arcR < 22) { arcR = 22; }
        if (arcR > 40) { arcR = 40; }
        var arcThick = (arcR * 0.28).toNumber();
        if (arcThick < 5) { arcThick = 5; }
        if (arcThick > 11) { arcThick = 11; }
        var arcCX = (width / 2).toNumber();
        var arcCY = (height * 0.88).toNumber();

        // Ratio: 1.0 = full interval remaining, 0.0 = due now
        var timeRemaining = item.scheduledTime - mEngine.getElapsedSeconds();
        var intervalSec = getCurrentItemIntervalSec(item);
        var ratio = 0.0f;
        if (intervalSec > 0 && timeRemaining > 0) {
            ratio = timeRemaining.toFloat() / intervalSec.toFloat();
        }
        if (ratio > 1.0f) { ratio = 1.0f; }
        if (ratio < 0.0f) { ratio = 0.0f; }

        // Background track (gray ring, drawn as 359° to avoid start==end ambiguity)
        dc.setColor(0xD7DEE6, Graphics.COLOR_TRANSPARENT);
        for (var t = 0; t < arcThick; t++) {
            dc.drawArc(arcCX, arcCY, arcR - t, Graphics.ARC_CLOCKWISE, 91, 90);
        }

        // Active arc: depletes clockwise from top as time passes
        if (ratio > 0.005f) {
            var sweepDeg = (360.0f * ratio).toNumber();
            dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
            for (var t = 0; t < arcThick; t++) {
                dc.drawArc(arcCX, arcCY, arcR - t, Graphics.ARC_CLOCKWISE, 90, 90 - sweepDeg);
            }
        }

        // Countdown number centered inside arc
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            arcCX,
            arcCY,
            pickFont(height, "countdown"),
            countdownText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function getCurrentItemIntervalSec(item as NutritionItem) as Number {
        var idx = mEngine.getCurrentIndexOneBased(); // 1-based
        if (idx <= 1) {
            // First item: interval from activity start to its scheduled time.
            return item.scheduledTime > 0 ? item.scheduledTime : 900;
        }
        var plan = mEngine.getPlan();
        if (plan == null) { return 900; }
        var prevItem = plan.getItemAt(idx - 2); // 0-based index of previous item
        if (prevItem == null) { return 900; }
        var interval = item.scheduledTime - prevItem.scheduledTime;
        return interval > 60 ? interval : 900;
    }

    private function buildCountdownText(item as NutritionItem) as String {
        var timeToItem = item.scheduledTime - mEngine.getElapsedSeconds();

        if (mAutoConsumePlannedItems && hasPendingAutoConsumeQueue()) {
            return "ESPERA";
        }

        if (item.state == "due" || (timeToItem <= 0 && !item.isResolved())) {
            return "AHORA";
        }

        if (!mShowCountdown) {
            return "PROX";
        }

        return formatSeconds(timeToItem);
    }

    private function formatSeconds(totalSeconds as Number) as String {
        var safeSeconds = totalSeconds;
        if (safeSeconds < 0) {
            safeSeconds = 0;
        }
        var minutes = safeSeconds / 60;
        var seconds = safeSeconds % 60;
        return minutes.format("%d") + ":" + seconds.format("%02d");
    }

    private function drawDueNow(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        item as NutritionItem,
        textColor as Graphics.ColorType,
        accentColor as Graphics.ColorType
    ) as Void {
        // ── Large product icon (centred between status chip and item name) ───
        var icon = getCachedDueIcon(item);
        // Zone starts below the status chip area, ends above item name.
        var zoneTop = (height * 0.18).toNumber();
        var zoneBot = (height * 0.46).toNumber();
        var zoneH = zoneBot - zoneTop;
        var targetSize = (zoneH * 0.85).toNumber();
        if (targetSize < 64) { targetSize = 64; }
        var iconY = (zoneTop + (zoneH - targetSize) / 2).toNumber();
        if (iconY < zoneTop) { iconY = zoneTop; }

        if (icon != null) {
            var x = ((width / 2) - (targetSize / 2)).toNumber();
            try {
                if (dc has :drawScaledBitmap) {
                    dc.drawScaledBitmap(x, iconY, targetSize, targetSize, icon);
                } else {
                    var ox = ((width / 2) - (icon.getWidth() / 2)).toNumber();
                    dc.drawBitmap(ox, iconY, icon);
                }
            } catch (ex) {
                // Draw category label fallback if icon fails.
                dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(width / 2, iconY + targetSize / 2, Graphics.FONT_SMALL,
                    ProductClassifier.getCategoryLabel(item),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        } else {
            // No icon — show category label in a tinted box.
            var boxX = ((width / 2) - (targetSize / 2)).toNumber();
            var fallbackBg = getBackgroundColor();
            dc.setColor(fallbackBg, fallbackBg);
            dc.fillRectangle(boxX, iconY, targetSize, targetSize);
            dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(width / 2, iconY + targetSize / 2, Graphics.FONT_XTINY,
                ProductClassifier.getCategoryLabel(item),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // ── Item name ─────────────────────────────────────────────────────────
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.52,
            Graphics.FONT_SMALL,
            truncateText(item.name, 18),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Nutrient delta (category color) ───────────────────────────────────
        var cho = item.getNutrient("cho");
        var na  = item.getNutrient("na");
        var nutriLine = "";
        if (cho > 0) { nutriLine = "+" + cho + "g CHO"; }
        if (na > 0) {
            if (!nutriLine.equals("")) { nutriLine += "  "; }
            nutriLine += "+" + na + "mg Na";
        }
        if (!nutriLine.equals("")) {
            dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                width / 2,
                height * 0.58,
                Graphics.FONT_XTINY,
                nutriLine,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        // ── "TOMAR AHORA" full-width action strip ─────────────────────────────
        var stripY = (height * 0.66).toNumber();
        var stripH = (height * 0.13).toNumber();
        if (stripH < 18) { stripH = 18; }
        dc.setColor(accentColor, accentColor);
        dc.fillRectangle((width * 0.04).toNumber(), stripY, (width * 0.92).toNumber(), stripH);
        dc.setColor(0x1A202C, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            stripY + stripH / 2,
            Graphics.FONT_SMALL,
            "TOMAR AHORA",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Rate metrics row (CHO/h · Na/h · ml/h, large, high-contrast) ─────
        // Tasas grandes legibles en marcha; etiquetas pequeñas. ml/h se llena
        // sólo cuando el item es de tipo bebida (el backend envía nutrients.ml).
        // Layout responsive: en pantallas circulares (relojes) se aprietan las
        // columnas hacia el centro y se suben para no caer fuera del círculo.
        var elapsedSeconds = mEngine.getElapsedSeconds();
        var choRate = mEngine.getCHORate(elapsedSeconds);
        var naRate = mEngine.getNaRate(elapsedSeconds);
        var mlRate = mEngine.getMlRate(elapsedSeconds);
        var settings = System.getDeviceSettings();
        var isRound = settings != null && settings.screenShape == System.SCREEN_SHAPE_ROUND;
        var metricY = isRound ? (height * 0.80).toNumber() : (height * 0.87).toNumber();
        var labelY = isRound ? (height * 0.88).toNumber() : (height * 0.96).toNumber();
        var metricFont = height > 250 ? Graphics.FONT_LARGE : Graphics.FONT_MEDIUM;
        var x1 = isRound ? (width * 0.25).toNumber() : (width / 6).toNumber();
        var x2 = (width / 2).toNumber();
        var x3 = isRound ? (width * 0.75).toNumber() : ((width * 5) / 6).toNumber();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x1, metricY, metricFont, choRate.format("%.0f"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x2, metricY, metricFont, naRate.format("%.0f"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x3, metricY, metricFont, mlRate.format("%.0f"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(0xCBD5E1, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x1, labelY, Graphics.FONT_XTINY, "g CHO/h",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x2, labelY, Graphics.FONT_XTINY, "mg Na/h",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x3, labelY, Graphics.FONT_XTINY, "ml/h",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function getCachedDueIcon(item as NutritionItem) {
        if (mDueIconCache != null && mDueIconCacheItemId.equals(item.id)) {
            return mDueIconCache;
        }

        mDueIconCacheItemId = item.id;
        mDueIconCache = ProductIconResolver.loadForItem(item);
        return mDueIconCache;
    }

    private function getCategoryColorForItem(item as NutritionItem) as Graphics.ColorType {
        var label = ProductClassifier.getCategoryLabel(item);
        var color = ProductClassifier.getCategoryColor(label);
        // Fall back to black (dark field) rather than white for unknown items.
        return color.equals(Graphics.COLOR_WHITE) ? Graphics.COLOR_BLACK : color;
    }

    private function rememberAutoConsumeNotice(item as NutritionItem) as Void {
        mRecentAutoConsumeItemName = item.name;
        mRecentAutoConsumeItemCategory = ProductClassifier.getCategoryLabel(item);
        mRecentAutoConsumeCHO = item.getNutrient("cho");
        mRecentAutoConsumeNa = item.getNutrient("na");
        mRecentAutoConsumeBatchCount = 1;
        mRecentAutoConsumeBatchNames = "";
        mRecentAutoConsumeIcon = ProductIconResolver.loadForItem(item);
        mRecentAutoConsumeSequence = [
            {
                "id" => item.id,
                "name" => item.name,
                "category" => mRecentAutoConsumeItemCategory,
                "cho" => mRecentAutoConsumeCHO,
                "na" => mRecentAutoConsumeNa,
                "icon" => mRecentAutoConsumeIcon
            }
        ] as Array<Dictionary>;
        mRecentAutoConsumeCommitted = false;
        mRecentAutoConsumeAtSec = mEngine.getElapsedSeconds();
        // Anchor visible duration at first overlay render, not at alert trigger time.
        // This prevents the first product in a batch from losing time due to compute cadence.
        mRecentAutoConsumeAtMs = -1;
    }

    private function rememberAutoConsumeBatchNotice(firstItem as NutritionItem, batchSummary as Dictionary) as Void {
        if (firstItem == null || batchSummary == null) {
            return;
        }

        mRecentAutoConsumeItemName = firstItem.name;
        mRecentAutoConsumeItemCategory = ProductClassifier.getCategoryLabel(firstItem);
        mRecentAutoConsumeCHO = batchSummary.hasKey("cho") ? batchSummary["cho"] as Number : firstItem.getNutrient("cho");
        mRecentAutoConsumeNa = batchSummary.hasKey("na") ? batchSummary["na"] as Number : firstItem.getNutrient("na");
        mRecentAutoConsumeBatchCount = batchSummary.hasKey("count") ? batchSummary["count"] as Number : 1;
        mRecentAutoConsumeBatchNames = batchSummary.hasKey("names") ? batchSummary["names"].toString() : "";
        mRecentAutoConsumeIcon = ProductIconResolver.loadForItem(firstItem);
        mRecentAutoConsumeSequence = [] as Array<Dictionary>;
        if (batchSummary.hasKey("entries")) {
            var summaryEntries = batchSummary["entries"];
            if (summaryEntries instanceof Array) {
                var rawEntries = summaryEntries as Array;
                for (var i = 0; i < rawEntries.size(); i++) {
                    var entry = rawEntries[i];
                    if (entry == null) {
                        continue;
                    }
                    try {
                        mRecentAutoConsumeSequence.add(entry as Dictionary);
                    } catch (ex) {
                        System.println("rememberAutoConsumeBatchNotice entry cast error: " + ex.getErrorMessage());
                    }
                }
            }
        }
        if (mRecentAutoConsumeSequence.size() == 0) {
            mRecentAutoConsumeSequence.add({
                "id" => firstItem.id,
                "name" => firstItem.name,
                "category" => mRecentAutoConsumeItemCategory,
                "cho" => mRecentAutoConsumeCHO,
                "na" => mRecentAutoConsumeNa,
                "icon" => mRecentAutoConsumeIcon
            });
        }
        mRecentAutoConsumeCommitted = false;
        mRecentAutoConsumeAtSec = mEngine.getElapsedSeconds();
        // Anchor visible duration at first overlay render.
        mRecentAutoConsumeAtMs = -1;
    }

    private function hasRecentAutoConsumeNotice() as Boolean {
        if (mRecentAutoConsumeAtSec < 0) {
            return false;
        }

        var ageMs = getRecentAutoConsumeAgeMs();
        if (ageMs < 0) {
            return false;
        }
        var duration = mRecentAutoConsumeNoticeSec;
        if (mRecentAutoConsumeSequence != null && mRecentAutoConsumeSequence.size() > 1) {
            duration = mRecentAutoConsumeSequence.size() * mRecentAutoConsumeSequenceStepSec;
        }
        var durationMs = duration * 1000;
        return ageMs >= 0 && ageMs < durationMs;
    }

    private function drawRecentAutoConsumeOverlay(dc as Graphics.Dc, width as Number, height as Number) as Void {
        var overlayEntryName = mRecentAutoConsumeItemName;
        var overlayEntryCategory = mRecentAutoConsumeItemCategory;
        var overlayEntryCHO = mRecentAutoConsumeCHO;
        var overlayEntryNa = mRecentAutoConsumeNa;
        var overlayEntryIcon = mRecentAutoConsumeIcon;
        var overlayStep = 1;
        var overlayTotal = mRecentAutoConsumeBatchCount;
        var overlayAgeMs = getRecentAutoConsumeAgeMs();
        if (overlayAgeMs < 0) {
            overlayAgeMs = 0;
        }
        var overlayStepElapsedMs = overlayAgeMs;
        var overlayStepDurationMs = mRecentAutoConsumeNoticeSec * 1000;

        if (mRecentAutoConsumeSequence != null && mRecentAutoConsumeSequence.size() > 0) {
            var seqAgeMs = overlayAgeMs;
            var seqIndex = 0;
            if (mRecentAutoConsumeSequence.size() > 1 && mRecentAutoConsumeSequenceStepSec > 0) {
                var stepMs = mRecentAutoConsumeSequenceStepSec * 1000;
                if (stepMs <= 0) {
                    stepMs = 5000;
                }
                overlayStepDurationMs = stepMs;
                seqIndex = ((seqAgeMs - (seqAgeMs % stepMs)) / stepMs).toNumber();
                if (seqIndex < 0) {
                    seqIndex = 0;
                }
                if (seqIndex >= mRecentAutoConsumeSequence.size()) {
                    seqIndex = mRecentAutoConsumeSequence.size() - 1;
                }
                overlayStepElapsedMs = seqAgeMs - (seqIndex * stepMs);
                if (overlayStepElapsedMs < 0) {
                    overlayStepElapsedMs = 0;
                }
            }

            var activeEntry = mRecentAutoConsumeSequence[seqIndex];
            if (activeEntry != null) {
                overlayStep = seqIndex + 1;
                overlayTotal = mRecentAutoConsumeSequence.size();
                if (activeEntry.hasKey("name")) {
                    overlayEntryName = activeEntry["name"].toString();
                }
                if (activeEntry.hasKey("category")) {
                    overlayEntryCategory = activeEntry["category"].toString();
                }
                if (activeEntry.hasKey("cho")) {
                    overlayEntryCHO = activeEntry["cho"] as Number;
                }
                if (activeEntry.hasKey("na")) {
                    overlayEntryNa = activeEntry["na"] as Number;
                }
                if (activeEntry.hasKey("icon")) {
                    overlayEntryIcon = activeEntry["icon"];
                }
            }
        }

        var cardW = (width * 0.86).toNumber();
        var cardH = (height * 0.66).toNumber();
        var cardX = ((width - cardW) / 2).toNumber();
        var cardY = (height * 0.12).toNumber();
        var contentBlockOffsetY = (height * 0.045).toNumber();
        var mediaBlockExtraOffsetY = (height * 0.055).toNumber();

        // Card background (device default).
        var cardBg = getBackgroundColor();
        dc.setColor(cardBg, cardBg);
        dc.fillRectangle(cardX, cardY, cardW, cardH);

        // ── Green "REGISTRADO" header strip ───────────────────────────────────
        var headerStripH = (cardH * 0.10).toNumber();
        if (headerStripH < 12) { headerStripH = 12; }
        dc.setColor(0x22C55E, 0x22C55E);
        dc.fillRectangle(cardX, cardY, cardW, headerStripH);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var registradoLabel = overlayTotal > 1
            ? ("REGISTRADO  " + overlayStep + "/" + overlayTotal)
            : "REGISTRADO";
        dc.drawText(
            width / 2,
            cardY + headerStripH / 2,
            Graphics.FONT_XTINY,
            registradoLabel,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Item name ─────────────────────────────────────────────────────────
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            cardY + (cardH * 0.15) + contentBlockOffsetY,
            Graphics.FONT_SMALL,
            truncateText(overlayEntryName, 18),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Product icon ──────────────────────────────────────────────────────
        drawRecentAutoConsumeOverlayIcon(
            dc,
            (width / 2).toNumber(),
            (cardY + (cardH * 0.22) + contentBlockOffsetY + mediaBlockExtraOffsetY).toNumber(),
            cardH,
            overlayEntryIcon,
            overlayEntryCategory
        );

        // ── Category + nutrient delta ─────────────────────────────────────────
        var catColor = ProductClassifier.getCategoryColor(overlayEntryCategory);
        dc.setColor(catColor.equals(Graphics.COLOR_WHITE) ? Graphics.COLOR_BLACK : catColor,
            Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            cardY + (cardH * 0.72) + contentBlockOffsetY + mediaBlockExtraOffsetY,
            Graphics.FONT_XTINY,
            overlayTotal > 1 ? ("TOMA " + overlayStep + "/" + overlayTotal) : overlayEntryCategory,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(0x374151, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            cardY + (cardH * 0.82) + contentBlockOffsetY + mediaBlockExtraOffsetY,
            Graphics.FONT_XTINY,
            "+" + overlayEntryCHO + "g CHO  +" + overlayEntryNa + "mg Na",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );


        if (mDebugOverlayTiming) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cardX + 6,
                cardY + 6,
                Graphics.FONT_XTINY,
                "DBG " + overlayStep + "/" + overlayTotal +
                " " + overlayStepElapsedMs + "/" + overlayStepDurationMs + "ms",
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    private function drawRecentAutoConsumeOverlayIcon(
        dc as Graphics.Dc,
        centerX as Number,
        topY as Number,
        cardH as Number,
        icon,
        categoryLabel as String
    ) as Void {
        var boxSize = (cardH * 0.52).toNumber();
        if (boxSize < 80) {
            boxSize = 80;
        }

        var boxY = topY.toNumber();


        if (icon == null) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                centerX,
                boxY + (boxSize / 2),
                Graphics.FONT_XTINY,
                truncateText(categoryLabel, 9),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        var targetSize = boxSize - 2;
        if (dc has :drawScaledBitmap) {
            var xScaled = (centerX - (targetSize / 2)).toNumber();
            var yScaled = (boxY + ((boxSize - targetSize) / 2)).toNumber();
            dc.drawScaledBitmap(xScaled, yScaled, targetSize, targetSize, icon);
        } else {
            var iconWidth = icon.getWidth();
            var iconHeight = icon.getHeight();
            var x = (centerX - (iconWidth / 2)).toNumber();
            var y = (boxY + ((boxSize - iconHeight) / 2)).toNumber();
            dc.drawBitmap(x, y, icon);
        }
    }

    private function drawContentCard(dc as Graphics.Dc, width as Number, height as Number) as Void {
        // Reserved hook: the content card background is currently drawn elsewhere.
    }

    private function drawProgressBar(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        ratio as Float,
        accentColor as Graphics.ColorType
    ) as Void {
        var barW = (width * 0.92).toNumber();
        var barH = 5;
        var barX = ((width - barW) / 2).toNumber();
        var barY = (height * 0.03).toNumber();

        var safeRatio = ratio;
        if (safeRatio < 0.0) {
            safeRatio = 0.0;
        }
        if (safeRatio > 1.0) {
            safeRatio = 1.0;
        }

        dc.setColor(0xE3E8EE, 0xE3E8EE);
        dc.fillRectangle(barX, barY, barW, barH);

        var fillW = (barW * safeRatio).toNumber();
        if (fillW < 0) {
            fillW = 0;
        }
        if (fillW > 0) {
            dc.setColor(accentColor, accentColor);
            dc.fillRectangle(barX, barY, fillW, barH);
        }
    }

    private function drawStatusChip(dc as Graphics.Dc, width as Number, height as Number, text as String, accentColor as Graphics.ColorType) as Void {
        if (text == null || text.equals("")) {
            return;
        }

        var chipText = truncateText(text, 22);
        // Use dc.getTextDimensions for pixel-accurate chip width when available.
        var chipW = (chipText.length() * 7) + 16;
        if (dc has :getTextDimensions) {
            var dims = dc.getTextDimensions(chipText, Graphics.FONT_XTINY);
            chipW = (dims[0]).toNumber() + 16;
        }
        var maxChipW = (width * 0.80).toNumber();
        if (chipW > maxChipW) {
            chipW = maxChipW;
        }

        var chipFont = pickFont(height, "label");
        var chipH = 15;
        var chipY = (height * 0.13).toNumber();

        dc.drawText(
            width / 2,
            chipY + (chipH / 2),
            chipFont,
            chipText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // ── Adaptive font helpers ────────────────────────────────────────────────
    // Returns a font scaled to the field height.
    //   "label"     — small labels (CHO/h, PROXIMA TOMA, plan header, chip)
    //   "value"     — metric values (item name uses FONT_SMALL/MEDIUM baseline)
    //   "countdown" — large numeric countdown
    private function pickFont(height as Number, kind as String) as Graphics.FontType {
        if (kind.equals("countdown")) {
            return height > 200 ? Graphics.FONT_NUMBER_MEDIUM : Graphics.FONT_NUMBER_MILD;
        }
        if (kind.equals("value")) {
            if (height > 300) { return Graphics.FONT_MEDIUM; }
            if (height > 160) { return Graphics.FONT_SMALL; }
            return Graphics.FONT_TINY;
        }
        // "label" default
        if (height > 300) { return Graphics.FONT_SMALL; }
        if (height > 160) { return Graphics.FONT_TINY; }
        return Graphics.FONT_XTINY;
    }

    /*
     * Draws ambient temperature with a risk-color at the top-right of the HUD.
     * Only called when the device actually provides ambientTemperature data.
     *
     * Risk scale:
     *   < 15°C  → blue   (cold)
     *   15-22°C → green  (optimal)
     *   22-28°C → yellow (moderate)
     *   28-35°C → orange (high)
     *   ≥ 35°C  → red    (critical)
     */
    private function drawTemperatureIndicator(dc as Graphics.Dc, width as Number, height as Number, temp as Float) as Void {
        var tempInt = temp.toNumber();
        var tempText = tempInt + "C";
        var riskColor = getTemperatureRiskColor(temp);
        dc.setColor(riskColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width - 4,
            height * 0.09,
            Graphics.FONT_XTINY,
            tempText,
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function getTemperatureRiskColor(temp as Float) as Graphics.ColorType {
        if (temp < 15.0f) { return 0x66CCFF; }  // blue  – cold
        if (temp < 22.0f) { return 0x22C55E; }  // green – optimal
        if (temp < 28.0f) { return 0xFFD166; }  // yellow – moderate
        if (temp < 35.0f) { return 0xF97316; }  // orange – high
        return 0xEF4444;                         // red    – critical
    }

    private function buildTopStatusText() as String {
        if (mUseQuickDemoPlan) {
            return "";
        }

        if (mUseFreeMode) {
            return "MODO LIBRE";
        }

        if (isUsingFallbackFreePlan()) {
            return buildSyncHintText();
        }

        if (mSyncInProgress) {
            return "SYNC WEB...";
        }

        if (!mSyncAttempted && hasPairingCodeConfigured()) {
            return "SYNC WEB...";
        }

        if (mSyncAttempted && !mSyncSuccess && hasPairingCodeConfigured()) {
            return "SYNC PENDIENTE";
        }

        if (mSyncSuccess && mAutoConsumePlannedItems) {
            return "";
        }

        if (mAutoConsumePlannedItems) {
            return "PLAN LOCAL";
        }

        return "ALERTA INFORMATIVA";
    }

    private function getPrimaryAccentColor(item as NutritionItem or Null) as Graphics.ColorType {
        if (item == null) {
            return 0x5B8DEF;
        }

        if (item.state == "due") {
            return getCategoryColorForItem(item);
        }

        var timeToItem = item.scheduledTime - mEngine.getElapsedSeconds();
        if (timeToItem <= 30) {
            return 0xF4A261;
        }

        return 0x5B8DEF;
    }

    private function truncateText(text as String or Null, maxLen as Number) as String {
        if (text == null) {
            return "";
        }

        if (text.length() <= maxLen) {
            return text;
        }

        if (maxLen <= 2) {
            return "..";
        }

        return text.substring(0, maxLen - 2) + "..";
    }

    private function resetAlertTracking() as Void {
        mLastAlertItemId = "";
        mLastAlertAtSec = -9999;
        mLastAlertMinuteBucket = -1;
        mDueIconCacheItemId = "";
        mDueIconCache = null;
        mLastBackgroundSyncSec = -9999;
        mRecentAutoConsumeItemName = "";
        mRecentAutoConsumeItemCategory = "";
        mRecentAutoConsumeCHO = 0;
        mRecentAutoConsumeNa = 0;
        mRecentAutoConsumeAtSec = -9999;
        mRecentAutoConsumeAtMs = -1;
        mRecentAutoConsumeBatchCount = 1;
        mRecentAutoConsumeBatchNames = "";
        mRecentAutoConsumeIcon = null;
        mRecentAutoConsumeSequence = [] as Array<Dictionary>;
        mRecentAutoConsumeCommitted = false;
        mPendingAutoConsumeEntries = [] as Array<Dictionary>;
        mPendingAutoConsumeQueuedAtSec = -9999;
    }

    private function getSystemTimerMsSafe() as Number {
        try {
            if (System has :getTimer) {
                return System.getTimer();
            }
        } catch (ex) {
            // Try Time.now() fallback below.
        }

        try {
            if (Time has :now) {
                var nowMoment = Time.now();
                if (nowMoment != null && nowMoment has :value) {
                    return nowMoment.value();
                }
            }
        } catch (ex2) {
            // Fall back to activity elapsed time based timing.
        }
        return -1;
    }

    private function getRecentAutoConsumeAgeMs() as Number {
        var nowMs = getSystemTimerMsSafe();
        if (nowMs >= 0) {
            if (mRecentAutoConsumeAtMs < 0) {
                mRecentAutoConsumeAtMs = nowMs;
                // Also anchor second-based fallback at first visible frame to avoid
                // shortening the first batch item when only coarse elapsedTime exists.
                mRecentAutoConsumeAtSec = mEngine.getElapsedSeconds();
                return 0;
            }
            if (nowMs >= mRecentAutoConsumeAtMs) {
                return nowMs - mRecentAutoConsumeAtMs;
            }
            return 0;
        }

        if (mRecentAutoConsumeAtSec < 0) {
            return -1;
        }

        var ageSec = mEngine.getElapsedSeconds() - mRecentAutoConsumeAtSec;
        if (ageSec < 0) {
            return -1;
        }
        return ageSec * 1000;
    }

    private function buildSyncHintText() as String {
        if (mSyncInProgress) {
            return "SYNC WEB...";
        }

        if (!hasPairingCodeConfigured()) {
            return "CONFIGURA CODIGO";
        }

        if (mSyncErrorMessage != null && !mSyncErrorMessage.equals("")) {
            return "SYNC PENDIENTE";
        }

        return "ESPERANDO PLAN WEB";
    }
}
