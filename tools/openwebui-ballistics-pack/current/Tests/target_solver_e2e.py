import importlib.util
import json
import sys
from pathlib import Path

tool_path = Path(sys.argv[1]).resolve()
fixture_path = Path(sys.argv[2]).resolve()
spec = importlib.util.spec_from_file_location("ballistics_target_e2e", tool_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)
tool = module.Tools()
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))["g7_imperial"]
payload = json.loads(tool.calculate_dope(json.dumps(fixture), "json"))
rows = payload.get("calculated_rows", [])
if not rows or payload.get("notice") != module.NOTICE:
    raise RuntimeError("G7 target calculation incomplete")
if not all("elevation_mrad" in row and "elevation_moa" in row for row in rows):
    raise RuntimeError("MRAD/MOA output missing")
csv_text = tool.calculate_dope(json.dumps(fixture), "csv")
if not csv_text.startswith(",".join(module.CSV_COLUMNS)) or module.NOTICE not in csv_text:
    raise RuntimeError("CSV target output incomplete")
invalid = json.loads(tool.calculate_dope(json.dumps(dict(fixture, ballistic_coefficient=-0.1)), "json"))
if invalid.get("ok") is not False:
    raise RuntimeError("invalid target input accepted")
print(json.dumps({"passed": True, "dragModel": "G7", "rows": len(rows), "mrad": True, "moa": True, "csv": True, "notice": True, "invalidRejected": True}))
