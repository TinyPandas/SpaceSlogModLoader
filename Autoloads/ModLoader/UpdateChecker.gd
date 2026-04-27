extends Node
## UpdateChecker — checks GitHub Releases for a newer ModLoader version,
## prompts the user, downloads the zip, extracts it in-place, and asks
## the user to restart.

signal update_check_completed(has_update: bool, latest_version: String)
signal update_applied

const LOG_TAG: String = "[UpdateChecker]"
const REPO_API_URL: String = "https://api.github.com/repos/TinyPandas/SpaceSlogModLoader/releases/latest"

## Injected by ModLoader after instantiation.
var current_version: String

## Internal state
var _latest_version: String = ""
var _download_url: String = ""
var _check_request: HTTPRequest = null
var _download_request: HTTPRequest = null
var _confirm_dialog: AcceptDialog = null
var _restart_dialog: AcceptDialog = null


func check_for_update() -> void:
	if _check_request != null:
		return  # Already checking

	_check_request = HTTPRequest.new()
	add_child(_check_request)
	_check_request.request_completed.connect(_on_check_completed)

	var headers: PackedStringArray = PackedStringArray([
		"Accept: application/vnd.github.v3+json",
		"User-Agent: SpaceSlogModLoader/%s" % current_version
	])

	var err := _check_request.request(REPO_API_URL, headers)
	if err != OK:
		push_error("%s Failed to send update check request (error %d)" % [LOG_TAG, err])
		_cleanup_check_request()


func _on_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_cleanup_check_request()

	if result != HTTPRequest.RESULT_SUCCESS:
		push_warning("%s Update check failed: HTTPRequest result %d" % [LOG_TAG, result])
		update_check_completed.emit(false, "")
		return

	if response_code != 200:
		push_warning("%s Update check failed: HTTP %d" % [LOG_TAG, response_code])
		update_check_completed.emit(false, "")
		return

	var json := JSON.new()
	var err := json.parse(body.get_string_from_utf8())
	if err != OK:
		push_warning("%s Failed to parse update response: %s" % [LOG_TAG, json.get_error_message()])
		update_check_completed.emit(false, "")
		return

	var data: Dictionary = json.data
	var tag_name: String = str(data.get("tag_name", ""))
	_latest_version = _normalize_tag(tag_name)

	if not _is_newer_version(_latest_version, current_version):
		print("%s Up to date (current: %s, latest: %s)" % [LOG_TAG, current_version, _latest_version])
		update_check_completed.emit(false, _latest_version)
		return

	# Find the zip asset in the release
	var assets: Array = data.get("assets", [])
	_download_url = ""
	for asset in assets:
		var name: String = str(asset.get("name", ""))
		if name.ends_with(".zip"):
			_download_url = str(asset.get("browser_download_url", ""))
			break

	if _download_url.is_empty():
		push_warning("%s Release %s has no .zip asset — cannot auto-update" % [LOG_TAG, _latest_version])
		update_check_completed.emit(false, _latest_version)
		return

	print("%s Update available: %s -> %s" % [LOG_TAG, current_version, _latest_version])
	update_check_completed.emit(true, _latest_version)
	_show_update_prompt()


func _show_update_prompt() -> void:
	_confirm_dialog = AcceptDialog.new()
	_confirm_dialog.title = "ModLoader Update Available"
	_confirm_dialog.dialog_text = "ModLoader v%s is available (you have v%s).\n\nUpdate now?" % [_latest_version, current_version]
	_confirm_dialog.ok_button_text = "Yes"
	_confirm_dialog.add_cancel_button("No")
	_confirm_dialog.confirmed.connect(_on_update_accepted)
	_confirm_dialog.canceled.connect(_on_update_declined)

	_add_dialog_to_scene(_confirm_dialog)


func _on_update_accepted() -> void:
	_cleanup_dialog(_confirm_dialog)
	_confirm_dialog = null
	_download_update()


func _on_update_declined() -> void:
	print("%s User declined update to %s" % [LOG_TAG, _latest_version])
	_cleanup_dialog(_confirm_dialog)
	_confirm_dialog = null


func _download_update() -> void:
	print("%s Downloading update from: %s" % [LOG_TAG, _download_url])

	_download_request = HTTPRequest.new()
	# Download to a temp file in the game directory
	var base_dir: String = OS.get_executable_path().get_base_dir()
	var temp_zip: String = base_dir.path_join("_modloader_update.zip")
	_download_request.download_file = temp_zip
	add_child(_download_request)
	_download_request.request_completed.connect(_on_download_completed)

	var headers: PackedStringArray = PackedStringArray([
		"User-Agent: SpaceSlogModLoader/%s" % current_version
	])

	var err := _download_request.request(_download_url, headers)
	if err != OK:
		push_error("%s Failed to start download (error %d)" % [LOG_TAG, err])
		_cleanup_download_request()


func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_cleanup_download_request()

	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("%s Download failed: HTTPRequest result %d" % [LOG_TAG, result])
		return

	if response_code != 200:
		push_error("%s Download failed: HTTP %d" % [LOG_TAG, response_code])
		return

	print("%s Download complete, extracting..." % LOG_TAG)
	var success := _extract_update()

	if success:
		print("%s Update applied successfully" % LOG_TAG)
		update_applied.emit()
		_show_restart_prompt()
	else:
		push_error("%s Update extraction failed" % LOG_TAG)


func _extract_update() -> bool:
	var base_dir: String = OS.get_executable_path().get_base_dir()
	var temp_zip: String = base_dir.path_join("_modloader_update.zip")

	if not FileAccess.file_exists(temp_zip):
		push_error("%s Temp zip not found: %s" % [LOG_TAG, temp_zip])
		return false

	var reader := ZIPReader.new()
	var err := reader.open(temp_zip)
	if err != OK:
		push_error("%s Failed to open zip: error %d" % [LOG_TAG, err])
		return false

	var files: PackedStringArray = reader.get_files()
	# Determine if the zip has a top-level folder (common with GitHub releases)
	var prefix: String = _detect_zip_prefix(files)

	for file_path in files:
		# Skip directory entries
		if file_path.ends_with("/"):
			continue

		var relative_path: String = file_path
		if not prefix.is_empty() and relative_path.begins_with(prefix):
			relative_path = relative_path.substr(prefix.length())

		# Only extract Autoloads/ and override.cfg — skip repo metadata
		if not _should_extract(relative_path):
			continue

		var content: PackedByteArray = reader.read_file(file_path)
		var target_path: String = base_dir.path_join(relative_path)

		# Ensure parent directory exists
		var target_dir: String = target_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(target_dir):
			DirAccess.make_dir_recursive_absolute(target_dir)

		var file := FileAccess.open(target_path, FileAccess.WRITE)
		if not file:
			push_error("%s Cannot write: %s (error %d)" % [LOG_TAG, target_path, FileAccess.get_open_error()])
			continue

		file.store_buffer(content)
		file.close()
		print("%s Extracted: %s" % [LOG_TAG, relative_path])

	reader.close()

	# Clean up the temp zip
	DirAccess.remove_absolute(temp_zip)
	print("%s Temp zip removed" % LOG_TAG)
	return true


## Detects a common top-level folder prefix in the zip (e.g., "SpaceSlogModLoader-1.2.0/").
func _detect_zip_prefix(files: PackedStringArray) -> String:
	if files.is_empty():
		return ""

	# Check if all files share a common top-level directory
	var first: String = files[0]
	var slash_idx: int = first.find("/")
	if slash_idx < 0:
		return ""

	var candidate: String = first.substr(0, slash_idx + 1)
	for file_path in files:
		if not file_path.begins_with(candidate):
			return ""

	return candidate


## Returns true if the relative path should be extracted during an update.
## We only update the ModLoader's own files, not Mod_Info.json or repo metadata.
func _should_extract(relative_path: String) -> bool:
	if relative_path.begins_with("Autoloads/"):
		return true
	if relative_path == "override.cfg":
		return true
	return false


func _show_restart_prompt() -> void:
	_restart_dialog = AcceptDialog.new()
	_restart_dialog.title = "ModLoader Updated"
	_restart_dialog.dialog_text = "ModLoader has been updated to v%s.\nPlease restart the game for changes to take effect." % _latest_version
	_restart_dialog.ok_button_text = "OK"
	_restart_dialog.confirmed.connect(_on_restart_acknowledged)

	_add_dialog_to_scene(_restart_dialog)


func _on_restart_acknowledged() -> void:
	_cleanup_dialog(_restart_dialog)
	_restart_dialog = null


# ─── Version Comparison ──────────────────────────────────────────────


## Strips a leading "v" from a tag name (e.g., "v1.2.0" -> "1.2.0").
func _normalize_tag(tag: String) -> String:
	tag = tag.strip_edges()
	if tag.begins_with("v") or tag.begins_with("V"):
		tag = tag.substr(1)
	return tag


## Returns true if `remote` is strictly newer than `local` using semver comparison.
func _is_newer_version(remote: String, local: String) -> bool:
	var remote_parts: Array = _parse_semver(remote)
	var local_parts: Array = _parse_semver(local)

	for i in range(3):
		if remote_parts[i] > local_parts[i]:
			return true
		if remote_parts[i] < local_parts[i]:
			return false

	return false  # Equal


## Parses a version string into [major, minor, patch]. Missing parts default to 0.
func _parse_semver(version: String) -> Array:
	var parts: PackedStringArray = version.split(".")
	var result: Array = [0, 0, 0]
	for i in range(mini(parts.size(), 3)):
		result[i] = parts[i].to_int()
	return result


# ─── UI Helpers ──────────────────────────────────────────────────────


## Adds a dialog to the scene tree's root so it displays properly.
func _add_dialog_to_scene(dialog: AcceptDialog) -> void:
	var root := get_tree().root
	root.add_child(dialog)
	dialog.popup_centered()


func _cleanup_dialog(dialog: AcceptDialog) -> void:
	if dialog != null and is_instance_valid(dialog):
		dialog.queue_free()


func _cleanup_check_request() -> void:
	if _check_request != null:
		_check_request.queue_free()
		_check_request = null


func _cleanup_download_request() -> void:
	if _download_request != null:
		_download_request.queue_free()
		_download_request = null
