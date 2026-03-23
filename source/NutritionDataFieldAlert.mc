import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

/*
 * NutritionDataFieldAlert displays an informational nutrition reminder.
 * DataField alerts are non-interactive; the popup closes automatically.
 */
class NutritionDataFieldAlert extends WatchUi.DataFieldAlert {
    hidden var mItemName as String;
    hidden var mCategoryLabel as String;
    hidden var mProductIcon;
    hidden var mCHO as Number;
    hidden var mNa as Number;
    hidden var mAutoConsumeEnabled as Boolean = true;
    hidden var mBatchMode as Boolean = false;
    hidden var mBatchCount as Number = 1;
    hidden var mBatchTotalCHO as Number = 0;
    hidden var mBatchTotalNa as Number = 0;
    hidden var mBatchNames as String = "";

    function initialize(owner as InnerDataField1View, item as NutritionItem, autoConsumeEnabled as Boolean, alertMeta) {
        DataFieldAlert.initialize();

        mItemName = item.name;
        mCategoryLabel = ProductClassifier.getCategoryLabel(item);
        mProductIcon = ProductIconResolver.loadForItem(item);
        mCHO = item.getNutrient("cho");
        mNa = item.getNutrient("na");
        mAutoConsumeEnabled = autoConsumeEnabled;
        mBatchTotalCHO = mCHO;
        mBatchTotalNa = mNa;

        if (alertMeta != null && alertMeta instanceof Dictionary) {
            var meta = alertMeta as Dictionary;
            if (meta.hasKey("batchMode") && meta["batchMode"] instanceof Boolean) {
                mBatchMode = meta["batchMode"] as Boolean;
            }
            if (meta.hasKey("batchCount") && meta["batchCount"] instanceof Number) {
                mBatchCount = meta["batchCount"] as Number;
            }
            if (meta.hasKey("batchTotalCHO") && meta["batchTotalCHO"] instanceof Number) {
                mBatchTotalCHO = meta["batchTotalCHO"] as Number;
            }
            if (meta.hasKey("batchTotalNa") && meta["batchTotalNa"] instanceof Number) {
                mBatchTotalNa = meta["batchTotalNa"] as Number;
            }
            if (meta.hasKey("batchNames") && meta["batchNames"] instanceof String) {
                mBatchNames = meta["batchNames"] as String;
            }
        }

        if (mProductIcon == null) {
            System.println("Alert icon missing: " + mItemName + " (cat=" + mCategoryLabel + ")");
        }
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var catColor = ProductClassifier.getCategoryColor(mCategoryLabel);

        // ── Accent strip at very top ─────────────────────────────────────────
        var stripH = (height * 0.07).toNumber();
        if (stripH < 10) { stripH = 10; }
        dc.setColor(catColor, catColor);
        dc.fillRectangle(0, 0, width, stripH);

        // Batch / category label on the strip
        dc.setColor(0x1A1A2E, Graphics.COLOR_TRANSPARENT);
        var headerLabel = mBatchMode && mBatchCount > 1
            ? "TOMA x" + mBatchCount + "  " + mCategoryLabel
            : mCategoryLabel;
        dc.drawText(
            centerX,
            stripH / 2,
            Graphics.FONT_XTINY,
            headerLabel,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Product icon (centred, large) ─────────────────────────────────────
        drawProductIcon(dc, centerX, height);

        // ── Item name ─────────────────────────────────────────────────────────
        var itemName = truncateText(mItemName, 20);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            centerX,
            height * 0.54,
            Graphics.FONT_SMALL,
            itemName,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // ── Nutrient delta ─────────────────────────────────────────────────────
        var cho = mBatchMode ? mBatchTotalCHO : mCHO;
        var na  = mBatchMode ? mBatchTotalNa  : mNa;
        var nutriLine = "";
        if (cho > 0) { nutriLine = "+" + cho + "g CHO"; }
        if (na > 0) {
            if (!nutriLine.equals("")) { nutriLine += "  "; }
            nutriLine += "+" + na + "mg Na";
        }
        if (!nutriLine.equals("")) {
            dc.setColor(catColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                centerX,
                height * 0.65,
                Graphics.FONT_XTINY,
                nutriLine,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        // ── Bottom confirmation strip ─────────────────────────────────────────
        var botStripY = (height * 0.76).toNumber();
        var botStripH = (height * 0.14).toNumber();
        if (botStripH < 16) { botStripH = 16; }
        if (mAutoConsumeEnabled) {
            dc.setColor(0x22C55E, 0x22C55E);  // green
        } else {
            dc.setColor(0x475569, 0x475569);  // slate
        }
        dc.fillRectangle(0, botStripY, width, botStripH);
        dc.setColor(0xFFFFFF, Graphics.COLOR_TRANSPARENT);
        var confirmLabel = mAutoConsumeEnabled ? "REGISTRADO" : "INFORMATIVO";
        if (mBatchMode && mBatchCount > 1 && mAutoConsumeEnabled) {
            confirmLabel = "LOTE REGISTRADO";
        }
        dc.drawText(
            centerX,
            botStripY + botStripH / 2,
            Graphics.FONT_XTINY,
            confirmLabel,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Batch item names (if any)
        if (mBatchMode && !mBatchNames.equals("")) {
            dc.setColor(0x94A3B8, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                centerX,
                botStripY + botStripH + (height * 0.02),
                Graphics.FONT_XTINY,
                truncateText(mBatchNames, 22),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
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

    private function drawProductIcon(dc as Dc, centerX as Number, height as Number) as Void {
        var boxSize = (height * 0.34).toNumber();
        if (boxSize < 48) {
            boxSize = 48;
        }
        if (boxSize > 90) {
            boxSize = 90;
        }
        var boxX = (centerX - (boxSize / 2)).toNumber();
        var boxY = (height * 0.10).toNumber();

        // Icon container improves visibility on dark alert background.
        dc.setColor(0x1E293B, 0x1E293B);
        dc.fillRectangle(boxX, boxY, boxSize, boxSize);
        dc.setColor(0x334155, Graphics.COLOR_TRANSPARENT);
        if (dc has :drawRectangle) {
            dc.drawRectangle(boxX, boxY, boxSize, boxSize);
        }

        if (mProductIcon == null) {
            dc.setColor(ProductClassifier.getCategoryColor(mCategoryLabel), Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, boxY + (boxSize / 2), Graphics.FONT_XTINY, mCategoryLabel, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        try {
            var iconWidth = mProductIcon.getWidth();
            var iconHeight = mProductIcon.getHeight();
            var targetSize = boxSize - 8;
            if (dc has :drawScaledBitmap) {
                var xScaled = (centerX - (targetSize / 2)).toNumber();
                var yScaled = (boxY + ((boxSize - targetSize) / 2)).toNumber();
                dc.drawScaledBitmap(xScaled, yScaled, targetSize, targetSize, mProductIcon);
                return;
            }

            var x = (centerX - (iconWidth / 2)).toNumber();
            var y = (boxY + ((boxSize - iconHeight) / 2)).toNumber();
            dc.drawBitmap(x, y, mProductIcon);
        } catch (ex) {
            System.println("Alert icon draw failed: " + ex.getErrorMessage());
            dc.setColor(ProductClassifier.getCategoryColor(mCategoryLabel), Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, boxY + (boxSize / 2), Graphics.FONT_XTINY, mCategoryLabel, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

}
