import Toybox.Application;
import Toybox.Attention;
import Toybox.System;
import Toybox.Lang;

/*
 * AlertHelper - Handles vibration and sound alerts.
 * Adapted from AlertController.mc in the original INNER watch app.
 */
class AlertHelper {

    // Trigger vibration based on item type
    static function triggerVibration(item as NutritionItem) as Void {
        if (Attention has :vibrate) {
            try {
                var intensity = getVibrationIntensity();
                var useDrinkPattern = ProductClassifier.shouldUseDrinkPattern(item);
                var category = ProductClassifier.getCategory(item);
                var vibeData;
                
                if (useDrinkPattern) {
                    // Drink pattern: Two short pulses
                    vibeData = [
                        new Attention.VibeProfile(intensity, 150),
                        new Attention.VibeProfile(0, 100),
                        new Attention.VibeProfile(intensity, 150)
                    ];
                } else {
                    // Eat pattern: One long pulse
                    vibeData = [
                        new Attention.VibeProfile(intensity, 400)
                    ];
                }
                
                Attention.vibrate(vibeData);
                var iconText = "none";
                if (item.iconKey != null) {
                    iconText = item.iconKey as String;
                }
                System.println("Vibration triggered: " + category + " (iconKey=" + iconText + ")");
            } catch (e) {
                System.println("Vibration error: " + e.getErrorMessage());
            }
        }
    }
    
    // Encender retroiluminación brevemente para que el aviso sea visible
    // aunque la pantalla esté apagada o atenuada (caso típico en ciclismo
    // de día con auto-dim agresivo). Garmin libera el control después,
    // así que no hay que apagarla manualmente.
    static function triggerBacklight() as Void {
        if (Attention has :backlight) {
            try {
                Attention.backlight(true);
                System.println("Backlight ON for alert");
            } catch (e) {
                System.println("Backlight error: " + e.getErrorMessage());
            }
        }
    }

    // Trigger audio tone
    static function triggerSound() as Void {
        if (Attention has :playTone) {
            try {
                var toneProfile = [
                    new Attention.ToneProfile(2000, 200),  // 2000Hz, 200ms
                    new Attention.ToneProfile(0, 100),     // Silence, 100ms
                    new Attention.ToneProfile(2000, 200)   // 2000Hz, 200ms
                ];
                Attention.playTone({:toneProfile => toneProfile});
                System.println("Tone played");
            } catch (e) {
                System.println("Tone error: " + e.getErrorMessage());
            }
        }
    }
    
    // Get vibration intensity from settings
    static function getVibrationIntensity() as Number {
        var intensitySetting = Application.Properties.getValue("vibrationIntensity");
        var intensityValues = [30, 50, 75]; // Low, Medium, High

        if (intensitySetting != null && intensitySetting instanceof Number) {
            var level = intensitySetting as Number;
            if (level >= 1 && level <= 3) {
                return intensityValues[level - 1];
            }
        }

        return 50; // Default to medium
    }
    
    // Backward-compatible helper.
    static function isDrinkItem(item as NutritionItem) as Boolean {
        return ProductClassifier.shouldUseDrinkPattern(item);
    }
}
