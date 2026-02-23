import Toybox.Lang;

/*
 * ProductClassifier centralizes product type detection using iconKey first
 * and item name as fallback.
 */
class ProductClassifier {
    static function getCategory(item as NutritionItem) as String {
        var iconCategory = classifyByIcon(item.iconKey);
        if (!iconCategory.equals("other")) {
            return iconCategory;
        }
        return classifyByName(item.name);
    }

    static function getCategoryLabel(item as NutritionItem) as String {
        var category = getCategory(item);

        if (category.equals("water")) {
            return "AGUA";
        }
        if (category.equals("drink")) {
            return "BEBIDA";
        }
        if (category.equals("gel")) {
            return "GEL";
        }
        if (category.equals("gummy")) {
            return "GOMINOLA";
        }
        if (category.equals("electrolyte")) {
            return "ELECTROLITOS";
        }
        if (category.equals("caffeine")) {
            return "CAFEINA";
        }

        return "NUTRICION";
    }

    static function shouldUseDrinkPattern(item as NutritionItem) as Boolean {
        var category = getCategory(item);
        return category.equals("drink") ||
               category.equals("water") ||
               category.equals("electrolyte");
    }

    private static function classifyByIcon(iconKey as String or Null) as String {
        if (iconKey == null) {
            return "other";
        }

        var key = iconKey.toLower();

        // Drinks / monodose.
        if (key.equals("glut5_150") || key.equals("glut5_250") ||
            key.equals("iso_150") || key.equals("iso_250") ||
            key.equals("buffer")) {
            return "drink";
        }

        // Water.
        if (startsWith(key, "agua_")) {
            return "water";
        }

        // Gels.
        if (startsWith(key, "gel30_") ||
            startsWith(key, "gelhydro35_") ||
            startsWith(key, "gelhydro45_") ||
            startsWith(key, "gel60_")) {
            return "gel";
        }

        // Gummies.
        if (key.equals("electro_gummy") ||
            key.equals("carbo_gummy") ||
            key.equals("carbo_gummy_fresa")) {
            return "gummy";
        }

        // Electrolytes.
        if (key.equals("electrolytes") ||
            key.equals("pastillas") ||
            key.equals("sales")) {
            return "electrolyte";
        }

        if (key.equals("cafeina")) {
            return "caffeine";
        }

        return "other";
    }

    private static function classifyByName(name as String) as String {
        var text = name.toLower();

        if (contains(text, "agua") || contains(text, "water")) {
            return "water";
        }

        if (contains(text, "electrolit") || contains(text, "sales") || contains(text, "salt")) {
            return "electrolyte";
        }

        if (contains(text, "gel")) {
            return "gel";
        }

        if (contains(text, "gummy") || contains(text, "gomin")) {
            return "gummy";
        }

        if (contains(text, "cafe") || contains(text, "caffeine")) {
            return "caffeine";
        }

        if (contains(text, "ml") ||
            contains(text, "drink") ||
            contains(text, "isot") ||
            contains(text, "hydro")) {
            return "drink";
        }

        return "other";
    }

    private static function startsWith(text as String, prefix as String) as Boolean {
        if (text.length() < prefix.length()) {
            return false;
        }
        return text.substring(0, prefix.length()).equals(prefix);
    }

    private static function contains(text as String, value as String) as Boolean {
        return text.find(value) != null;
    }
}
