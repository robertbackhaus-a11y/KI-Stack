"""
title: KI-Stack Ballistikrechner
author: KI-Stack
version: 1.0.0
required_open_webui_version: 0.11.0
requirements: pyballistic==2.2.0,Deprecated==1.2.18,wrapt==1.17.3
managed_by: KI-STACK-OPENWEBUI-BALLISTICS-PACK
canonical_id: ki-stack-ballistics-calculator
"""

from __future__ import annotations

import csv
import io
import json
import math
import os
import statistics
from pathlib import Path
from typing import Any, Dict, List, Literal, Optional

NOTICE = (
    "Numerische Näherungsberechnung. Reale Trefferlage durch Chronographen-, "
    "Umwelt- und Schießstanddaten verifizieren."
)
MANAGED_BY = "KI-STACK-OPENWEBUI-BALLISTICS-PACK"
CSV_COLUMNS = [
    "range", "range_unit", "elevation_mrad", "elevation_moa", "wind_mrad",
    "wind_moa", "velocity", "velocity_unit", "time_of_flight_s", "energy",
    "energy_unit", "temperature", "pressure", "humidity", "wind_speed",
    "wind_angle", "drag_model", "ballistic_coefficient", "muzzle_velocity",
    "zero_distance", "sight_height",
]


def _finite(name: str, value: Any, *, positive: bool = False, minimum: float | None = None) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} muss numerisch sein.") from exc
    if not math.isfinite(number):
        raise ValueError(f"{name} muss endlich sein.")
    if positive and number <= 0:
        raise ValueError(f"{name} muss größer als 0 sein.")
    if minimum is not None and number < minimum:
        raise ValueError(f"{name} muss mindestens {minimum} sein.")
    return number


def _unit_value(unit: Any, value: float) -> Any:
    return unit(value)


def calculate_trajectory(data: Dict[str, Any]) -> Dict[str, Any]:
    required = [
        "bullet_description", "drag_model", "ballistic_coefficient", "muzzle_velocity",
        "muzzle_velocity_unit", "sight_height", "sight_height_unit", "zero_distance",
        "zero_distance_unit", "angular_output", "max_range", "range_step", "range_unit",
        "output_system", "temperature", "temperature_unit", "humidity", "wind_speed",
        "wind_unit", "wind_angle",
    ]
    missing = [name for name in required if data.get(name) is None or data.get(name) == ""]
    if data.get("pressure") in (None, "") and not data.get("standard_atmosphere", False):
        missing.append("pressure oder standard_atmosphere=true")
    if missing:
        raise ValueError("Fehlende Pflichtwerte: " + ", ".join(missing))

    drag_name = str(data["drag_model"]).upper()
    if drag_name not in {"G1", "G7"}:
        raise ValueError("drag_model muss G1 oder G7 sein.")
    angular_output = str(data["angular_output"]).upper()
    if angular_output not in {"MRAD", "MOA"}:
        raise ValueError("angular_output muss MRAD oder MOA sein.")
    output_system = str(data["output_system"]).lower()
    if output_system not in {"metric", "imperial"}:
        raise ValueError("output_system muss metric oder imperial sein.")

    bc = _finite("ballistic_coefficient", data["ballistic_coefficient"], positive=True)
    mv = _finite("muzzle_velocity", data["muzzle_velocity"], positive=True)
    sight = _finite("sight_height", data["sight_height"], positive=True)
    zero = _finite("zero_distance", data["zero_distance"], positive=True)
    maximum = _finite("max_range", data["max_range"], positive=True)
    step = _finite("range_step", data["range_step"], positive=True)
    if step > maximum:
        raise ValueError("range_step darf max_range nicht überschreiten.")
    temperature = _finite("temperature", data["temperature"])
    humidity = _finite("humidity", data["humidity"], minimum=0)
    if humidity > 100:
        raise ValueError("humidity darf 100 Prozent nicht überschreiten.")
    wind_speed = _finite("wind_speed", data["wind_speed"], minimum=0)
    wind_angle = _finite("wind_angle", data["wind_angle"])
    if not 0 <= wind_angle <= 360:
        raise ValueError("wind_angle muss zwischen 0 und 360 Grad liegen.")

    import pyballistic as pb

    distance_units = {"m": pb.Unit.Meter, "meter": pb.Unit.Meter, "yd": pb.Unit.Yard, "yard": pb.Unit.Yard}
    velocity_units = {"m/s": pb.Unit.MPS, "mps": pb.Unit.MPS, "fps": pb.Unit.FPS, "ft/s": pb.Unit.FPS}
    sight_units = {"cm": pb.Unit.Centimeter, "in": pb.Unit.Inch, "inch": pb.Unit.Inch}
    temp_units = {"c": pb.Unit.Celsius, "celsius": pb.Unit.Celsius, "f": pb.Unit.Fahrenheit, "fahrenheit": pb.Unit.Fahrenheit}
    pressure_units = {"hpa": pb.Unit.hPa, "mbar": pb.Unit.hPa, "inhg": pb.Unit.InHg}
    try:
        range_unit = distance_units[str(data["range_unit"]).lower()]
        zero_unit = distance_units[str(data["zero_distance_unit"]).lower()]
        mv_unit = velocity_units[str(data["muzzle_velocity_unit"]).lower()]
        wind_unit = velocity_units[str(data["wind_unit"]).lower()]
        sight_unit = sight_units[str(data["sight_height_unit"]).lower()]
        temp_unit = temp_units[str(data["temperature_unit"]).lower()]
    except KeyError as exc:
        raise ValueError(f"Nicht unterstützte oder widersprüchliche Einheit: {exc.args[0]}") from exc

    weight = data.get("bullet_weight")
    weight_value = 0 if weight in (None, "") else _finite("bullet_weight", weight, positive=True)
    weight_unit_name = str(data.get("bullet_weight_unit", "grain")).lower()
    if weight_value:
        weight_units = {"grain": pb.Unit.Grain, "gr": pb.Unit.Grain, "g": pb.Unit.Gram, "gram": pb.Unit.Gram}
        if weight_unit_name not in weight_units:
            raise ValueError("bullet_weight_unit muss grain/gr oder g/gram sein.")
        solver_weight = weight_units[weight_unit_name](weight_value)
    else:
        solver_weight = 0

    table = pb.TableG1 if drag_name == "G1" else pb.TableG7
    ammo = pb.Ammo(pb.DragModel(bc, table, solver_weight), mv_unit(mv))
    twist = data.get("twist_rate")
    weapon = pb.Weapon(
        sight_height=sight_unit(sight),
        twist=None if twist in (None, "") else pb.Unit.Inch(_finite("twist_rate", twist, positive=True)),
    )

    standard = bool(data.get("standard_atmosphere", False))
    altitude = data.get("altitude")
    if standard:
        pressure_value = None
        altitude_value = pb.Unit.Meter(_finite("altitude", altitude or 0))
        pressure_label = "Standardatmosphäre"
    else:
        if altitude not in (None, ""):
            raise ValueError("Station Pressure und Höhe dürfen nicht gleichzeitig zur Druckkorrektur verwendet werden.")
        pressure = _finite("pressure", data["pressure"], positive=True)
        pressure_name = str(data.get("pressure_unit", "hPa")).lower()
        if pressure_name not in pressure_units:
            raise ValueError("pressure_unit muss hPa/mbar oder inHg sein.")
        pressure_value = pressure_units[pressure_name](pressure)
        altitude_value = pb.Unit.Meter(0)
        pressure_label = f"{pressure:g} {data.get('pressure_unit', 'hPa')} Station Pressure"

    atmo = pb.Atmo(
        altitude=altitude_value,
        pressure=pressure_value,
        temperature=temp_unit(temperature),
        humidity=humidity,
    )
    wind = pb.Wind(velocity=wind_unit(wind_speed), direction_from=pb.Unit.Degree(wind_angle))
    shot = pb.Shot(
        weapon=weapon,
        ammo=ammo,
        atmo=atmo,
        winds=[wind],
        look_angle=pb.Unit.Degree(_finite("shot_angle", data.get("shot_angle", 0))),
    )
    calculator = pb.Calculator(engine=pb.RK4IntegrationEngine)
    calculator.set_weapon_zero(shot, zero_unit(zero))
    result = calculator.fire(shot, range_unit(maximum), range_unit(step))

    out_range_unit = pb.Unit.Meter if output_system == "metric" else pb.Unit.Yard
    out_range_name = "m" if output_system == "metric" else "yd"
    out_drop_unit = pb.Unit.Centimeter if output_system == "metric" else pb.Unit.Inch
    out_drop_name = "cm" if output_system == "metric" else "in"
    out_velocity_unit = pb.Unit.MPS if output_system == "metric" else pb.Unit.FPS
    out_velocity_name = "m/s" if output_system == "metric" else "fps"
    out_energy_unit = pb.Unit.Joule if output_system == "metric" else pb.Unit.FootPound
    out_energy_name = "J" if output_system == "metric" else "ft-lb"
    click_value = data.get("click_value")
    click = None if click_value in (None, "") else _finite("click_value", click_value, positive=True)
    click_unit = str(data.get("click_unit", angular_output)).upper()
    if click is not None and click_unit not in {"MRAD", "MOA"}:
        raise ValueError("click_unit muss MRAD oder MOA sein.")

    rows: List[Dict[str, Any]] = []
    for point in result:
        elevation_mrad = point.drop_adj >> pb.Unit.MRad
        elevation_moa = point.drop_adj >> pb.Unit.MOA
        wind_mrad = point.windage_adj >> pb.Unit.MRad
        wind_moa = point.windage_adj >> pb.Unit.MOA
        row = {
            "range": round(point.distance >> out_range_unit, 3),
            "range_unit": out_range_name,
            "drop": round(point.height >> out_drop_unit, 3),
            "drop_unit": out_drop_name,
            "elevation_mrad": round(elevation_mrad, 3),
            "elevation_moa": round(elevation_moa, 3),
            "elevation_clicks": None if click is None else round((elevation_mrad if click_unit == "MRAD" else elevation_moa) / click, 1),
            "wind_drift": round(point.windage >> out_drop_unit, 3),
            "wind_drift_unit": out_drop_name,
            "wind_mrad": round(wind_mrad, 3),
            "wind_moa": round(wind_moa, 3),
            "wind_clicks": None if click is None else round((wind_mrad if click_unit == "MRAD" else wind_moa) / click, 1),
            "velocity": round(point.velocity >> out_velocity_unit, 2),
            "velocity_unit": out_velocity_name,
            "time_of_flight_s": round(float(point.time), 4),
            "energy": None if not weight_value else round(point.energy >> out_energy_unit, 2),
            "energy_unit": None if not weight_value else out_energy_name,
            "mach": round(float(point.mach), 3) if math.isfinite(float(point.mach)) else None,
            "temperature": temperature,
            "pressure": pressure_label,
            "humidity": humidity,
            "wind_speed": wind_speed,
            "wind_angle": wind_angle,
            "drag_model": drag_name,
            "ballistic_coefficient": bc,
            "muzzle_velocity": mv,
            "zero_distance": zero,
            "sight_height": sight,
        }
        if any(isinstance(value, float) and not math.isfinite(value) for value in row.values()):
            raise ArithmeticError("Solver lieferte NaN oder Infinity.")
        rows.append(row)

    velocities = [row["velocity"] for row in rows]
    if any(right > left + 0.01 for left, right in zip(velocities, velocities[1:])):
        raise ArithmeticError("Restgeschwindigkeit ist nicht monoton fallend.")

    assumptions = ["3-DoF-Punktmassenmodell", "RK4-Integrationskern"]
    unsupported = ["Coriolis", "automatische BC-/Mündungsgeschwindigkeits-Kalibrierung"]
    if not data.get("twist_rate"):
        unsupported.append("Spin Drift (kein Laufdrall angegeben)")
    return {
        "schema_version": "1.0.0",
        "solver": "pyballistic 2.2.0 / RK4 pure Python",
        "inputs": data,
        "calculated_rows": rows,
        "assumptions": assumptions,
        "not_considered": unsupported,
        "notice": NOTICE,
    }


def render_csv(result: Dict[str, Any]) -> str:
    stream = io.StringIO(newline="")
    writer = csv.DictWriter(stream, fieldnames=CSV_COLUMNS, extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    writer.writerows(result["calculated_rows"])
    return stream.getvalue()


def render_table(result: Dict[str, Any]) -> str:
    header = "| Entfernung | Abfall | Elev. MRAD | Elev. MOA | Wind | Wind MRAD | Wind MOA | V | TOF | Energie | Mach |\n|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    lines = [header]
    for row in result["calculated_rows"]:
        lines.append(
            f"| {row['range']} {row['range_unit']} | {row['drop']} {row['drop_unit']} | "
            f"{row['elevation_mrad']} | {row['elevation_moa']} | {row['wind_drift']} {row['wind_drift_unit']} | "
            f"{row['wind_mrad']} | {row['wind_moa']} | {row['velocity']} {row['velocity_unit']} | "
            f"{row['time_of_flight_s']} s | {row['energy'] if row['energy'] is not None else 'n/a'} "
            f"{row['energy_unit'] or ''} | {row['mach']} |"
        )
    lines.extend(["", "**Nutzereingaben:** explizit im Tool-Aufruf übergebene Werte.", "**Berechnete Werte:** alle Tabellenwerte.", "**Annahmen:** " + ", ".join(result["assumptions"]), "**Nicht berücksichtigt:** " + ", ".join(result["not_considered"]), NOTICE])
    return "\n".join(lines)


class Tools:
    def calculate_dope(self, parameters_json: str, output_format: Literal["table", "csv", "json", "card"] = "table") -> str:
        """Berechnet DOPE ausschließlich aus vollständigen, expliziten Eingaben. parameters_json folgt dem Eingabeschema des KI-Stack Ballistics Pack."""
        try:
            data = json.loads(parameters_json)
            result = calculate_trajectory(data)
            if output_format == "csv":
                return render_csv(result) + "\n" + NOTICE
            if output_format == "json":
                return json.dumps(result, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            if output_format == "card":
                rows = result["calculated_rows"]
                return "\n".join(f"{r['range']} {r['range_unit']}: ↑ {r['elevation_mrad']} MRAD / → {r['wind_mrad']} MRAD" for r in rows) + "\n\n" + NOTICE
            return render_table(result)
        except Exception as exc:
            return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)

    def chronograph_summary(self, velocities_json: str, velocity_unit: Literal["m/s", "fps"], temperature: float, lot_number: str = "") -> str:
        """Vergleicht synthetische oder gemessene Chronographenwerte, verändert aber kein Profil."""
        try:
            values = [_finite("velocity", v, positive=True) for v in json.loads(velocities_json)]
            if len(values) < 2:
                raise ValueError("Mindestens zwei Messwerte erforderlich.")
            result = {"count": len(values), "mean": statistics.fmean(values), "standard_deviation": statistics.stdev(values), "extreme_spread": max(values) - min(values), "velocity_unit": velocity_unit, "temperature": temperature, "lot_number": lot_number, "profile_changed": False}
            return json.dumps(result, ensure_ascii=False, allow_nan=False)
        except Exception as exc:
            return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)

    def compare_impact_data(self, observed_json: str, calculated_json: str) -> str:
        """Erzeugt eine dokumentierte Differenz, ohne BC oder Mündungsgeschwindigkeit automatisch zu ändern."""
        try:
            observed, calculated = json.loads(observed_json), json.loads(calculated_json)
            result = {"vertical_difference": float(observed["vertical"]) - float(calculated["vertical"]), "horizontal_difference": float(observed["horizontal"]) - float(calculated["horizontal"]), "suggestion": "Abweichung prüfen; Profiländerung nur nach ausdrücklicher Bestätigung.", "profile_changed": False}
            return json.dumps(result, ensure_ascii=False, allow_nan=False)
        except Exception as exc:
            return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)

    def save_profile(self, profile_name: str, profile_json: str, confirmed: bool = False) -> str:
        """Speichert ein lokales Profil ausschließlich nach ausdrücklicher Bestätigung."""
        if not confirmed:
            return json.dumps({"ok": False, "saved": False, "error": "Ausdrückliche Bestätigung erforderlich."}, ensure_ascii=False)
        if not profile_name or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for ch in profile_name):
            return json.dumps({"ok": False, "saved": False, "error": "Ungültiger Profilname."}, ensure_ascii=False)
        try:
            profile = json.loads(profile_json)
            root = Path(os.environ.get("KI_STACK_BALLISTICS_DATA", r"C:\KI-Stack\data\ballistics")) / "profiles"
            root.mkdir(parents=True, exist_ok=True)
            path = root / f"{profile_name}.json"
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps({"schema_version": "1.0.0", "profile_name": profile_name, "data": profile}, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(temporary, path)
            return json.dumps({"ok": True, "saved": True, "profile_name": profile_name}, ensure_ascii=False)
        except Exception as exc:
            return json.dumps({"ok": False, "saved": False, "error": str(exc)}, ensure_ascii=False)

    def load_profile(self, profile_name: str) -> str:
        """Liest ein bestätigtes lokales Profil zurück."""
        if not profile_name or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for ch in profile_name):
            return json.dumps({"ok": False, "error": "Ungültiger Profilname."}, ensure_ascii=False)
        path = Path(os.environ.get("KI_STACK_BALLISTICS_DATA", r"C:\KI-Stack\data\ballistics")) / "profiles" / f"{profile_name}.json"
        if not path.is_file():
            return json.dumps({"ok": False, "error": "Profil nicht gefunden."}, ensure_ascii=False)
        return path.read_text(encoding="utf-8")
