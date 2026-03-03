import Toybox.System;
import Toybox.WatchUi;
import Toybox.Lang;

/*
 * ProductIconResolver maps iconKey/category to drawable resources.
 */
class ProductIconResolver {
    static function loadForItem(item as NutritionItem) {
        var resourceId = resolveResourceId(item);
        if (resourceId == null) {
            return null;
        }

        try {
            return WatchUi.loadResource(resourceId);
        } catch (e) {
            System.println("Icon load error: " + e.getErrorMessage());
            return null;
        }
    }

    private static function resolveResourceId(item as NutritionItem) {
        var iconKey = ProductCatalogMapper.normalizeIconKey(item.iconKey, null, item.name);

        if (iconKey != null) {
            var key = iconKey as Lang.String;

            // Bebidas / Monodosis
            if (key.equals("glut5_150") || key.equals("glut5_250")) {
                return Rez.Drawables.IconGlut5Drink;
            }
            if (key.equals("iso_150") || key.equals("iso_250")) {
                return Rez.Drawables.IconIsoDrink;
            }
            if (key.equals("buffer")) {
                return Rez.Drawables.IconBuffer;
            }

            // Geles 30g
            if (key.equals("gel30_limon")) { return Rez.Drawables.IconGel30Limon; }
            if (key.equals("gel30_naranja")) { return Rez.Drawables.IconGel30Naranja; }
            if (key.equals("gel30_neutro")) { return Rez.Drawables.IconGel30Neutro; }
            if (key.equals("gel30_caramelo")) { return Rez.Drawables.IconGel30Caramelo; }

            // Geles 35g
            if (key.equals("gelhydro35_fresa")) { return Rez.Drawables.IconGelHydro35Fresa; }
            if (key.equals("gelhydro35_platano")) { return Rez.Drawables.IconGelHydro35Platano; }

            // Geles 45g
            if (key.equals("gelhydro45_cafe")) { return Rez.Drawables.IconGelHydro45Cafe; }
            if (key.equals("gelhydro45_neutro")) { return Rez.Drawables.IconGelHydro45Neutro; }
            if (key.equals("gelhydro45_naranja")) { return Rez.Drawables.IconGelHydro45Naranja; }

            // Geles 60g
            if (key.equals("gel60_limon")) { return Rez.Drawables.IconGel60Limon; }
            if (key.equals("gel60_naranja")) { return Rez.Drawables.IconGel60Naranja; }
            if (key.equals("gel60_neutro")) { return Rez.Drawables.IconGel60Neutro; }
            if (key.equals("gel60_caramelo")) { return Rez.Drawables.IconGel60Caramelo; }
            if (key.equals("gel60_frambuesa")) { return Rez.Drawables.IconGel60Frambuesa; }

            // Gominolas
            if (key.equals("electro_gummy")) { return Rez.Drawables.IconElectroGummy; }
            if (key.equals("carbo_gummy")) { return Rez.Drawables.IconCarboGummy; }
            if (key.equals("carbo_gummy_fresa")) { return Rez.Drawables.IconCarboGummyFresa; }

            // Otros
            if (key.equals("electrolytes") || key.equals("pastillas") || key.equals("sales")) {
                return Rez.Drawables.IconElectrolytes;
            }
            if (key.equals("tart_cherry")) {
                return Rez.Drawables.IconTartCherry;
            }
            if (key.equals("agua_150")) {
                return Rez.Drawables.IconAgua150;
            }
            if (key.equals("agua_250")) {
                return Rez.Drawables.IconAgua250;
            }
            if (key.equals("cafeina")) {
                return Rez.Drawables.IconCafeina;
            }
        }

        // Category-based fallback when iconKey is missing/unmapped.
        var category = ProductClassifier.getCategory(item);
        if (category.equals("water")) {
            return Rez.Drawables.IconAgua150;
        }
        if (category.equals("drink")) {
            return Rez.Drawables.IconIsoDrink;
        }
        if (category.equals("gel")) {
            return Rez.Drawables.IconGel60Naranja;
        }
        if (category.equals("gummy")) {
            return Rez.Drawables.IconCarboGummy;
        }
        if (category.equals("electrolyte")) {
            return Rez.Drawables.IconElectrolytes;
        }
        if (category.equals("caffeine")) {
            return Rez.Drawables.IconCafeina;
        }

        // Nutrient-based fallback for generic/free-mode items.
        var cho = item.getNutrient("cho");
        var na = item.getNutrient("na");
        if (cho > 0 && na > 0) {
            return Rez.Drawables.IconIsoDrink;
        }
        if (cho > 0) {
            return Rez.Drawables.IconGel60Naranja;
        }
        if (na > 0) {
            return Rez.Drawables.IconElectrolytes;
        }

        return null;
    }
}
