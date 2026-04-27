extends RefCounted

var mod_id: String
var mod_name: String
var mod_folder: String  # Absolute filesystem path

func log(message: String) -> void:
	print("[%s] %s" % [mod_id, message])

func log_warning(message: String) -> void:
	push_warning("[%s] %s" % [mod_id, message])

func log_error(message: String) -> void:
	push_error("[%s] %s" % [mod_id, message])
