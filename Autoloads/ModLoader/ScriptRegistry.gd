extends RefCounted
## Utility class for registering mod GDScript files at virtual resource paths.


static func register_script(disk_path: String, res_path: String, mod_id: String) -> bool:
	if not FileAccess.file_exists(disk_path):
		push_error("[ScriptRegistry][%s] File not found: %s" % [mod_id, disk_path])
		return false

	var file := FileAccess.open(disk_path, FileAccess.READ)
	if not file:
		push_error("[ScriptRegistry][%s] Cannot open: %s (error %d)" % [
			mod_id, disk_path, FileAccess.get_open_error()])
		return false

	var source := file.get_as_text()
	file.close()

	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		push_error("[ScriptRegistry][%s] Compile failed: %s (error %d)" % [
			mod_id, disk_path, err])
		return false

	script.take_over_path(res_path)
	print("[ScriptRegistry][%s] Registered: %s -> %s" % [mod_id, disk_path, res_path])
	return true
