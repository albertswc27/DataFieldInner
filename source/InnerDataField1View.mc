import Toybox.Activity;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
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

    // Alert retry/fallback state for due items.
    hidden var mLastAlertItemId as String = "";
    hidden var mLastAlertAtSec as Number = -9999;
    hidden var mAlertRepeatSec as Number = 8;
    hidden var mDueIconCacheItemId as String = "";
    hidden var mDueIconCache;
    hidden var mLastSettingsVersion as Number = -1;

    function initialize() {
        DataField.initialize();

        mEngine = new NutritionSessionEngine();
        loadSettings();
        if (!loadPlanFromSyncCache()) {
            loadPlanFromProperties();
        }
        if (!mUseFreeMode) {
            attemptSync(false);
        } else {
            mSyncAttempted = true;
            mSyncSuccess = true;
        }
        mLastSettingsVersion = readSettingsVersion();

        System.println("INNER DataField initialized");
    }

    function onLayout(dc as Graphics.Dc) as Void {
        // Dynamic layout.
    }

    function compute(info as Activity.Info) as Void {
        if (info != null && info has :elapsedTime && info.elapsedTime != null) {
            var elapsedSeconds = (info.elapsedTime / 1000).toNumber();
            mEngine.updateElapsedSeconds(elapsedSeconds);
        }
        maybeRefreshFromSettings();

        // DataField alerts are informational and can be disabled by user/device.
        // Retry while item is due and keep the on-field "AHORA" fallback visible.
        var currentItem = mEngine.getCurrentItem();
        if (currentItem != null && currentItem.state == "due") {
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
    }

    function onTimerStart() as Void {
        // Reload in case settings/plan changed while activity was not running.
        loadSettings();
        if (!loadPlanFromSyncCache()) {
            loadPlanFromProperties();
        }
        resetAlertTracking();
        mLastSettingsVersion = readSettingsVersion();
        if (!mUseFreeMode) {
            // Try to refresh from web at activity start (pairing code required).
            attemptSync(true);
        }
    }

    function onTimerStop() as Void {
        // No-op; state stays available for post-activity review.
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var plan = mEngine.getPlan();

        var bgColor = getBackgroundColor();
        dc.setColor(bgColor, bgColor);
        dc.fillRectangle(0, 0, width, height);

        var textColor = Graphics.COLOR_BLACK;
        if (plan == null || !plan.hasItems()) {
            drawNoPlan(dc, width, height, textColor);
            return;
        }

        if (mEngine.isComplete()) {
            drawCompleted(dc, width, height, textColor);
            return;
        }

        drawHUD(dc, width, height, textColor);
    }

    private function attemptSync(force as Boolean) as Void {
        if (mUseFreeMode) {
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
            fallbackToFreeModeIfNoPlan("No pairing code");
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

        mSyncAttempted = false;
        mSyncSuccess = false;
        mSyncErrorMessage = "";

        loadSettings();
        loadPlanFromProperties();
        resetAlertTracking();

        if (!mUseFreeMode) {
            attemptSync(true);
        } else {
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

        try {
            if (mUseFreeMode) {
                plan = FreeModePlanFactory.build(
                    mFreeIntervalSec,
                    mFreeCHO,
                    mFreeNa,
                    mFreeItemName,
                    mFreeMaxDurationMin * 60
                );
            } else {
                plan = SyncService.getInstance().loadPersistedSelectedPlan();

                // Fast path: use pre-selected single plan JSON first.
                if (plan == null) {
                    var planJson = Application.Properties.getValue("nutritionPlan");
                    if (planJson != null && planJson instanceof String && !planJson.equals("")) {
                        var planStr = planJson as String;
                        if (planStr.length() > 10 && planStr.length() <= 4000) {
                            plan = NutritionPlanParser.parse(planStr);
                        } else if (planStr.length() > 4000) {
                            System.println("Skip nutritionPlan parse (payload too large)");
                        }
                    }
                }

                // Fallback: parse plans envelope only if needed and within safe size.
                if (plan == null) {
                    var plansJson = Application.Properties.getValue("nutritionPlans");
                    if (plansJson != null && plansJson instanceof String && !plansJson.equals("")) {
                        var plansStr = plansJson as String;
                        if (plansStr.length() > 10 && plansStr.length() <= 4000) {
                            var parsedPlans = NutritionPlanParser.parsePlans(plansStr);
                            plan = selectPlan(parsedPlans, mSelectedPlanId);
                        } else if (plansStr.length() > 4000) {
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
        if (mUseFreeMode) {
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

        mEngine.setToleranceSec(mToleranceSec);
        mEngine.setAutoConsumePlannedItems(mAutoConsumePlannedItems);
    }

    private function triggerAlert(item as NutritionItem) as Void {
        if (mVibrationEnabled) {
            AlertHelper.triggerVibration(item);
        }
        if (mSoundEnabled) {
            AlertHelper.triggerSound();
        }
    }

    private function showDueItemAlert(item as NutritionItem) as Boolean {
        if (!(WatchUi.DataField has :showAlert)) {
            return false;
        }

        try {
            WatchUi.DataField.showAlert(new NutritionDataFieldAlert(self, item));
            return true;
        } catch (ex) {
            System.println("showAlert failed: " + ex.getErrorMessage());
            return false;
        }
    }

    private function maybeNotifyDueItem(item as NutritionItem) as Void {
        var elapsedSeconds = mEngine.getElapsedSeconds();
        var isNewItem = !item.id.equals(mLastAlertItemId);
        var shouldNotify = isNewItem || ((elapsedSeconds - mLastAlertAtSec) >= mAlertRepeatSec);

        if (!shouldNotify) {
            return;
        }

        triggerAlert(item);
        var shown = showDueItemAlert(item);
        if (!shown) {
            System.println("Native DataField alert unavailable; using AHORA fallback");
        }

        mLastAlertItemId = item.id;
        mLastAlertAtSec = elapsedSeconds;
    }

    private function maybeRetryPlanSync() as Void {
        if (mUseFreeMode || mSyncInProgress) {
            return;
        }

        if (!hasPairingCodeConfigured()) {
            return;
        }

        if (!isUsingFallbackFreePlan()) {
            return;
        }

        var elapsedSeconds = mEngine.getElapsedSeconds();
        if ((elapsedSeconds - mLastBackgroundSyncSec) < mBackgroundSyncIntervalSec) {
            return;
        }

        mLastBackgroundSyncSec = elapsedSeconds;
        System.println("Background sync retry...");
        attemptSync(true);
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
        var plan = mEngine.getPlan();
        if (plan == null || !plan.hasItems()) {
            return Graphics.COLOR_WHITE;
        }

        if (mEngine.isComplete()) {
            return Graphics.COLOR_GREEN;
        }

        var currentItem = mEngine.getCurrentItem();
        if (currentItem == null) {
            return Graphics.COLOR_WHITE;
        }

        if (currentItem.state == "due") {
            return Graphics.COLOR_YELLOW;
        }

        var timeToItem = currentItem.scheduledTime - mEngine.getElapsedSeconds();
        if (timeToItem <= 30) {
            return Graphics.COLOR_ORANGE;
        }

        return Graphics.COLOR_WHITE;
    }

    private function drawNoPlan(dc as Graphics.Dc, width as Number, height as Number, textColor as Graphics.ColorType) as Void {
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);

        var message = "Sin Plan";
        if (mSyncInProgress) {
            message = "Sincronizando";
        } else if (mSyncAttempted && !mSyncSuccess) {
            message = "Sync Error";
        } else if (mUseFreeMode) {
            message = "Modo Libre";
        }

        dc.drawText(
            width / 2,
            height / 2,
            Graphics.FONT_MEDIUM,
            message,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawCompleted(dc as Graphics.Dc, width as Number, height as Number, textColor as Graphics.ColorType) as Void {
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);

        dc.drawText(
            width / 2,
            height * 0.24,
            Graphics.FONT_SMALL,
            "COMPLETADO",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var elapsedSeconds = mEngine.getElapsedSeconds();
        var choRate = mEngine.getCHORate(elapsedSeconds);
        var naRate = mEngine.getNaRate(elapsedSeconds);
        var totals = "CHO " + mEngine.getConsumedCHO() + "g (" + choRate.format("%.0f") + "g/h)";
        var states = "OK " + mEngine.getConsumedCount() + "  SKIP " + mEngine.getSkippedCount() + "  MISS " + mEngine.getMissedCount();

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

        dc.drawText(
            width / 2,
            height * 0.86,
            Graphics.FONT_XTINY,
            states,
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

        var headerName = mUseFreeMode ? "MODO LIBRE" : plan.name;
        if (headerName.length() > 14) {
            headerName = headerName.substring(0, 12) + "..";
        }

        var progress = mEngine.getCurrentIndexOneBased() + "/" + plan.getItemCount();
        var headerText = headerName + " [" + progress + "]";

        dc.drawText(
            width / 2,
            height * 0.12,
            Graphics.FONT_XTINY,
            headerText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        if (isUsingFallbackFreePlan()) {
            var syncHint = buildSyncHintText();
            dc.drawText(
                width / 2,
                height * 0.20,
                Graphics.FONT_XTINY,
                syncHint,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        var itemName = item.name;
        if (itemName.length() > 18) {
            itemName = itemName.substring(0, 16) + "..";
        }
        dc.drawText(
            width / 2,
            height * 0.35,
            Graphics.FONT_SMALL,
            itemName,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var countdownText = buildCountdownText(item);
        if (countdownText.equals("AHORA")) {
            drawDueNow(dc, width, height, item, textColor);
        } else {
            dc.drawText(
                width / 2,
                height * 0.58,
                Graphics.FONT_NUMBER_MILD,
                countdownText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        var footerText;
        var footerText2 = "";
        if (mShowNutrients) {
            var elapsedSeconds = mEngine.getElapsedSeconds();
            var choRate = mEngine.getCHORate(elapsedSeconds);
            var naRate = mEngine.getNaRate(elapsedSeconds);

            footerText = "CHO " + mEngine.getConsumedCHO() + "g (" + choRate.format("%.0f") + "g/h)";
            footerText2 = "Na " + mEngine.getConsumedNa() + "mg (" + naRate.format("%.0f") + "mg/h)";
        } else if (mUseFreeMode) {
            footerText = "INT " + formatSeconds(mFreeIntervalSec) + "  MISS " + mEngine.getMissedCount();
        } else {
            footerText = "MISS " + mEngine.getMissedCount() + "  TOL " + mToleranceSec + "s";
        }

        dc.drawText(
            width / 2,
            height * 0.85,
            Graphics.FONT_XTINY,
            footerText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        if (!footerText2.equals("")) {
            dc.drawText(
                width / 2,
                height * 0.92,
                Graphics.FONT_XTINY,
                footerText2,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    private function buildCountdownText(item as NutritionItem) as String {
        var timeToItem = item.scheduledTime - mEngine.getElapsedSeconds();

        if (item.state == "due" || timeToItem <= 0 || !mShowCountdown) {
            return "AHORA";
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
        textColor as Graphics.ColorType
    ) as Void {
        var icon = getCachedDueIcon(item);
        if (icon != null) {
            var targetSize = (height * 0.18).toNumber();
            if (targetSize < 40) {
                targetSize = 40;
            }
            if (targetSize > 56) {
                targetSize = 56;
            }
            var y = (height * 0.38).toNumber();
            var x = (width / 2) - (targetSize / 2);

            if (dc has :drawScaledBitmap) {
                dc.drawScaledBitmap(x, y, targetSize, targetSize, icon);
            } else {
                var ox = (width / 2) - (icon.getWidth() / 2);
                dc.drawBitmap(ox, y, icon);
            }
        }

        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.64,
            Graphics.FONT_SMALL,
            "AHORA",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(getCategoryColorForItem(item), Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.74,
            Graphics.FONT_XTINY,
            ProductClassifier.getCategoryLabel(item),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
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

        if (label.equals("BEBIDA") || label.equals("AGUA")) {
            return 0x66CCFF;
        }
        if (label.equals("GEL")) {
            return 0xFFD166;
        }
        if (label.equals("GOMINOLA")) {
            return 0xFF99CC;
        }
        if (label.equals("ELECTROLITOS")) {
            return 0x99FF99;
        }
        if (label.equals("CAFEINA")) {
            return 0xFFE08A;
        }

        return Graphics.COLOR_BLACK;
    }

    private function resetAlertTracking() as Void {
        mLastAlertItemId = "";
        mLastAlertAtSec = -9999;
        mDueIconCacheItemId = "";
        mDueIconCache = null;
        mLastBackgroundSyncSec = -9999;
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
