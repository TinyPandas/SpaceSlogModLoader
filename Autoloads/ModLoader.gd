# ModLoader — internal singleton, not called by modders directly.
# Handles discovery, validation, script registration, and lifecycle orchestration
# for GDScript mods.

extends Node

## Helper scripts — loaded at runtime in _ready() because preload() of loose
## .gd files from override.cfg crashes the engine in exported builds.
var _ModManifest: GDScript
var _ModContext: GDScript
var _ScriptRegistry: GDScript
var _SpaceslogMod: GDScript
var _UpdateChecker: GDScript
var _ModConfigManager: GDScript
var _ConfigUIInjector: GDScript

## Update checker instance (child node)
var _update_checker: Node = null
## Config manager instance
var _config_manager = null
## Config UI injector instance
var _config_ui_injector = null
## Reference to the InfoContainer in the Modules tab
var _info_container: VBoxContainer = null
## Maps mod display names to mod_ids for config panel selection
var _mod_name_to_id: Dictionary = {}
## Tracks the last detected mod name in the InfoContainer to detect selection changes
var _last_info_mod_name: String = ""

## Emitted after all mods have completed all lifecycle phases.
signal all_mods_loaded

## Internal state
var _discovered_mods: Array = []
var _loaded_mods: Array = []
var _failed_mods: Array[String] = []
var _mod_data_entries: Dictionary = {}
var _mod_scripts: Dictionary = {}
var _mod_states: Dictionary = {}
var _ui_label: Label = null
var _data_mod_count: int = 0
var _pipeline_ran: bool = false
var _last_enabled_mods: Array = []

const LOG_TAG: String = "[ModLoader]"
const VERSION: String = "1.1.2"

enum ModState {
	DISCOVERED,
	VALIDATED,
	SCRIPTS_REGISTERED,
	INITIALIZED,
	REGISTERED,
	PATCHED,
	READY,
	FAILED
}


func _ready() -> void:
	# Load helper scripts at runtime
	var base := OS.get_executable_path().get_base_dir()
	_ModManifest = _load_script(base.path_join("Autoloads/ModLoader/ModManifest.gd"))
	_ModContext = _load_script(base.path_join("Autoloads/ModLoader/ModContext.gd"))
	_ScriptRegistry = _load_script(base.path_join("Autoloads/ModLoader/ScriptRegistry.gd"))
	_SpaceslogMod = _load_script(base.path_join("Autoloads/ModdingAPI/SpaceslogMod.gd"))
	_UpdateChecker = _load_script(base.path_join("Autoloads/ModLoader/UpdateChecker.gd"))
	_ModConfigManager = _load_script(base.path_join("Autoloads/ModLoader/ModConfigManager.gd"))
	_ConfigUIInjector = _load_script(base.path_join("Autoloads/ModLoader/ConfigUIInjector.gd"))

	if not _ModManifest or not _ModContext or not _ScriptRegistry or not _SpaceslogMod:
		push_error("%s Failed to load one or more helper scripts — aborting" % LOG_TAG)
		return

	print("%s Helper scripts loaded successfully" % LOG_TAG)

	# Start update check (runs in background, independent of mod pipeline)
	if _UpdateChecker:
		_update_checker = _UpdateChecker.new()
		_update_checker.current_version = VERSION
		add_child(_update_checker)
		_update_checker.check_for_update()
		print("%s Update checker started" % LOG_TAG)
	else:
		push_warning("%s UpdateChecker script not found — skipping update check" % LOG_TAG)

	_await_data_and_load()
	set_process(true)


## Loads a .gd file from disk, compiles it, and returns the GDScript resource.
func _load_script(disk_path: String) -> GDScript:
	if not FileAccess.file_exists(disk_path):
		push_error("%s Helper script not found: %s" % [LOG_TAG, disk_path])
		return null
	var file := FileAccess.open(disk_path, FileAccess.READ)
	if not file:
		push_error("%s Cannot open helper script: %s" % [LOG_TAG, disk_path])
		return null
	var source := file.get_as_text()
	file.close()
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		push_error("%s Helper script compile failed: %s (error %d)" % [LOG_TAG, disk_path, err])
		return null
	return script


func _await_data_and_load() -> void:
	if not Data.tasks.is_empty():
		_run_pipeline()
	else:
		call_deferred("_await_data_and_load")


func _process(_delta: float) -> void:
	if not _pipeline_ran and not Data.tasks.is_empty():
		# Initial run or post-reload with data ready
		_run_pipeline()
		return

	if _pipeline_ran:
		# Check if the enabled mods list changed (player toggled mods and reloaded)
		var current_mods: Array = _get_enabled_mods_snapshot()
		if current_mods != _last_enabled_mods:
			print("%s Enabled mods changed — re-running pipeline" % LOG_TAG)
			# Clean up all previously registered data entries from Data singleton
			for mod_id in _mod_data_entries.keys():
				for entry in _mod_data_entries[mod_id]:
					_remove_data_entry(entry.category, entry.key)
				# Also undo reasoner patches
				for patch in ModdingAPI.get_tracked_patches(mod_id):
					_remove_reasoner_patch(patch.reasoner_key, patch.option_key)
			_pipeline_ran = false
			_loaded_mods.clear()
			_failed_mods.clear()
			_mod_states.clear()
			_mod_data_entries.clear()
			ModdingAPI.clear_all_tracked_entries()
			if _config_manager:
				_config_manager.clear_all()

	# Poll for mod selection changes in the Modules tab
	_check_mod_selection()


func _get_enabled_mods_snapshot() -> Array:
	if not is_instance_valid(PlayerSettings) or not PlayerSettings.has_method("get_mods"):
		return []
	return PlayerSettings.get_mods().duplicate()


func _run_pipeline() -> void:
	print("%s Starting mod loading pipeline..." % LOG_TAG)

	var mods := _discover_mods()
	var valid_mods := _validate_and_sort(mods)

	if _ModConfigManager:
		_load_configs(valid_mods)

	# Instantiate the UI injector if configs are available
	if _ConfigUIInjector and _config_ui_injector == null:
		_config_ui_injector = _ConfigUIInjector.new()
		_config_ui_injector._config_manager = _config_manager

	for manifest in valid_mods:
		if _is_mod_enabled(manifest.mod_id):
			_load_single_mod(manifest)

	for mod in _loaded_mods:
		if _mod_states.get(mod.context.mod_id) == ModState.FAILED:
			continue
		mod._on_mod_register(ModdingAPI)
		_mod_states[mod.context.mod_id] = ModState.REGISTERED

	for mod in _loaded_mods:
		var mod_id: String = mod.context.mod_id
		_mod_data_entries[mod_id] = ModdingAPI.get_tracked_entries(mod_id)

	for mod in _loaded_mods:
		if _mod_states.get(mod.context.mod_id) == ModState.FAILED:
			continue
		mod._on_mod_patch(ModdingAPI)
		_mod_states[mod.context.mod_id] = ModState.PATCHED

	for mod in _loaded_mods:
		if _mod_states.get(mod.context.mod_id) == ModState.FAILED:
			continue
		mod._on_mod_ready()
		_mod_states[mod.context.mod_id] = ModState.READY

	_log_summary()
	_update_ui_display()
	_pipeline_ran = true
	_last_enabled_mods = _get_enabled_mods_snapshot()
	all_mods_loaded.emit()


func _load_configs(valid_mods: Array) -> void:
	if _config_manager == null:
		_config_manager = _ModConfigManager.new()
	ModdingAPI._config_manager = _config_manager
	for manifest in valid_mods:
		if _is_mod_enabled(manifest.mod_id):
			# Build name-to-id map for config UI selection
			_mod_name_to_id[manifest.mod_name] = manifest.mod_id
			var loaded: bool = _config_manager.load_config(manifest.mod_id, manifest.mod_folder)
			if loaded:
				print("%s [%s] Config loaded" % [LOG_TAG, manifest.mod_id])
			else:
				print("%s [%s] No config file found at: %s" % [LOG_TAG, manifest.mod_id, manifest.mod_folder.path_join(manifest.mod_id + ".cfg")])


func _discover_mods() -> Array:
	var mods: Array = []
	_data_mod_count = 0
	var base_dir: String = OS.get_executable_path().get_base_dir()

	var local_mods_path: String = base_dir.path_join("Modules")
	_scan_directory(local_mods_path, mods)

	var steamapps_dir: String = base_dir.get_base_dir().get_base_dir()
	var workshop_path: String = steamapps_dir.path_join("workshop/content/2133570")
	_scan_directory(workshop_path, mods)

	print("%s Discovered %d GDScript mod(s)" % [LOG_TAG, mods.size()])
	return mods


func _scan_directory(dir_path: String, mods: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return

	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and not folder_name.begins_with("."):
			var folder_path: String = dir_path.path_join(folder_name)
			var json_path: String = folder_path.path_join("Mod_Info.json")

			if FileAccess.file_exists(json_path):
				var json_text: String = FileAccess.get_file_as_string(json_path)
				var json := JSON.new()
				var err := json.parse(json_text)
				if err != OK:
					push_warning("%s Invalid JSON in '%s': %s" % [LOG_TAG, json_path, json.get_error_message()])
				else:
					var data: Dictionary = json.data
					if _ModManifest.is_gdscript_mod(data):
						var manifest = _ModManifest.new()
						if manifest.parse_json(data, folder_path):
							mods.append(manifest)
					elif data.has("mod_id"):
						var data_mod_id = str(data["mod_id"])
						if _is_mod_enabled(data_mod_id):
							_data_mod_count += 1
		folder_name = dir.get_next()
	dir.list_dir_end()


func _validate_and_sort(mods: Array) -> Array:
	var available_ids: Dictionary = {}
	for manifest in mods:
		available_ids[manifest.mod_id] = true

	var valid_mods: Array = []
	for manifest in mods:
		# Check ModLoader version requirement
		if not manifest.min_modloader_version.is_empty():
			if _is_version_newer(manifest.min_modloader_version, VERSION):
				push_warning("%s Mod '%s' requires ModLoader v%s (installed: v%s) — skipping" % [LOG_TAG, manifest.mod_id, manifest.min_modloader_version, VERSION])
				_failed_mods.append(manifest.mod_id)
				continue

		var deps_ok: bool = true
		for dep_id in manifest.dependencies:
			if not available_ids.has(dep_id):
				push_error("%s Mod '%s' requires missing dependency: %s — skipping" % [LOG_TAG, manifest.mod_id, dep_id])
				deps_ok = false
				break
		if deps_ok:
			valid_mods.append(manifest)

	valid_mods.sort_custom(_compare_manifests)
	print("%s Validated %d mod(s), %d skipped" % [LOG_TAG, valid_mods.size(), mods.size() - valid_mods.size()])
	return valid_mods


static func _compare_manifests(a, b) -> bool:
	if a.load_order != b.load_order:
		return a.load_order < b.load_order
	return a.mod_id < b.mod_id


func _load_single_mod(manifest) -> void:
	_mod_states[manifest.mod_id] = ModState.DISCOVERED

	if not _register_scripts(manifest):
		push_error("%s [%s] Script registration failed — some scripts may not work" % [LOG_TAG, manifest.mod_id])
	_mod_states[manifest.mod_id] = ModState.SCRIPTS_REGISTERED

	var entry_disk_path: String = manifest.mod_folder.path_join(manifest.entry_script)
	if not FileAccess.file_exists(entry_disk_path):
		push_error("%s [%s] Entry script not found: %s" % [LOG_TAG, manifest.mod_id, entry_disk_path])
		_mod_states[manifest.mod_id] = ModState.FAILED
		_failed_mods.append(manifest.mod_id)
		return

	var file := FileAccess.open(entry_disk_path, FileAccess.READ)
	if not file:
		push_error("%s [%s] Cannot open entry script: %s" % [LOG_TAG, manifest.mod_id, entry_disk_path])
		_mod_states[manifest.mod_id] = ModState.FAILED
		_failed_mods.append(manifest.mod_id)
		return

	var source := file.get_as_text()
	file.close()

	# Rewrite "extends SpaceslogMod" — the class_name isn't globally registered
	# for loose scripts loaded via override.cfg, so we inject the base class fields
	if "extends SpaceslogMod" in source:
		source = source.replace("extends SpaceslogMod", "extends Node")
		# Inject the context variable that SpaceslogMod normally provides
		# Insert it right after the extends line
		var lines: PackedStringArray = source.split("\n")
		var new_lines: PackedStringArray = PackedStringArray()
		var injected: bool = false
		for line in lines:
			new_lines.append(line)
			if not injected and line.strip_edges() == "extends Node":
				new_lines.append("var context")
				injected = true
		source = "\n".join(new_lines)

	var entry_script := GDScript.new()
	entry_script.source_code = source
	var err := entry_script.reload()
	if err != OK:
		push_error("%s [%s] Entry script compile failed: %s (error %d)" % [LOG_TAG, manifest.mod_id, entry_disk_path, err])
		_mod_states[manifest.mod_id] = ModState.FAILED
		_failed_mods.append(manifest.mod_id)
		return

	var mod_instance = entry_script.new()
	if not mod_instance is Node:
		push_error("%s [%s] Entry script does not extend Node" % [LOG_TAG, manifest.mod_id])
		_mod_states[manifest.mod_id] = ModState.FAILED
		_failed_mods.append(manifest.mod_id)
		return

	var context = _ModContext.new()
	context.mod_id = manifest.mod_id
	context.mod_name = manifest.mod_name
	context.mod_folder = manifest.mod_folder

	mod_instance.context = context
	if mod_instance.has_method("_on_mod_init"):
		mod_instance._on_mod_init(context)
	_mod_states[manifest.mod_id] = ModState.INITIALIZED

	_loaded_mods.append(mod_instance)
	add_child(mod_instance)
	print("%s [%s] Mod initialized successfully" % [LOG_TAG, manifest.mod_id])


func _register_scripts(manifest) -> bool:
	var all_ok: bool = true
	var registered_paths: Array[String] = []

	for entry in manifest.scripts:
		var disk_path: String = manifest.mod_folder.path_join(entry["path"])
		var res_path: String = entry["res_path"]

		if _ScriptRegistry.register_script(disk_path, res_path, manifest.mod_id):
			registered_paths.append(res_path)
		else:
			all_ok = false

	_mod_scripts[manifest.mod_id] = registered_paths
	return all_ok


func _is_mod_enabled(mod_id: String) -> bool:
	if not is_instance_valid(PlayerSettings):
		push_warning("%s PlayerSettings not available — defaulting mod '%s' to enabled" % [LOG_TAG, mod_id])
		return true
	if not PlayerSettings.has_method("get_mods"):
		push_warning("%s PlayerSettings.get_mods() not found — defaulting mod '%s' to enabled" % [LOG_TAG, mod_id])
		return true
	var selected_mods: Array = PlayerSettings.get_mods()
	return selected_mods.has(mod_id) or selected_mods.has(StringName(mod_id))


func _log_summary() -> void:
	var loaded_count := _loaded_mods.size()
	var failed_count := _failed_mods.size()
	print("%s ═══════════════════════════════════════" % LOG_TAG)
	print("%s Pipeline complete: %d mod(s) loaded, %d failed" % [LOG_TAG, loaded_count, failed_count])
	if failed_count > 0:
		print("%s Failed mods: %s" % [LOG_TAG, ", ".join(_failed_mods)])
	print("%s ═══════════════════════════════════════" % LOG_TAG)


func _update_ui_display() -> void:
	print("%s %s" % [LOG_TAG, get_version_string()])
	# If we have a valid label reference, update it directly
	if is_instance_valid(_ui_label):
		call_deferred("_append_version_text")
	# Also ensure we're listening for new GameVersion labels (after reload)
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node.name == "GameVersion" and node is Label:
		# Store reference and append our text on the next frame
		# (after the game sets the version text in _ready)
		_ui_label = node
		node.tree_exiting.connect(_on_version_label_removed)
		call_deferred("_append_version_text")

	# Config UI: store InfoContainer reference if detected via node_added
	if _config_ui_injector and node.name == "InfoContainer" and node is VBoxContainer:
		_info_container = node


func _append_version_text() -> void:
	if is_instance_valid(_ui_label):
		var version_str := get_version_string()
		# Replace existing ModLoader line if present, otherwise append
		if "ModLoader" in _ui_label.text:
			var lines: PackedStringArray = _ui_label.text.split("\n")
			var new_lines: PackedStringArray = PackedStringArray()
			for line in lines:
				if "ModLoader" not in line:
					new_lines.append(line)
			new_lines.append(version_str)
			_ui_label.text = "\n".join(new_lines)
		else:
			_ui_label.text += "\n" + version_str
		print("%s Version text updated on GameVersion label" % LOG_TAG)


func _on_version_label_removed() -> void:
	# The scene is being rebuilt (hot-reload) — reset so we re-attach
	_ui_label = null
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


## Polls the InfoContainer for mod selection changes by checking the mod name label.
func _check_mod_selection() -> void:
	if not _config_ui_injector or not _config_manager:
		return

	# Lazily find InfoContainer if we haven't yet
	if not is_instance_valid(_info_container):
		_info_container = null
		var root := get_tree().root
		var found := _find_node_by_name(root, "InfoContainer")
		if found and found is VBoxContainer:
			_info_container = found
		else:
			return

	# Find the mod name from the InfoContainer's content.
	var current_mod_name: String = _detect_mod_name_from_info()
	if current_mod_name == _last_info_mod_name:
		return  # No change

	_last_info_mod_name = current_mod_name

	# Remove any existing config panel
	for child in _info_container.get_children():
		if child.name == "ConfigPanel":
			_info_container.remove_child(child)
			child.queue_free()

	if current_mod_name.is_empty():
		return

	# Look up the mod_id from the display name
	var mod_id: String = _mod_name_to_id.get(current_mod_name, "")
	if mod_id.is_empty():
		return

	# Check if this mod has config entries
	var config_entries: Dictionary = _config_manager.get_config_entries(mod_id)
	if config_entries.is_empty():
		return

	var panel = _config_ui_injector.build_config_panel(mod_id, config_entries)
	if panel != null:
		_info_container.add_child(panel)
		print("%s Config UI: Showing config for '%s'" % [LOG_TAG, mod_id])


## Recursively finds a node by name in the scene tree.
func _find_node_by_name(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var result := _find_node_by_name(child, target_name)
		if result:
			return result
	return null


## Searches the InfoContainer for a Label whose text matches a known mod name.
func _detect_mod_name_from_info() -> String:
	if not is_instance_valid(_info_container):
		return ""
	return _search_labels_recursive(_info_container, 4)


## Recursively searches for a Label matching a known mod name, up to max_depth levels.
func _search_labels_recursive(node: Node, max_depth: int) -> String:
	if max_depth <= 0:
		return ""
	for child in node.get_children():
		if child.name == "ConfigPanel":
			continue  # Skip our own injected panel
		if child is Label:
			var text: String = child.text.strip_edges()
			if _mod_name_to_id.has(text):
				return text
		var result: String = _search_labels_recursive(child, max_depth - 1)
		if not result.is_empty():
			return result
	return ""


func _find_version_label(node: Node):
	if node is Label:
		var text: String = node.text
		if "Early Access" in text or "Version" in text:
			return node
	for child in node.get_children():
		var result = _find_version_label(child)
		if result:
			return result
	return null


func get_module_info() -> Dictionary:
	return {
		"mod_name": "ModLoader",
		"mod_id": "spaceslog.modloader",
		"mod_author": "SpaceSlog ModLoader",
		"mod_description": "GDScript mod loading system — %d mods loaded" % _loaded_mods.size(),
		"mod_version": VERSION,
		"is_always_enabled": true,
	}


func _reload() -> void:
	# Called externally or can be triggered manually
	print("%s Reloading mod pipeline..." % LOG_TAG)
	_pipeline_ran = false
	_loaded_mods.clear()
	_failed_mods.clear()
	_mod_states.clear()
	_mod_data_entries.clear()
	ModdingAPI.clear_all_tracked_entries()
	if _config_manager:
		_config_manager.clear_all()
	_run_pipeline()


func _cleanup_disabled_mods() -> void:
	var mods_to_clean: Array[String] = []
	for mod_id in _mod_data_entries.keys():
		if not _is_mod_enabled(mod_id):
			mods_to_clean.append(mod_id)

	for mod_id in mods_to_clean:
		print("%s Cleaning up disabled mod: %s" % [LOG_TAG, mod_id])
		for entry in _mod_data_entries[mod_id]:
			_remove_data_entry(entry.category, entry.key)
		_mod_data_entries.erase(mod_id)
		if _mod_scripts.has(mod_id):
			_mod_scripts.erase(mod_id)
		if _config_manager:
			_config_manager.clear_mod(mod_id)


func _remove_data_entry(category: String, key: StringName) -> void:
	if not ModdingAPI.CATEGORY_MAP.has(category):
		push_warning("%s Cannot remove entry — invalid category: %s" % [LOG_TAG, category])
		return
	var dict_name: String = ModdingAPI.CATEGORY_MAP[category].dict_name
	var data_dict: Dictionary = Data[dict_name]
	if data_dict.has(key):
		data_dict.erase(key)
	else:
		push_warning("%s Entry not found for removal — %s: %s" % [LOG_TAG, category, key])


func _remove_reasoner_patch(reasoner_key: StringName, option_key: StringName) -> void:
	if not Data.pawn_reasoners.has(reasoner_key):
		return
	var reasoner = Data.pawn_reasoners[reasoner_key]
	var idx: int = reasoner.pawn_options.find(option_key)
	if idx >= 0:
		reasoner.pawn_options.remove_at(idx)


func get_version_string() -> String:
	var script_count := _loaded_mods.size()
	var failed_count := _failed_mods.size()
	var total := _data_mod_count + script_count
	var base := "ModLoader v%s | %d mods loaded (%d data, %d script)" % [VERSION, total, _data_mod_count, script_count]
	if failed_count > 0:
		base += ", %d failed" % failed_count
	return base


## Returns true if version `a` is strictly newer than version `b` (semver comparison).
static func _is_version_newer(a: String, b: String) -> bool:
	var pa: Array = _parse_semver(a)
	var pb: Array = _parse_semver(b)
	for i in range(3):
		if pa[i] > pb[i]:
			return true
		if pa[i] < pb[i]:
			return false
	return false


## Parses a version string into [major, minor, patch]. Strips leading "v".
static func _parse_semver(version: String) -> Array:
	version = version.strip_edges()
	if version.begins_with("v") or version.begins_with("V"):
		version = version.substr(1)
	# Strip any pre-release suffix (e.g., "1.1.2_pre" -> "1.1.2")
	var underscore := version.find("_")
	if underscore >= 0:
		version = version.substr(0, underscore)
	var dash := version.find("-")
	if dash >= 0:
		version = version.substr(0, dash)
	var parts: PackedStringArray = version.split(".")
	var result: Array = [0, 0, 0]
	for i in range(mini(parts.size(), 3)):
		result[i] = parts[i].to_int()
	return result
