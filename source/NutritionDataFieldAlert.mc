import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

/*
 * NutritionDataFieldAlert displays a due nutrition item and captures user intent:
 * consume (START/ENTER) or skip (BACK/ESC).
 */
class NutritionDataFieldAlert extends WatchUi.DataFieldAlert {
    hidden var mItemName as String;
    hidden var mCategoryLabel as String;
    hidden var mProductIcon;
    hidden var mCHO as Number;
    hidden var mNa as Number;

    function initialize(owner as InnerDataField1View, item as NutritionItem) {
        DataFieldAlert.initialize();

        mItemName = item.name;
        mCategoryLabel = ProductClassifier.getCategoryLabel(item);
        mProductIcon = ProductIconResolver.loadForItem(item);
        mCHO = item.getNutrient("cho");
        mNa = item.getNutrient("na");
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

        dc.drawText(centerX, height * 0.12, Graphics.FONT_XTINY, "INNER ALERTA", Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.24, Graphics.FONT_SMALL, itemName, Graphics.TEXT_JUSTIFY_CENTER);

        drawProductIcon(dc, centerX, height);

        dc.setColor(getCategoryColor(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height * 0.64, Graphics.FONT_XTINY, "TIPO: " + mCategoryLabel, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height * 0.72, Graphics.FONT_XTINY, "CHO " + mCHO + "g  Na " + mNa + "mg", Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(0x66FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height * 0.84, Graphics.FONT_XTINY, "Alerta informativa", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height * 0.91, Graphics.FONT_XTINY, "Se cierra automaticamente", Graphics.TEXT_JUSTIFY_CENTER);
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
        if (mProductIcon == null) {
            return;
        }

        var iconWidth = mProductIcon.getWidth();
        var iconHeight = mProductIcon.getHeight();
        var targetSize = (height * 0.24).toNumber();
        if (targetSize < 40) {
            targetSize = 40;
        }
        if (targetSize > 72) {
            targetSize = 72;
        }

        var topY = (height * 0.32).toNumber();
        if (dc has :drawScaledBitmap) {
            var xScaled = centerX - (targetSize / 2);
            dc.drawScaledBitmap(xScaled, topY, targetSize, targetSize, mProductIcon);
            return;
        }

        var x = centerX - (iconWidth / 2);
        dc.drawBitmap(x, topY, mProductIcon);
    }

}
