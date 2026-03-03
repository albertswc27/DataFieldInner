import Toybox.Lang;

/*
 * QuickDemoPlanFactory builds a local test plan for simulator/UI iterations.
 * It triggers reminders every 60 seconds and covers several product categories.
 */
class QuickDemoPlanFactory {
    static function buildOneMinuteDemo() as NutritionPlan {
        var items = [] as Array<NutritionItem>;
        var totalCHO = 0;
        var totalNa = 0;

        addDemoItem(items, "d1", "Agua 150ml", 60, 0, 0, "agua_150");
        addDemoItem(items, "d2", "Gel LITE 30 Limon", 120, 30, 175, "gel30_limon");
        addDemoItem(items, "d2b", "Electrolyte LITE 200mg", 120, 0, 200, "electrolytes");
        addDemoItem(items, "d3", "Iso Drink 250ml", 180, 23, 150, "iso_250");
        addDemoItem(items, "d4", "Electrolytes", 240, 0, 200, "electrolytes");
        addDemoItem(items, "d5", "Carbo Gummy", 300, 45, 260, "carbo_gummy");
        addDemoItem(items, "d6", "Gel Hydro 45 Cafe", 360, 45, 275, "gelhydro45_cafe");
        addDemoItem(items, "d7", "Agua 250ml", 420, 0, 0, "agua_250");
        addDemoItem(items, "d8", "Electrolyte LITE 200mg", 480, 0, 200, "electrolytes");
        addDemoItem(items, "d9", "Electro Gummy", 540, 22, 300, "electro_gummy");
        addDemoItem(items, "d10", "Gel 60 Naranja", 600, 60, 350, "gel60_naranja");
        addDemoItem(items, "d11", "Glut5 Drink 150ml", 660, 14, 70, "glut5_150");
        addDemoItem(items, "d12", "Cafeina", 720, 0, 0, "cafeina");
        addDemoItem(items, "d13", "Carbo Gummy Fresa", 780, 47, 260, "carbo_gummy_fresa");

        for (var i = 0; i < items.size(); i++) {
            totalCHO += items[i].getNutrient("cho");
            totalNa += items[i].getNutrient("na");
        }

        return new NutritionPlan(
            "demo-quick-1min",
            "Demo Rapido 1min",
            items,
            totalCHO,
            totalNa
        );
    }

    private static function addDemoItem(
        items as Array<NutritionItem>,
        id as String,
        name as String,
        scheduledTime as Number,
        cho as Number,
        na as Number,
        iconKey as String
    ) as Void {
        var nutrients = {
            "cho" => cho,
            "na" => na
        } as Dictionary<String, Number>;

        items.add(new NutritionItem(id, name, scheduledTime, nutrients, iconKey));
    }
}
