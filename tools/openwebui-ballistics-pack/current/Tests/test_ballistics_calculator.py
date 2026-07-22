import importlib.util
import json
import math
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ballistics_tool", ROOT / "Tool" / "BallisticsCalculator.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)
fixtures = json.loads((ROOT / "Tests" / "fixtures.json").read_text(encoding="utf-8"))


def assert_result(name):
    result = module.calculate_trajectory(fixtures[name])
    rows = result["calculated_rows"]
    assert rows and result["solver"] == "pyballistic 2.2.0 / RK4 pure Python"
    assert all(row["time_of_flight_s"] >= 0 for row in rows)
    assert all(math.isfinite(v) for row in rows for v in row.values() if isinstance(v, float))
    assert all(b["velocity"] <= a["velocity"] + 0.01 for a, b in zip(rows, rows[1:]))
    assert all(abs(row["elevation_moa"] - row["elevation_mrad"] * 3.43774677) < 0.02 for row in rows)
    return result


g1 = assert_result("g1_metric")
g7 = assert_result("g7_imperial")
assert g1["calculated_rows"][-1]["wind_mrad"] == 0
for angle in (0, 90, 180):
    fixture = dict(fixtures["g1_metric"], wind_speed=5, wind_angle=angle, temperature=-5 if angle == 0 else 30, pressure=950 if angle == 180 else 1013.25)
    assert module.calculate_trajectory(fixture)["calculated_rows"]

for key, value in (("ballistic_coefficient", -1), ("muzzle_velocity", 0), ("max_range", -1)):
    fixture = dict(fixtures["g1_metric"], **{key: value})
    try:
        module.calculate_trajectory(fixture)
        raise AssertionError(key)
    except ValueError:
        pass

missing = dict(fixtures["g1_metric"])
del missing["muzzle_velocity"]
try:
    module.calculate_trajectory(missing)
    raise AssertionError("missing input accepted")
except ValueError as exc:
    assert "muzzle_velocity" in str(exc)

try:
    module.calculate_trajectory(dict(fixtures["g1_metric"], altitude=500))
    raise AssertionError("pressure/altitude contradiction accepted")
except ValueError:
    pass

csv_text = module.render_csv(g7)
assert csv_text.splitlines()[0].split(",") == module.CSV_COLUMNS
json.dumps(g7, allow_nan=False)

tool = module.Tools()
with tempfile.TemporaryDirectory() as temp:
    os.environ["KI_STACK_BALLISTICS_DATA"] = temp
    denied = json.loads(tool.save_profile("fixture", '{"synthetic":true}', False))
    assert denied["saved"] is False and not (Path(temp) / "profiles" / "fixture.json").exists()
    saved = json.loads(tool.save_profile("fixture", '{"synthetic":true}', True))
    assert saved["saved"] is True
    assert json.loads(tool.load_profile("fixture"))["data"]["synthetic"] is True
print(json.dumps({"passed": True, "g1Rows": len(g1["calculated_rows"]), "g7Rows": len(g7["calculated_rows"]), "csvColumns": len(module.CSV_COLUMNS)}))
