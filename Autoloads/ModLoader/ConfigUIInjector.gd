extends RefCounted

## ConfigUIInjector — Internal component responsible for building configuration
## UI controls and injecting them into the Modules tab.
## Loaded at runtime by ModLoader via _load_script().

const LOG_TAG: String = "[ConfigUIInjector]"

## Reference to the ModConfigManager instance (set by ModLoader).
var _config_manager = null

## Tracks which mod's config panel is currently displayed.
var _current_mod_id: String = ""

## Tracks the current panel VBoxContainer for rebuilding after reset.
var _current_panel: VBoxContainer = null


# ─── Public Interface ─────────────────────────────────────────────


## Creates and returns a VBoxContainer with config controls for a mod.
## Returns null if config_entries is empty.
func build_config_panel(mod_id: String, config_entries: Dictionary) -> VBoxContainer:
	if config_entries.is_empty():
		return null

	_current_mod_id = mod_id

	var panel := VBoxContainer.new()
	panel.name = "ConfigPanel"

	# Header label
	var header := Label.new()
	header.text = "Configuration"
	header.add_theme_font_size_override("font_size", 18)
	panel.add_child(header)

	# Create a control for each config entry
	for entry_name in config_entries.keys():
		var entry: Dictionary = config_entries[entry_name]
		var control := _create_control(entry_name, entry)
		if control != null:
			panel.add_child(control)

	# Reset to Defaults button at the bottom
	var reset_button := _create_reset_button()
	panel.add_child(reset_button)

	_current_panel = panel
	return panel


# ─── Control Builders ─────────────────────────────────────────────


## Dispatcher: creates the appropriate input control based on entry type.
func _create_control(entry_name: String, entry: Dictionary) -> HBoxContainer:
	match entry["type"]:
		"bool":
			return _create_bool_control(entry_name, entry["currentValue"])
		"int":
			return _create_int_control(entry_name, entry)
		"float":
			return _create_float_control(entry_name, entry)
		"string":
			return _create_string_control(entry_name, entry["currentValue"])
		_:
			push_warning("%s Unknown config type '%s' for entry '%s'" % [LOG_TAG, entry["type"], entry_name])
			return null


## Creates a CheckBox control for bool config entries.
func _create_bool_control(entry_name: String, value: bool) -> HBoxContainer:
	var container := HBoxContainer.new()
	container.name = entry_name

	var label := Label.new()
	label.text = _format_label(entry_name)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(label)

	var checkbox := CheckBox.new()
	checkbox.button_pressed = value
	checkbox.toggled.connect(func(new_value: bool) -> void:
		_config_manager.set_value(_current_mod_id, entry_name, new_value)
	)
	container.add_child(checkbox)

	return container


## Creates a SpinBox control for int config entries.
## Sets min_value/max_value from entry if present.
func _create_int_control(entry_name: String, entry: Dictionary) -> HBoxContainer:
	var container := HBoxContainer.new()
	container.name = entry_name

	var label := Label.new()
	label.text = _format_label(entry_name)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(label)

	var spinbox := SpinBox.new()
	spinbox.step = 1
	spinbox.rounded = true

	if entry["minValue"] != null:
		spinbox.min_value = entry["minValue"]
	if entry["maxValue"] != null:
		spinbox.max_value = entry["maxValue"]

	spinbox.value = entry["currentValue"]
	spinbox.value_changed.connect(func(new_value: float) -> void:
		_config_manager.set_value(_current_mod_id, entry_name, int(new_value))
	)
	container.add_child(spinbox)

	return container


## Creates a SpinBox control for float config entries.
## Sets min_value/max_value from entry if present.
func _create_float_control(entry_name: String, entry: Dictionary) -> HBoxContainer:
	var container := HBoxContainer.new()
	container.name = entry_name

	var label := Label.new()
	label.text = _format_label(entry_name)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(label)

	var spinbox := SpinBox.new()
	spinbox.step = 0.01

	if entry["minValue"] != null:
		spinbox.min_value = entry["minValue"]
	if entry["maxValue"] != null:
		spinbox.max_value = entry["maxValue"]

	spinbox.value = entry["currentValue"]
	spinbox.value_changed.connect(func(new_value: float) -> void:
		_config_manager.set_value(_current_mod_id, entry_name, new_value)
	)
	container.add_child(spinbox)

	return container


## Creates a LineEdit control for string config entries.
func _create_string_control(entry_name: String, value: String) -> HBoxContainer:
	var container := HBoxContainer.new()
	container.name = entry_name

	var label := Label.new()
	label.text = _format_label(entry_name)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(label)

	var line_edit := LineEdit.new()
	line_edit.text = value
	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_edit.text_changed.connect(func(new_value: String) -> void:
		_config_manager.set_value(_current_mod_id, entry_name, new_value)
	)
	container.add_child(line_edit)

	return container


# ─── Reset Button ─────────────────────────────────────────────────


## Creates the "Reset to Defaults" button.
func _create_reset_button() -> Button:
	var button := Button.new()
	button.text = "Reset to Defaults"
	button.pressed.connect(_on_reset_pressed)
	return button


## Called when the reset button is pressed. Resets all config values to defaults
## and rebuilds the panel to reflect the new values.
func _on_reset_pressed() -> void:
	_config_manager.reset_to_defaults(_current_mod_id)
	_rebuild_panel()


## Rebuilds the current config panel after a reset to reflect updated values.
func _rebuild_panel() -> void:
	if _current_panel == null or not is_instance_valid(_current_panel):
		return

	var parent := _current_panel.get_parent()
	if parent == null:
		return

	# Get fresh config entries
	var config_entries: Dictionary = _config_manager.get_config_entries(_current_mod_id)

	# Remove old panel
	parent.remove_child(_current_panel)
	_current_panel.queue_free()

	# Build new panel and add it
	var new_panel := build_config_panel(_current_mod_id, config_entries)
	if new_panel != null:
		parent.add_child(new_panel)


# ─── Helpers ──────────────────────────────────────────────────────


## Formats an entry_name into a readable label (replaces underscores with spaces, capitalizes).
func _format_label(entry_name: String) -> String:
	return entry_name.replace("_", " ").capitalize()
