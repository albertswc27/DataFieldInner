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
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;

        var itemName = mItemName;
        if (itemName.length() > 18) {
            itemName = itemName.substring(0, 16) + "..";
        }

        dc.drawText(centerX, height * 0.12, Graphics.FONT_XTINY, "INNER NUTRICION", Graphics.TEXT_JUSTIFY_CENTER);
        if (mBatchMode && mBatchCount > 1) {
            dc.drawText(centerX, height * 0.20, Graphics.FONT_XTINY, "TOMA MULTIPLE x" + mBatchCount, Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(centerX, height * 0.28, Graphics.FONT_SMALL, itemName, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, height * 0.24, Graphics.FONT_SMALL, itemName, Graphics.TEXT_JUSTIFY_CENTER);
        }

        drawProductIcon(dc, centerX, height);

        dc.setColor(getCategoryColor(), Graphics.COLOR_TRANSPARENT);
        if (mBatchMode && mBatchCount > 1) {
            dc.drawText(centerX, height * 0.64, Graphics.FONT_XTINY, "PRINCIPAL: " + mCategoryLabel, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, height * 0.64, Graphics.FONT_XTINY, "TIPO: " + mCategoryLabel, Graphics.TEXT_JUSTIFY_CENTER);
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (mBatchMode && mBatchCount > 1) {
            dc.drawText(centerX, height * 0.72, Graphics.FONT_XTINY, "Lote CHO " + mBatchTotalCHO + "g  Na " + mBatchTotalNa + "mg", Graphics.TEXT_JUSTIFY_CENTER);
            if (!mBatchNames.equals("")) {
                dc.drawText(centerX, height * 0.78, Graphics.FONT_XTINY, truncateText(mBatchNames, 22), Graphics.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.drawText(centerX, height * 0.72, Graphics.FONT_XTINY, "CHO " + mCHO + "g  Na " + mNa + "mg", Graphics.TEXT_JUSTIFY_CENTER);
        }

        dc.setColor(0x66FF66, Graphics.COLOR_TRANSPARENT);
        if (mAutoConsumeEnabled) {
            if (mBatchMode && mBatchCount > 1) {
                dc.drawText(centerX, height * 0.86, Graphics.FONT_XTINY, "Lote auto-registrado", Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                dc.drawText(centerX, height * 0.84, Graphics.FONT_XTINY, "Auto-registrado", Graphics.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.drawText(centerX, height * 0.84, Graphics.FONT_XTINY, "Alerta informativa", Graphics.TEXT_JUSTIFY_CENTER);
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (mAutoConsumeEnabled) {
            if (mBatchMode && mBatchCount > 1) {
                dc.drawText(centerX, height * 0.93, Graphics.FONT_XTINY, "CHO/Na actualizados", Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                dc.drawText(centerX, height * 0.91, Graphics.FONT_XTINY, "Suma actualizada", Graphics.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.drawText(centerX, height * 0.91, Graphics.FONT_XTINY, "Sin interaccion", Graphics.TEXT_JUSTIFY_CENTER);
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

    private function getCategoryColor() as Graphics.ColorType {
        if (mCategoryLabel.equals("BEBIDA") || mCategoryLabel.equals("AGUA")) {
            return 0x66CCFF;
        }
        if (mCategoryLabel.equals("GEL")) {
            return 0xFFD166;
        }
        if (mCategoryLabel.equals("GOMINOLA")) {
            return 0xFF99CC;
        }
        if (mCategoryLabel.equals("ELECTROLITOS")) {
            return 0x99FF99;
        }
        if (mCategoryLabel.equals("CAFEINA")) {
            return 0xFFE08A;
        }
        return Graphics.COLOR_WHITE;
    }

    private function drawProductIcon(dc as Dc, centerX as Number, height as Number) as Void {
        var boxSize = (height * 0.26).toNumber();
        if (boxSize < 42) {
            boxSize = 42;
        }
        if (boxSize > 76) {
            boxSize = 76;
        }
        var boxX = (centerX - (boxSize / 2)).toNumber();
        var boxY = (height * 0.33).toNumber();

        // Icon container improves visibility on dark alert background.
        dc.setColor(0x1E293B, 0x1E293B);
        dc.fillRectangle(boxX, boxY, boxSize, boxSize);
        dc.setColor(0x334155, Graphics.COLOR_TRANSPARENT);
        if (dc has :drawRectangle) {
            dc.drawRectangle(boxX, boxY, boxSize, boxSize);
        }

        if (mProductIcon == null) {
            dc.setColor(getCategoryColor(), Graphics.COLOR_TRANSPARENT);
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
            dc.setColor(getCategoryColor(), Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, boxY + (boxSize / 2), Graphics.FONT_XTINY, mCategoryLabel, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

}
