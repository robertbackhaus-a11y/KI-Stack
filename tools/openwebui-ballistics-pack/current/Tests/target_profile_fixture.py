import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path

tool_path = Path(sys.argv[1]).resolve()
data_root = Path(sys.argv[2]).resolve()
os.environ["KI_STACK_BALLISTICS_DATA"] = str(data_root)
spec = importlib.util.spec_from_file_location("ballistics_target_tool", tool_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)
tool = module.Tools()
name = "ki_stack_synthetic_validation_fixture"
profile = data_root / "profiles" / f"{name}.json"
backup = data_root / "backups" / f"{name}.json"
if profile.exists() or backup.exists():
    raise RuntimeError("synthetic fixture residue exists before test")
denied = json.loads(tool.save_profile(name, '{"synthetic":true}', False))
if denied.get("saved") or profile.exists():
    raise RuntimeError("unconfirmed profile was saved")
saved = json.loads(tool.save_profile(name, '{"synthetic":true}', True))
if not saved.get("saved") or not json.loads(tool.load_profile(name))["data"]["synthetic"]:
    raise RuntimeError("profile readback failed")
backup.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(profile, backup)
profile.unlink()
shutil.copy2(backup, profile)
if not json.loads(tool.load_profile(name))["data"]["synthetic"]:
    raise RuntimeError("profile rollback readback failed")
profile.unlink()
backup.unlink()
print(json.dumps({"passed": True, "unconfirmedSave": False, "readback": True, "backup": True, "rollback": True, "residue": False}))
