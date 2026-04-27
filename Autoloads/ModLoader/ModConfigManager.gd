extends RefCounted

## ModConfigManager — Internal component responsible for parsing, validating,
## persisting, and distributing configuration values for all loaded mods.
## Loaded at runtime by ModLoader via _load_script().

signal config_value_changed(mod_id: String, value_name: String, new_value: Variant)

const LOG_TAG: String = "[ModConfigManager]"
const VALID_TYPES: Array[String] = ["bool", "int", "float", "string"]

## mod_id -> {value_name -> {type, defaultValue, currentValue, minValue, maxValue}}
var _configs: Dictionary = {}

## mod_id -> mod_folder (needed for persistence)
var _mod_folders: Dictionary = {}

## Array of {mod_id, value_name, target: WeakRef, property: String}
var _bindings: Array = []


# ─── Public Interface ─────────────────────────────────────────────


## Parses a {mod_id}.cfg file from the mod folder. Returns true if config was
## found and loaded (even partially), false if no config file exists or on failure.
func load_config(mod_id: String, mod_folder: String) -> bool:
	var path: String = mod_folder.path_join(mod_id + ".cfg")

	if not FileAccess.file_exists(path):
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("%s [%s] Cannot open config file: %s" % [LOG_TAG, mod_id, path])
		return false

	var json_text: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		push_error("%s [%s] Config parse failed: %s (line %d)" % [LOG_TAG, mod_id, json.get_error_message(), json.get_error_line()])
		return false

	var data = json.data
	if not data is Dictionary:
		push_error("%s [%s] Config root must be a Dictionary" % [LOG_TAG, mod_id])
		return false

	var entries: Dictionary = {}
	for entry_name in data.keys():
		var entry_dict = data[entry_name]
		if not entry_dict is Dictionary:
			push_warning("%s [%s] Entry '%s' is not a Dictionary — skipping" % [LOG_TAG, mod_id, entry_name])
			continue
		var parsed = _parse_entry(entry_name, entry_dict, mod_id)
		if parsed != null:
			entries[entry_name] = parsed

	if entries.is_empty():
		return false

	_configs[mod_id] = entries
	_mod_folders[mod_id] = mod_folder
	return true


## Returns the current value for a config entry, or null if not found.
func get_value(mod_id: String, value_name: String) -> Variant:
	if not _configs.has(mod_id):
		push_warning("%s [%s] No config loaded for mod" % [LOG_TAG, mod_id])
		return null
	if not _configs[mod_id].has(value_name):
		push_warning("%s [%s] Config entry '%s' not found" % [LOG_TAG, mod_id, value_name])
		return null
	return _configs[mod_id][value_name]["currentValue"]


## Returns a Dictionary of {value_name: current_value} for all entries of a mod.
func get_all_values(mod_id: String) -> Dictionary:
	if not _configs.has(mod_id):
		return {}
	var result: Dictionary = {}
	for value_name in _configs[mod_id].keys():
		result[value_name] = _configs[mod_id][value_name]["currentValue"]
	return result


## Returns the default value for a config entry, or null if not found.
func get_default_value(mod_id: String, value_name: String) -> Variant:
	if not _configs.has(mod_id):
		push_warning("%s [%s] No config loaded for mod" % [LOG_TAG, mod_id])
		return null
	if not _configs[mod_id].has(value_name):
		push_warning("%s [%s] Config entry '%s' not found" % [LOG_TAG, mod_id, value_name])
		return null
	return _configs[mod_id][value_name]["defaultValue"]


## Returns the full config entry dictionary for a mod (used by UI).
func get_config_entries(mod_id: String) -> Dictionary:
	if not _configs.has(mod_id):
		return {}
	return _configs[mod_id]


## Updates a config value. Validates type, updates in-memory, persists to disk,
## emits config_value_changed signal. Returns true on success.
func set_value(mod_id: String, value_name: String, new_value: Variant) -> bool:
	if not _configs.has(mod_id):
		push_warning("%s [%s] No config loaded for mod" % [LOG_TAG, mod_id])
		return false
	if not _configs[mod_id].has(value_name):
		push_warning("%s [%s] Config entry '%s' not found" % [LOG_TAG, mod_id, value_name])
		return false

	var entry: Dictionary = _configs[mod_id][value_name]
	var validated = _validate_value(new_value, entry["type"], entry["minValue"], entry["maxValue"])
	if validated == null:
		push_warning("%s [%s] Value rejected for '%s': expected type '%s', got %s" % [LOG_TAG, mod_id, value_name, entry["type"], str(new_value)])
		return false

	# Update in-memory BEFORE emitting signal
	_configs[mod_id][value_name]["currentValue"] = validated

	# Persist to disk
	_persist_config(mod_id)

	# Emit signal
	config_value_changed.emit(mod_id, value_name, validated)

	# Update bindings
	_update_bindings(mod_id, value_name, validated)

	return true


## Resets all config entries for a mod to their default values.
func reset_to_defaults(mod_id: String) -> void:
	if not _configs.has(mod_id):
		return

	var changed_entries: Array = []
	for value_name in _configs[mod_id].keys():
		var entry: Dictionary = _configs[mod_id][value_name]
		if entry["currentValue"] != entry["defaultValue"]:
			entry["currentValue"] = entry["defaultValue"]
			changed_entries.append(value_name)

	if changed_entries.is_empty():
		return

	_persist_config(mod_id)

	for value_name in changed_entries:
		var new_value = _configs[mod_id][value_name]["currentValue"]
		config_value_changed.emit(mod_id, value_name, new_value)
		_update_bindings(mod_id, value_name, new_value)


## Binds a config value to a target object's property.
func bind(mod_id: String, value_name: String, target: Object, property: String) -> bool:
	if not _configs.has(mod_id) or not _configs[mod_id].has(value_name):
		push_warning("%s [%s] Cannot bind — config entry '%s' not found" % [LOG_TAG, mod_id, value_name])
		return false

	var binding: Dictionary = {
		"mod_id": mod_id,
		"value_name": value_name,
		"target": weakref(target),
		"property": property
	}
	_bindings.append(binding)

	# Immediately set the property to the current value
	target.set(property, _configs[mod_id][value_name]["currentValue"])
	return true


## Removes a previously created binding.
func unbind(mod_id: String, value_name: String, target: Object, property: String) -> void:
	for i in range(_bindings.size() - 1, -1, -1):
		var b: Dictionary = _bindings[i]
		if b["mod_id"] == mod_id and b["value_name"] == value_name and b["property"] == property:
			var ref = b["target"].get_ref()
			if ref == target:
				_bindings.remove_at(i)
				return


## Removes all config data and bindings for a mod.
func clear_mod(mod_id: String) -> void:
	_configs.erase(mod_id)
	_mod_folders.erase(mod_id)
	# Remove all bindings for this mod
	for i in range(_bindings.size() - 1, -1, -1):
		if _bindings[i]["mod_id"] == mod_id:
			_bindings.remove_at(i)


## Removes all config data and bindings.
func clear_all() -> void:
	_configs.clear()
	_mod_folders.clear()
	_bindings.clear()


# ─── Internal ─────────────────────────────────────────────────────


## Validates that a value matches the declared type. Returns the coerced value
## on success, or null on failure. Applies range clamping if min/max are set.
func _validate_value(value: Variant, declared_type: String, min_value: Variant = null, max_value: Variant = null) -> Variant:
	var result: Variant = null

	match declared_type:
		"bool":
			if value is bool:
				result = value
			else:
				return null
		"int":
			if value is int:
				result = value
			elif value is float:
				# Accept floats with no fractional part
				if value == float(int(value)):
					result = int(value)
				else:
					return null
			else:
				return null
		"float":
			if value is float:
				result = value
			elif value is int:
				result = float(value)
			else:
				return null
		"string":
			if value is String:
				result = value
			else:
				return null
		_:
			return null

	# Apply range clamping for numeric types
	if declared_type == "int" or declared_type == "float":
		if min_value != null and max_value != null:
			result = clamp(result, min_value, max_value)
		elif min_value != null:
			result = max(result, min_value)
		elif max_value != null:
			result = min(result, max_value)

	return result


## Parses a single config entry from JSON. Returns null if invalid.
func _parse_entry(entry_name: String, entry_dict: Dictionary, mod_id: String) -> Variant:
	# Validate required fields
	if not entry_dict.has("type"):
		push_warning("%s [%s] Entry '%s' missing 'type' field — skipping" % [LOG_TAG, mod_id, entry_name])
		return null
	if not entry_dict.has("defaultValue"):
		push_warning("%s [%s] Entry '%s' missing 'defaultValue' field — skipping" % [LOG_TAG, mod_id, entry_name])
		return null

	var type_str: String = str(entry_dict["type"])

	# Validate type is supported
	if type_str not in VALID_TYPES:
		push_warning("%s [%s] Entry '%s' has unsupported type '%s' — skipping" % [LOG_TAG, mod_id, entry_name, type_str])
		return null

	# Parse optional minValue/maxValue
	var min_value: Variant = null
	var max_value: Variant = null

	if entry_dict.has("minValue") or entry_dict.has("maxValue"):
		if type_str == "bool" or type_str == "string":
			push_warning("%s [%s] Entry '%s': minValue/maxValue ignored for type '%s'" % [LOG_TAG, mod_id, entry_name, type_str])
		else:
			if entry_dict.has("minValue"):
				min_value = entry_dict["minValue"]
			if entry_dict.has("maxValue"):
				max_value = entry_dict["maxValue"]

			# Validate minValue <= maxValue when both present
			if min_value != null and max_value != null:
				if min_value > max_value:
					push_warning("%s [%s] Entry '%s': minValue (%s) > maxValue (%s) — skipping" % [LOG_TAG, mod_id, entry_name, str(min_value), str(max_value)])
					return null

	# Validate defaultValue matches declared type
	var validated_default = _validate_value(entry_dict["defaultValue"], type_str, min_value, max_value)
	if validated_default == null:
		push_warning("%s [%s] Entry '%s': defaultValue does not match type '%s' — skipping" % [LOG_TAG, mod_id, entry_name, type_str])
		return null

	# Parse currentValue
	var current_value: Variant = validated_default
	if entry_dict.has("currentValue"):
		var validated_current = _validate_value(entry_dict["currentValue"], type_str, min_value, max_value)
		if validated_current == null:
			push_warning("%s [%s] Entry '%s': currentValue type mismatch, falling back to defaultValue" % [LOG_TAG, mod_id, entry_name])
			current_value = validated_default
		else:
			current_value = validated_current

	return {
		"type": type_str,
		"defaultValue": validated_default,
		"currentValue": current_value,
		"minValue": min_value,
		"maxValue": max_value
	}


## Writes the config dictionary back to the {mod_id}.cfg file on disk.
func _persist_config(mod_id: String) -> bool:
	if not _configs.has(mod_id) or not _mod_folders.has(mod_id):
		return false

	var output: Dictionary = {}
	for value_name in _configs[mod_id].keys():
		var entry: Dictionary = _configs[mod_id][value_name]
		var entry_out: Dictionary = {
			"type": entry["type"],
			"defaultValue": entry["defaultValue"],
			"currentValue": entry["currentValue"]
		}
		if entry["minValue"] != null:
			entry_out["minValue"] = entry["minValue"]
		if entry["maxValue"] != null:
			entry_out["maxValue"] = entry["maxValue"]
		output[value_name] = entry_out

	var json_string: String = JSON.stringify(output, "\t")
	var path: String = _mod_folders[mod_id].path_join(mod_id + ".cfg")

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("%s [%s] Failed to write config file: %s (error %d)" % [LOG_TAG, mod_id, path, FileAccess.get_open_error()])
		return false

	file.store_string(json_string)
	file.close()
	return true


## Updates all bindings matching the given mod_id and value_name.
func _update_bindings(mod_id: String, value_name: String, new_value: Variant) -> void:
	for i in range(_bindings.size() - 1, -1, -1):
		var binding: Dictionary = _bindings[i]
		if binding["mod_id"] != mod_id or binding["value_name"] != value_name:
			continue
		var target = binding["target"].get_ref()
		if target == null:
			print("%s Binding target freed — removing binding for '%s.%s'" % [LOG_TAG, mod_id, value_name])
			_bindings.remove_at(i)
		else:
			target.set(binding["property"], new_value)
