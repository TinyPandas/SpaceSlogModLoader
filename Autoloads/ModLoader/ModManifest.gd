extends RefCounted

## Standard Mod_Info.json fields (present in all mods)
var mod_name: String
var mod_id: String
var mod_author: String
var mod_description: String
var image_path: String            ## Optional, path to mod image
var for_game_version: String      ## Optional, target game version
var workshop_file_id: int         ## Optional, Steam Workshop ID (0 if not set)
var mod_url: String               ## Optional, mod/author URL

## GDScript-specific fields (presence of entry_script indicates a GDScript mod)
var entry_script: String          ## Relative path within mod folder
var dependencies: Array[String]   ## Array of mod_id strings
var load_order: int = 100         ## Lower = earlier, default 100
var scripts: Array[Dictionary]    ## [{path: "relative/path.gd", res_path: "res://..."}]
var mod_folder: String            ## Absolute filesystem path to mod root

const LOG_TAG: String = "[ModManifest]"
const _REQUIRED_FIELDS: Array[String] = ["mod_name", "mod_id", "mod_author", "mod_description"]


## Parses and validates the Mod_Info.json content into this manifest instance.
## Returns true on success, false on validation failure.
func parse_json(json_dict: Dictionary, folder_path: String) -> bool:
	if not json_dict.has("entry_script"):
		return false

	# Validate required fields
	var missing_fields: Array[String] = []
	for field in _REQUIRED_FIELDS:
		if not json_dict.has(field) or str(json_dict[field]).strip_edges().is_empty():
			missing_fields.append(field)

	if not missing_fields.is_empty():
		push_error("%s Validation failed for mod in '%s': missing required fields: %s" % [
			LOG_TAG, folder_path, ", ".join(missing_fields)])
		return false

	# Standard fields
	mod_name = str(json_dict["mod_name"])
	mod_id = str(json_dict["mod_id"])
	mod_author = str(json_dict["mod_author"])
	mod_description = str(json_dict["mod_description"])
	image_path = str(json_dict.get("image_path", ""))
	for_game_version = str(json_dict.get("for_game_version", ""))
	workshop_file_id = int(json_dict.get("workshop_file_id", 0))
	mod_url = str(json_dict.get("mod_url", ""))

	# GDScript-specific fields
	entry_script = str(json_dict["entry_script"])
	load_order = int(json_dict.get("load_order", 100))
	mod_folder = folder_path

	# Parse dependencies
	var raw_deps = json_dict.get("dependencies", [])
	if raw_deps is Array:
		for dep in raw_deps:
			dependencies.append(str(dep))

	# Parse scripts array
	var raw_scripts = json_dict.get("scripts", [])
	if raw_scripts is Array:
		for entry in raw_scripts:
			if entry is Dictionary and entry.has("path") and entry.has("res_path"):
				scripts.append(entry)

	return true


static func is_gdscript_mod(json_dict: Dictionary) -> bool:
	## Returns true if the dictionary contains an "entry_script" field.
	return json_dict.has("entry_script")
