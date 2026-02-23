import Toybox.Lang;

/*
 * NutritionPlan - Represents a complete nutrition plan with scheduled items.
 */
class NutritionPlan {
    var id as String;
    var name as String;
    var items as Array<NutritionItem>;
    var targetCHO as Number;  // Target CHO in grams
    var targetNa as Number;   // Target Na in mg

    function initialize(id as String, name as String, items as Array<NutritionItem>, 
                       targetCHO as Number, targetNa as Number) {
        self.id = id;
        self.name = name;
        self.items = items != null ? items : [] as Array<NutritionItem>;
        self.targetCHO = targetCHO != null ? targetCHO : 0;
        self.targetNa = targetNa != null ? targetNa : 0;
    }

    function resetRuntimeState() as Void {
        for (var i = 0; i < items.size(); i++) {
            items[i].resetRuntimeState();
        }
    }

    function getItemCount() as Number {
        return items.size();
    }

    function hasItems() as Boolean {
        return items.size() > 0;
    }

    function getItemAt(index as Number) as NutritionItem? {
        if (index >= 0 && index < items.size()) {
            return items[index];
        }
        return null;
    }
}
