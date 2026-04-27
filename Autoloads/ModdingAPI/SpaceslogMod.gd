extends Node

## The mod's context, set by ModLoader before _on_mod_init is called.
var context


## Called after scripts are registered, before data registration.
func _on_mod_init(_context) -> void:
	pass


## Called after core data is loaded. Register new content here.
func _on_mod_register(_api) -> void:
	pass


## Called after ALL mods have registered. Patch other mods' content here.
func _on_mod_patch(_api) -> void:
	pass


## Called after all mods have patched. All content is finalized.
func _on_mod_ready() -> void:
	pass
