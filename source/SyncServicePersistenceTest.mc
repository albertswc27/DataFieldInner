import Toybox.Test;
import Toybox.Application;
import Toybox.Lang;

/*
 * Regression tests for BUG-001 (multi-plan offline persistence).
 *
 * The sync envelope can exceed the 10000-char property cap, so the full plans
 * array is persisted in Application.Storage ("ifpAllPlansDict") and recovered by
 * SyncService.loadPersistedAllPlans(). These tests exercise that round-trip and
 * the selection-by-id used by the view for offline plan switching.
 *
 * Run: monkeyc --unit-test ...  &&  monkeydo <prg> <device> -t
 */

(:test)
function buildEnvelopePlans() as Array {
    return [
        {
            "id" => "plan-A",
            "name" => "Plan A",
            "items" => [
                { "id" => "a1", "name" => "Gel", "scheduledTime" => 0,
                  "nutrients" => { "cho" => 25, "na" => 50 }, "iconKey" => "gel60_neutro" }
            ]
        },
        {
            "id" => "plan-B",
            "name" => "Plan B",
            "items" => [
                { "id" => "b1", "name" => "Sales", "scheduledTime" => 1800,
                  "nutrients" => { "cho" => 0, "na" => 300 }, "iconKey" => "electrolytes" },
                { "id" => "b2", "name" => "ISO", "scheduledTime" => 3600,
                  "nutrients" => { "cho" => 30, "na" => 200 }, "iconKey" => "iso_250" }
            ]
        }
    ];
}

// Round-trip: lo que persiste persistPlans() en Storage debe recuperarse intacto.
(:test)
function testLoadPersistedAllPlansRoundTrip(logger as Test.Logger) as Boolean {
    Application.Storage.setValue("ifpAllPlansDict", buildEnvelopePlans());

    var loaded = SyncService.getInstance().loadPersistedAllPlans();

    Test.assertEqual(loaded.size(), 2);
    Test.assertEqual(loaded[0].id, "plan-A");
    Test.assertEqual(loaded[1].id, "plan-B");
    Test.assert(loaded[0].hasItems());
    Test.assert(loaded[1].hasItems());
    logger.debug("Round-trip OK: " + loaded.size() + " planes recuperados de Storage");
    return true;
}

// Sin envelope en Storage => array vacío, sin excepción (degradación segura).
(:test)
function testLoadPersistedAllPlansEmpty(logger as Test.Logger) as Boolean {
    Application.Storage.deleteValue("ifpAllPlansDict");

    var loaded = SyncService.getInstance().loadPersistedAllPlans();

    Test.assertEqual(loaded.size(), 0);
    logger.debug("Storage vacío => 0 planes (sin crash)");
    return true;
}

// Selección por id: el segundo plan sigue siendo recuperable/seleccionable
// aunque no sea el activo (núcleo del cambio de plan offline, BUG-001).
(:test)
function testSelectSecondPlanById(logger as Test.Logger) as Boolean {
    Application.Storage.setValue("ifpAllPlansDict", buildEnvelopePlans());

    var loaded = SyncService.getInstance().loadPersistedAllPlans();
    var match = null;
    for (var i = 0; i < loaded.size(); i++) {
        if (loaded[i].id.equals("plan-B")) {
            match = loaded[i];
            break;
        }
    }

    Test.assert(match != null);
    Test.assertEqual(match.id, "plan-B");
    logger.debug("Plan no-activo 'plan-B' seleccionable offline por id");
    return true;
}
