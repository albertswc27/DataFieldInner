import Toybox.Lang;

/*
 * ProductCatalogMapper normalizes web product identifiers (slugs/codes) to:
 * - internal Garmin icon keys
 * - default CHO / Na values when the payload omits nutrients
 *
 * It also supports drink portion scaling using the item name (e.g. "250ml").
 */
class ProductCatalogMapper {

    static function normalizeIconKey(
        existingIconKey as String or Null,
        rawProductKey as String or Null,
        itemName as String
    ) as String or Null {
        var key = mapProductKeyToInternal(existingIconKey);
        if (key != null) {
            return key;
        }

        key = mapProductKeyToInternal(rawProductKey);
        if (key != null) {
            return key;
        }

        // Name-based normalization fallback for server payloads that don't include iconKey/slug.
        var text = itemName != null ? itemName.toLower() : "";
        if (contains(text, "electrolyte lite") || contains(text, "pastillas") || contains(text, "sales")) {
            return "electrolytes";
        }
        if (contains(text, "iso drink")) {
            var ml = extractPortionMl(itemName);
            return ml <= 150 ? "iso_150" : "iso_250";
        }
        if (contains(text, "glut5 drink") || contains(text, "drink")) {
            var ml2 = extractPortionMl(itemName);
            return ml2 <= 150 ? "glut5_150" : "glut5_250";
        }
        if (contains(text, "carbo gummy") && contains(text, "fresa")) {
            return "carbo_gummy_fresa";
        }
        if (contains(text, "carbo gummy") || contains(text, "gominola carbo")) {
            return "carbo_gummy";
        }
        if (contains(text, "electro gummy") || contains(text, "gominola electro")) {
            return "electro_gummy";
        }

        return null;
    }

    static function fillMissingNutrients(
        itemName as String,
        rawProductKey as String or Null,
        iconKey as String or Null,
        cho as Number,
        na as Number
    ) as Dictionary<String, Number> {
        var resultCho = cho;
        var resultNa = na;

        if (resultCho > 0 && resultNa > 0) {
            return {"cho" => resultCho, "na" => resultNa} as Dictionary<String, Number>;
        }

        var productCode = normalizeToken(rawProductKey);
        var mapped = getCatalogMacros(productCode, itemName);

        if (mapped == null && iconKey != null) {
            mapped = getCatalogMacros(normalizeToken(iconKey as String), itemName);
        }

        if (mapped != null) {
            if (resultCho <= 0 && mapped.hasKey("cho")) {
                resultCho = mapped["cho"] as Number;
            }
            if (resultNa <= 0 && mapped.hasKey("na")) {
                resultNa = mapped["na"] as Number;
            }
        }

        return {"cho" => resultCho, "na" => resultNa} as Dictionary<String, Number>;
    }

    private static function getCatalogMacros(productCode as String or Null, itemName as String) as Dictionary<String, Number>? {
        var code = productCode != null ? productCode as String : "";
        if (code.equals("")) {
            return getNameBasedMacros(itemName);
        }

        // 60g gels
        if (startsWith(code, "glut5-limon-60") || startsWith(code, "gel60_limon")) { return macros(60, 350); }
        if (startsWith(code, "glut5-naranja-60") || startsWith(code, "gel60_naranja")) { return macros(60, 350); }
        if (startsWith(code, "glut5-neutro-60") || startsWith(code, "gel60_neutro")) { return macros(60, 350); }
        if (startsWith(code, "glut5-frambuesa-60") || startsWith(code, "gel60_frambuesa")) { return macros(60, 350); }
        if (startsWith(code, "glut5-caramelo-60") || startsWith(code, "gel60_caramelo")) { return macros(60, 350); }

        // Lite 30g gels
        if (startsWith(code, "glut5-lite-limon") || startsWith(code, "gel30_limon")) { return macros(30, 175); }
        if (startsWith(code, "glut5-lite-neutro") || startsWith(code, "gel30_neutro")) { return macros(30, 175); }
        if (startsWith(code, "glut5-lite-naranja") || startsWith(code, "gel30_naranja")) { return macros(30, 175); }
        if (startsWith(code, "glut5-lite-caramelo") || startsWith(code, "gel30_caramelo")) { return macros(30, 175); }
        if (startsWith(code, "glut5-lite-frambuesa")) { return macros(30, 175); }

        // Hydro gels
        if (startsWith(code, "glut5-hydro-fresa") || startsWith(code, "gelhydro35_fresa")) { return macros(35, 200); }
        if (startsWith(code, "glut5-hydro-platano") || startsWith(code, "gelhydro35_platano")) { return macros(35, 200); }
        if (startsWith(code, "glut5-hydro-limon")) { return macros(35, 200); }
        if (startsWith(code, "glut5-hydro-45-cafe") || startsWith(code, "gelhydro45_cafe")) { return macros(45, 275); }
        if (startsWith(code, "glut5-hydro-45-neutro") || startsWith(code, "gelhydro45_neutro")) { return macros(45, 275); }
        if (startsWith(code, "glut5-hydro-45-naranja") || startsWith(code, "gelhydro45_naranja")) { return macros(45, 275); }

        // Gummies
        if (startsWith(code, "gominola-electrolitos") || startsWith(code, "electro-gummy-neutro") || startsWith(code, "electro_gummy")) {
            return macros(22, 300);
        }
        if (startsWith(code, "gominola-carbohidratos") || startsWith(code, "carbo-gummy-neutro") || startsWith(code, "carbo_gummy")) {
            return macros(45, 260);
        }
        if (startsWith(code, "gominola-carbo-fresa") || startsWith(code, "carbo_gummy_fresa")) {
            return macros(47, 260);
        }

        // Drinks (portion-scaled when item name provides ml)
        if (startsWith(code, "iso-drink-") || startsWith(code, "iso_")) {
            return scaleDrinkByPortion(itemName, 500, 45.0, 300.0);
        }
        if (startsWith(code, "glut5-drink-") || startsWith(code, "glut5_")) {
            return scaleDrinkByPortion(itemName, 750, 67.5, 350.0);
        }

        // Electrolytes / salts
        if (startsWith(code, "pastillas-sales-200mg") ||
            startsWith(code, "electrolyte-lite-120-pack") ||
            startsWith(code, "electrolytes") ||
            startsWith(code, "sales") ||
            startsWith(code, "pastillas")) {
            return macros(0, 200);
        }

        if (startsWith(code, "recovery-shot") ||
            startsWith(code, "glycogen-recovery") ||
            startsWith(code, "glycogen-recuperacion") ||
            startsWith(code, "tart_cherry")) {
            return macros(0, 0);
        }

        return getNameBasedMacros(itemName);
    }

    private static function getNameBasedMacros(itemName as String) as Dictionary<String, Number>? {
        var text = itemName != null ? itemName.toLower() : "";
        if (text.equals("")) {
            return null;
        }

        if (contains(text, "electrolyte lite") || (contains(text, "electrolit") && contains(text, "200"))) {
            return macros(0, 200);
        }

        if (contains(text, "gel lite") && contains(text, "30")) {
            return macros(30, 175);
        }

        if (contains(text, "gel hydro") && contains(text, "45")) {
            return macros(45, 275);
        }

        if (contains(text, "gel hydro") && contains(text, "35")) {
            return macros(35, 200);
        }

        if (contains(text, "gel") && contains(text, "60")) {
            return macros(60, 350);
        }

        if (contains(text, "carbo gummy") && contains(text, "fresa")) {
            return macros(47, 260);
        }

        if (contains(text, "carbo gummy") || contains(text, "gominola carbo")) {
            return macros(45, 260);
        }

        if (contains(text, "electro gummy") || contains(text, "gominola electro")) {
            return macros(22, 300);
        }

        if (contains(text, "iso drink")) {
            return scaleDrinkByPortion(itemName, 500, 45.0, 300.0);
        }

        if (contains(text, "glut5 drink")) {
            return scaleDrinkByPortion(itemName, 750, 67.5, 350.0);
        }

        return null;
    }

    private static function scaleDrinkByPortion(
        itemName as String,
        baseVolumeMl as Number,
        baseCHO as Float,
        baseNa as Float
    ) as Dictionary<String, Number> {
        var portionMl = normalizeTimelineDrinkPortionMl(itemName);

        // Timeline rule: drink ingestions are only 150ml or 250ml.
        // Values are precomputed from the full bottle to keep Garmin values stable.
        if (baseVolumeMl == 500) {
            // ISO DRINK (500ml = 45g CHO / 300mg Na)
            if (portionMl == 150) { return macros(14, 90); }
            return macros(23, 150); // 250ml
        }

        if (baseVolumeMl == 750) {
            // GLUT5 DRINK (750ml = 67.5g CHO / 350mg Na)
            if (portionMl == 150) { return macros(14, 70); }
            return macros(23, 117); // 250ml
        }

        // Defensive fallback for any future drink type.
        if (portionMl <= 0) {
            portionMl = baseVolumeMl;
        }
        var ratio = portionMl.toFloat() / baseVolumeMl.toFloat();
        var choRounded = ((baseCHO * ratio) + 0.5).toNumber();
        var naRounded = ((baseNa * ratio) + 0.5).toNumber();
        return macros(choRounded, naRounded);
    }

    private static function extractPortionMl(itemName as String) as Number {
        var text = itemName != null ? itemName.toLower() : "";
        if (contains(text, "150ml")) { return 150; }
        if (contains(text, "250ml")) { return 250; }
        if (contains(text, "500ml")) { return 500; }
        if (contains(text, "750ml")) { return 750; }
        return 0;
    }

    private static function normalizeTimelineDrinkPortionMl(itemName as String) as Number {
        var ml = extractPortionMl(itemName);
        if (ml == 150) {
            return 150;
        }
        if (ml == 250) {
            return 250;
        }

        // Timeline should only use 150/250. Default to 250ml if unspecified.
        return 250;
    }

    private static function mapProductKeyToInternal(rawKey as String or Null) as String or Null {
        if (rawKey == null) {
            return null;
        }

        var code = normalizeToken(rawKey);
        if (code.equals("")) {
            return null;
        }

        // Already normalized internal keys.
        if (startsWith(code, "gel30_") || startsWith(code, "gelhydro35_") || startsWith(code, "gelhydro45_") ||
            startsWith(code, "gel60_") || startsWith(code, "iso_") || startsWith(code, "glut5_") ||
            code.equals("electrolytes") || code.equals("electro_gummy") || code.equals("carbo_gummy") ||
            code.equals("carbo_gummy_fresa") || code.equals("buffer") || code.equals("agua_150") ||
            code.equals("agua_250") || code.equals("cafeina") || code.equals("tart_cherry")) {
            return code;
        }

        // Web catalog slugs -> internal icon keys
        if (startsWith(code, "glut5-lite-limon")) { return "gel30_limon"; }
        if (startsWith(code, "glut5-lite-neutro")) { return "gel30_neutro"; }
        if (startsWith(code, "glut5-lite-naranja")) { return "gel30_naranja"; }
        if (startsWith(code, "glut5-lite-caramelo")) { return "gel30_caramelo"; }
        if (startsWith(code, "glut5-lite-frambuesa")) { return "gel30_limon"; } // no dedicated 30g raspberry icon yet

        if (startsWith(code, "glut5-hydro-fresa")) { return "gelhydro35_fresa"; }
        if (startsWith(code, "glut5-hydro-platano")) { return "gelhydro35_platano"; }
        if (startsWith(code, "glut5-hydro-limon")) { return "gelhydro35_fresa"; }
        if (startsWith(code, "glut5-hydro-45-cafe")) { return "gelhydro45_cafe"; }
        if (startsWith(code, "glut5-hydro-45-neutro")) { return "gelhydro45_neutro"; }
        if (startsWith(code, "glut5-hydro-45-naranja")) { return "gelhydro45_naranja"; }

        if (startsWith(code, "glut5-limon-60")) { return "gel60_limon"; }
        if (startsWith(code, "glut5-naranja-60")) { return "gel60_naranja"; }
        if (startsWith(code, "glut5-neutro-60")) { return "gel60_neutro"; }
        if (startsWith(code, "glut5-frambuesa-60")) { return "gel60_frambuesa"; }
        if (startsWith(code, "glut5-caramelo-60")) { return "gel60_caramelo"; }

        if (startsWith(code, "gominola-electrolitos") || startsWith(code, "electro-gummy-neutro")) { return "electro_gummy"; }
        if (startsWith(code, "gominola-carbohidratos") || startsWith(code, "carbo-gummy-neutro")) { return "carbo_gummy"; }
        if (startsWith(code, "gominola-carbo-fresa")) { return "carbo_gummy_fresa"; }

        if (startsWith(code, "iso-drink-")) { return "iso_250"; }
        if (startsWith(code, "glut5-drink-")) { return "glut5_250"; }

        if (startsWith(code, "pastillas-sales-200mg") || startsWith(code, "electrolyte-lite-120-pack")) { return "electrolytes"; }

        if (startsWith(code, "recovery-shot") ||
            startsWith(code, "glycogen-recovery") ||
            startsWith(code, "glycogen-recuperacion")) { return "tart_cherry"; }

        return null;
    }

    private static function normalizeToken(raw) as String {
        if (raw == null) {
            return "";
        }

        var text = raw.toString().toLower();
        var out = "";
        for (var i = 0; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);
            if (isAlphaNum(ch)) {
                out += ch;
            } else if (ch.equals("-") || ch.equals("_") || ch.equals(" ") || ch.equals("/")) {
                if (out.length() == 0 || out.substring(out.length() - 1, out.length()).equals("-")) {
                    continue;
                }
                out += "-";
            }
        }

        while (out.length() > 0 && out.substring(out.length() - 1, out.length()).equals("-")) {
            out = out.substring(0, out.length() - 1);
        }

        // Internal icon keys use underscores.
        if (contains(out, "gel30-")) { out = replaceChar(out, "-", "_"); }
        if (contains(out, "gelhydro35-")) { out = replaceChar(out, "-", "_"); }
        if (contains(out, "gelhydro45-")) { out = replaceChar(out, "-", "_"); }
        if (contains(out, "gel60-")) { out = replaceChar(out, "-", "_"); }
        if (startsWith(out, "iso-150")) { out = "iso_150"; }
        if (startsWith(out, "iso-250")) { out = "iso_250"; }
        if (startsWith(out, "glut5-150")) { out = "glut5_150"; }
        if (startsWith(out, "glut5-250")) { out = "glut5_250"; }
        if (out.equals("electro-gummy")) { out = "electro_gummy"; }
        if (out.equals("carbo-gummy")) { out = "carbo_gummy"; }
        if (out.equals("carbo-gummy-fresa")) { out = "carbo_gummy_fresa"; }
        if (out.equals("agua-150")) { out = "agua_150"; }
        if (out.equals("agua-250")) { out = "agua_250"; }
        if (out.equals("tart-cherry")) { out = "tart_cherry"; }

        return out;
    }

    private static function macros(cho as Number, na as Number) as Dictionary<String, Number> {
        return {"cho" => cho, "na" => na} as Dictionary<String, Number>;
    }

    private static function contains(text as String, needle as String) as Boolean {
        return text != null && needle != null && text.find(needle) != null;
    }

    private static function startsWith(text as String, prefix as String) as Boolean {
        if (text == null || prefix == null || text.length() < prefix.length()) {
            return false;
        }
        return text.substring(0, prefix.length()).equals(prefix);
    }

    private static function isAlphaNum(ch as String) as Boolean {
        var letters = "abcdefghijklmnopqrstuvwxyz0123456789";
        return letters.find(ch) != null;
    }

    private static function replaceChar(text as String, target as String, replacement as String) as String {
        var out = "";
        for (var i = 0; i < text.length(); i++) {
            var ch = text.substring(i, i + 1);
            if (ch.equals(target)) {
                out += replacement;
            } else {
                out += ch;
            }
        }
        return out;
    }
}
