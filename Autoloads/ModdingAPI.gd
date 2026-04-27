extends Node

## ModdingAPI — Public singleton providing typed registration and patching methods
## for modders to add or modify game content without directly manipulating Data.*
## dictionaries or constructing Ref objects manually.

const LOG_TAG: String = "[ModdingAPI]"

## Tracks registered entries per mod for reload cleanup
var _tracked_entries: Dictionary = {}  # mod_id -> Array of {category: String, key: StringName}
## Tracks reasoner patches per mod for reload cleanup
var _tracked_patches: Dictionary = {}  # mod_id -> Array of {reasoner_key: StringName, option_key: StringName}

## Maps category strings to their Data singleton dictionary names and Ref class names.
const CATEGORY_MAP: Dictionary = {
	"tasks": {dict_name = "tasks", ref_class = "TaskRef"},
	"task_driver": {dict_name = "task_driver", ref_class = "TaskDriverRef"},
	"pawn_considerations": {dict_name = "pawn_considerations", ref_class = "ConsiderationRef"},
	"pawn_options": {dict_name = "pawn_options", ref_class = "OptionRef"},
	"pawn_reasoners": {dict_name = "pawn_reasoners", ref_class = "ReasonerRef"},
}


# ─── Internal Helpers ────────────────────────────────────────────────


## Resolves a category string to the actual Data singleton dictionary.
## Returns an empty dictionary if the category is not recognized.
func _get_data_dict(category: String) -> Dictionary:
	if not CATEGORY_MAP.has(category):
		push_error("%s Invalid category: %s" % [LOG_TAG, category])
		return {}
	var dict_name: String = CATEGORY_MAP[category].dict_name
	return Data[dict_name]


## Constructs the appropriate Ref object for the given category, populates it
## with the provided data dictionary, sets ref_type to key, and returns it.
## Returns null if the category is not recognized.
func _create_ref(category: String, key: StringName, data: Dictionary) -> RefCounted:
	if not CATEGORY_MAP.has(category):
		push_error("%s Cannot create ref for invalid category: %s" % [LOG_TAG, category])
		return null

	var ref_class_name: String = CATEGORY_MAP[category].ref_class
	var ref: RefCounted = null

	match ref_class_name:
		"TaskRef":
			ref = TaskRef.new(data)
		"TaskDriverRef":
			ref = TaskDriverRef.new(data)
		"ConsiderationRef":
			ref = ConsiderationRef.new(data)
		"OptionRef":
			ref = OptionRef.new(data)
		"ReasonerRef":
			ref = ReasonerRef.new(data)

	if ref != null:
		ref.ref_type = key

	return ref


# ─── Entry Tracking (for reload support) ─────────────────────────────


## Tracks a registered entry for a given mod, enabling cleanup on reload.
func _track_entry(mod_id: String, category: String, key: StringName) -> void:
	if not _tracked_entries.has(mod_id):
		_tracked_entries[mod_id] = []
	_tracked_entries[mod_id].append({category = category, key = key})


## Returns all tracked entries for a given mod. Used by ModLoader during reload.
func get_tracked_entries(mod_id: String) -> Array:
	return _tracked_entries.get(mod_id, [])


## Clears tracked entries for a given mod after they have been consumed.
func clear_tracked_entries(mod_id: String) -> void:
	_tracked_entries.erase(mod_id)


## Clears all tracked entries (used on full reload).
func clear_all_tracked_entries() -> void:
	_tracked_entries.clear()
	_tracked_patches.clear()


func _track_patch(mod_id: String, reasoner_key: StringName, option_key: StringName) -> void:
	if not _tracked_patches.has(mod_id):
		_tracked_patches[mod_id] = []
	_tracked_patches[mod_id].append({reasoner_key = reasoner_key, option_key = option_key})


func get_tracked_patches(mod_id: String) -> Array:
	return _tracked_patches.get(mod_id, [])


# ─── Typed Registration Methods ──────────────────────────────────────


## Registers a new task into Data.tasks.
func register_task(
	mod_id: String,
	task_key: StringName,
	task_type: StringName,
	title: String,
	variable: String = ""
) -> bool:
	if Data.tasks.has(task_key):
		push_warning("%s [%s] Duplicate task key: %s — skipping" % [LOG_TAG, mod_id, task_key])
		return false

	var data: Dictionary[StringName, Variant] = {
		&"task_type": task_type,
		&"title": title,
	}
	if not variable.is_empty():
		data[&"variable"] = variable

	var ref := TaskRef.new(data)
	ref.ref_type = task_key
	Data.tasks[task_key] = ref
	_track_entry(mod_id, "tasks", task_key)
	print("%s [%s] Registered task: %s" % [LOG_TAG, mod_id, task_key])
	return true


## Registers a new task driver into Data.task_driver.
func register_task_driver(
	mod_id: String,
	driver_key: StringName,
	title: String,
	description: String,
	tasks: Array[StringName],
	options: Dictionary = {}
) -> bool:
	if Data.task_driver.has(driver_key):
		push_warning("%s [%s] Duplicate task driver key: %s — skipping" % [LOG_TAG, mod_id, driver_key])
		return false

	# Warn about missing task references
	for task_key in tasks:
		if not Data.tasks.has(task_key):
			push_warning("%s [%s] Task driver '%s' references unknown task: %s" % [LOG_TAG, mod_id, driver_key, task_key])

	var data: Dictionary[StringName, Variant] = {
		&"title": title,
		&"description": description,
		&"tasks": tasks,
	}
	# Merge optional flags
	for key in options:
		data[key] = options[key]

	var ref := TaskDriverRef.new(data)
	ref.ref_type = driver_key
	Data.task_driver[driver_key] = ref
	_track_entry(mod_id, "task_driver", driver_key)
	print("%s [%s] Registered task driver: %s" % [LOG_TAG, mod_id, driver_key])
	return true


## Registers a new consideration into Data.pawn_considerations.
func register_consideration(
	mod_id: String,
	consideration_key: StringName,
	consideration_type: StringName,
	title: String,
	extra_fields: Dictionary = {}
) -> bool:
	if Data.pawn_considerations.has(consideration_key):
		push_warning("%s [%s] Duplicate consideration key: %s — skipping" % [LOG_TAG, mod_id, consideration_key])
		return false

	var data: Dictionary[StringName, Variant] = {
		&"consideration_type": consideration_type,
		&"title": title,
	}
	for key in extra_fields:
		data[key] = extra_fields[key]

	var ref := ConsiderationRef.new(data)
	ref.ref_type = consideration_key
	Data.pawn_considerations[consideration_key] = ref
	_track_entry(mod_id, "pawn_considerations", consideration_key)
	print("%s [%s] Registered consideration: %s" % [LOG_TAG, mod_id, consideration_key])
	return true


## Registers a new pawn option into Data.pawn_options.
func register_pawn_option(
	mod_id: String,
	option_key: StringName,
	title: String,
	context_text: String,
	considerations: Array[StringName],
	task_driver: StringName,
	schedule_types: Array[StringName],
	options: Dictionary = {}
) -> bool:
	if Data.pawn_options.has(option_key):
		push_warning("%s [%s] Duplicate pawn option key: %s — skipping" % [LOG_TAG, mod_id, option_key])
		return false

	if not Data.task_driver.has(task_driver):
		push_warning("%s [%s] Pawn option '%s' references unknown task driver: %s" % [LOG_TAG, mod_id, option_key, task_driver])

	for con_key in considerations:
		if not Data.pawn_considerations.has(con_key):
			push_warning("%s [%s] Pawn option '%s' references unknown consideration: %s" % [LOG_TAG, mod_id, option_key, con_key])

	var data: Dictionary[StringName, Variant] = {
		&"title": title,
		&"context_text": context_text,
		&"pawn_considerations": considerations,
		&"task_driver": task_driver,
		&"schedule_types": schedule_types,
	}
	for key in options:
		data[key] = options[key]

	var ref := OptionRef.new(data)
	ref.ref_type = option_key
	Data.pawn_options[option_key] = ref
	_track_entry(mod_id, "pawn_options", option_key)
	print("%s [%s] Registered pawn option: %s" % [LOG_TAG, mod_id, option_key])
	return true


# ─── Patching Methods ────────────────────────────────────────────────


## Patches an existing reasoner by appending a pawn option key to its options array.
func patch_reasoner(
	mod_id: String,
	reasoner_key: StringName,
	option_key: StringName
) -> bool:
	if not Data.pawn_reasoners.has(reasoner_key):
		push_error("%s [%s] Reasoner not found: %s" % [LOG_TAG, mod_id, reasoner_key])
		return false

	if not Data.pawn_options.has(option_key):
		push_warning("%s [%s] Patching reasoner '%s' with unregistered option: %s" % [LOG_TAG, mod_id, reasoner_key, option_key])

	var reasoner: ReasonerRef = Data.pawn_reasoners[reasoner_key]
	if option_key in reasoner.pawn_options:
		print("%s [%s] Option '%s' already in reasoner '%s' — skipping" % [LOG_TAG, mod_id, option_key, reasoner_key])
		return true

	reasoner.pawn_options.append(option_key)
	_track_patch(mod_id, reasoner_key, option_key)
	print("%s [%s] Patched reasoner '%s': added option '%s'" % [LOG_TAG, mod_id, reasoner_key, option_key])
	return true


# ─── Generic Methods ─────────────────────────────────────────────────


## Registers a new entry into any Data singleton dictionary by category.
func register_data(
	mod_id: String,
	category: String,
	key: StringName,
	data: Dictionary
) -> bool:
	if not CATEGORY_MAP.has(category):
		push_error("%s [%s] Invalid category: %s" % [LOG_TAG, mod_id, category])
		return false

	var data_dict := _get_data_dict(category)
	if data_dict.has(key):
		push_warning("%s [%s] Duplicate key '%s' in category '%s' — skipping" % [LOG_TAG, mod_id, key, category])
		return false

	var ref := _create_ref(category, key, data)
	if ref == null:
		push_error("%s [%s] Failed to create ref for category '%s', key '%s'" % [LOG_TAG, mod_id, category, key])
		return false

	data_dict[key] = ref
	_track_entry(mod_id, category, key)
	print("%s [%s] Registered %s: %s" % [LOG_TAG, mod_id, category, key])
	return true


## Patches an existing entry in any Data singleton dictionary by category.
func patch_data(
	mod_id: String,
	category: String,
	key: StringName,
	patch: Dictionary
) -> bool:
	if not CATEGORY_MAP.has(category):
		push_error("%s [%s] Invalid category: %s" % [LOG_TAG, mod_id, category])
		return false

	var data_dict := _get_data_dict(category)
	if not data_dict.has(key):
		push_error("%s [%s] Key '%s' not found in category '%s'" % [LOG_TAG, mod_id, key, category])
		return false

	var entry = data_dict[key]
	for field in patch:
		entry.set(field, patch[field])

	print("%s [%s] Patched %s: %s" % [LOG_TAG, mod_id, category, key])
	return true
