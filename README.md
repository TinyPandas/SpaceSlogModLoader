# SpaceSlogModLoader

A GDScript mod loading system for [SpaceSlog](https://store.steampowered.com/app/2133570/SpaceSlog/). Provides structured lifecycle management and a clean registration API so modders can add custom AI behaviors, tasks, and game content without boilerplate.

## What it does

- **Discovers** GDScript mods from the `Modules/` directory and Steam Workshop
- **Compiles** loose `.gd` files and registers them at `res://` paths automatically
- **Orchestrates** a four-phase mod lifecycle: init → register → patch → ready
- **Provides** the ModdingAPI with typed methods for registering tasks, task drivers, considerations, pawn options, and reasoner patches
- **Configures** mods via `.cfg` files with an in-game UI in the Modules tab
- **Updates** automatically from GitHub releases
- **Displays** version and loaded mod count on the main menu
- **Detects** mod enable/disable changes and updates in real time

## Installation

### 1. Download

Download the latest release from the [Releases](https://github.com/TinyPandas/SpaceSlogModLoader/releases) page, or clone this repo.

### 2. Copy files to your SpaceSlog install

Copy the following into your SpaceSlog install directory:

```
SpaceSlog/
├── override.cfg                          ← registers the autoloads
└── Autoloads/
    ├── ModdingAPI.gd                     ← public API singleton
    ├── ModLoader.gd                      ← mod loading pipeline
    ├── ModdingAPI/
    │   └── SpaceslogMod.gd              ← base class for mod entry scripts
    └── ModLoader/
        ├── ModManifest.gd               ← manifest parser
        ├── ModContext.gd                 ← mod logging context
        ├── ScriptRegistry.gd            ← script compiler/registrar
        ├── UpdateChecker.gd             ← automatic update checker
        ├── ModConfigManager.gd          ← mod configuration system
        └── ConfigUIInjector.gd          ← config UI for Modules tab
```

### 3. Verify

Launch SpaceSlog. You should see a line below the game version on the main menu:

```
ModLoader v1.0 | 0 mods loaded (0 data, 0 script)
```

### Finding your install directory

- **Steam**: Right-click SpaceSlog → Manage → Browse Local Files
- Typically: `C:\Program Files (x86)\Steam\steamapps\common\SpaceSlog\`

## For modders

### Quick start

1. Create your mod folder in `Modules/` with a `Mod_Info.json`
2. Add the GDScript fields to your `Mod_Info.json`:

```json
{
    "mod_name": "My Mod",
    "mod_id": "author.my_mod",
    "mod_author": "Author",
    "mod_description": "Description of my mod.",
    "entry_script": "my_mod.gd",
    "scripts": [
        {"path": "Scripts/MyTask.gd", "res_path": "res://Prefabs/AI/PawnAI/Tasks/MyTask.gd"}
    ]
}
```

3. Create your entry script extending `SpaceslogMod`:

```gdscript
extends SpaceslogMod

func _on_mod_register(api: ModdingAPI) -> void:
    api.register_task(context.mod_id, &"MyTask", &"MyTask", "Do something.")

func _on_mod_patch(api: ModdingAPI) -> void:
    api.patch_reasoner(context.mod_id, &"Human", &"MyOption")
```

### Mod_Info.json fields

Standard fields (all mods):

| Field | Required | Description |
|-------|----------|-------------|
| `mod_name` | Yes | Display name |
| `mod_id` | Yes | Unique identifier (e.g., `author.mod_name`) |
| `mod_author` | Yes | Author name |
| `mod_description` | Yes | Short description |
| `image_path` | No | Path to mod image |
| `for_game_version` | No | Target game version |
| `mod_url` | No | Link shown in mod menu |

GDScript fields (triggers ModLoader processing):

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `entry_script` | Yes | — | Path to main `.gd` file extending `SpaceslogMod` |
| `scripts` | No | `[]` | Array of `{path, res_path}` for scripts to compile and register |
| `dependencies` | No | `[]` | Array of `mod_id` strings this mod requires |
| `load_order` | No | `100` | Lower values load first |
| `min_modloader_version` | No | — | Minimum ModLoader version required (e.g., `"1.2.0"`) |

### Lifecycle methods

Override these in your entry script:

| Method | When | Use for |
|--------|------|---------|
| `_on_mod_init(context)` | After scripts registered | One-time setup |
| `_on_mod_register(api)` | After data import | Register new content |
| `_on_mod_patch(api)` | After all mods registered | Patch other mods' content |
| `_on_mod_ready()` | After all patches | Final setup |

### ModdingAPI methods

```gdscript
# Register content
api.register_task(mod_id, task_key, task_type, title, variable)
api.register_task_driver(mod_id, driver_key, title, description, tasks, options)
api.register_consideration(mod_id, key, type, title, extra_fields)
api.register_pawn_option(mod_id, key, title, context_text, considerations, task_driver, schedule_types, options)

# Patch existing content
api.patch_reasoner(mod_id, reasoner_key, option_key)
api.patch_data(mod_id, category, key, patch_dict)

# Generic registration for any Data category
api.register_data(mod_id, category, key, data_dict)
```

### ModContext

Available via `context` in your entry script:

```gdscript
context.mod_id      # Your mod's unique ID
context.mod_name    # Your mod's display name
context.mod_folder  # Absolute path to your mod's directory

context.log("message")          # Print with [mod_id] prefix
context.log_warning("message")  # Warning with [mod_id] prefix
context.log_error("message")    # Error with [mod_id] prefix
```

### Configuration

Mods can define player-configurable settings using a `.cfg` file. The ModLoader reads the config automatically and provides an in-game UI in the Modules tab.

#### Creating a config file

Create a file named `{mod_id}.cfg` in your mod folder (e.g., `author.my_mod.cfg`). The format is JSON:

```json
{
    "speed_multiplier": {
        "type": "float",
        "defaultValue": 1.0,
        "currentValue": 1.0,
        "minValue": 0.1,
        "maxValue": 10.0
    },
    "enable_feature": {
        "type": "bool",
        "defaultValue": true,
        "currentValue": true
    },
    "max_count": {
        "type": "int",
        "defaultValue": 5,
        "currentValue": 5,
        "minValue": 1,
        "maxValue": 100
    },
    "label_text": {
        "type": "string",
        "defaultValue": "Hello",
        "currentValue": "Hello"
    }
}
```

#### Config entry fields

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | `"bool"`, `"int"`, `"float"`, or `"string"` |
| `defaultValue` | Yes | The default value (must match the declared type) |
| `currentValue` | No | The player's current setting (falls back to `defaultValue` if missing or invalid) |
| `minValue` | No | Minimum allowed value (`int` and `float` only) |
| `maxValue` | No | Maximum allowed value (`int` and `float` only) |

#### Reading config values

Config values are available from `_on_mod_init` onward:

```gdscript
func _on_mod_init(ctx) -> void:
    var speed = ModdingAPI.get_config(context.mod_id, "speed_multiplier")
    var enabled = ModdingAPI.get_config(context.mod_id, "enable_feature")
    context.log("Speed: %s, Enabled: %s" % [speed, enabled])
```

#### Config API methods

```gdscript
# Read values
ModdingAPI.get_config(mod_id, value_name)           # Returns current value
ModdingAPI.get_all_config(mod_id)                    # Returns {name: value} dict
ModdingAPI.get_config_default(mod_id, value_name)    # Returns default value

# Write values (validates type, persists to disk, emits signal)
ModdingAPI.set_config(mod_id, value_name, new_value)

# Auto-bind a config value to an object property (zero boilerplate)
ModdingAPI.bind_config(mod_id, value_name, target_object, "property_name")
ModdingAPI.unbind_config(mod_id, value_name, target_object, "property_name")
```

#### Reacting to config changes at runtime

**Option 1: Polling** — Call `get_config()` whenever you need the value. Simple, no setup needed.

**Option 2: Binding** — Use `bind_config()` to auto-update a property when the value changes:

```gdscript
func _on_mod_init(ctx) -> void:
    # self.speed_multiplier will be set immediately and updated whenever the player changes it
    ModdingAPI.bind_config(context.mod_id, "speed_multiplier", self, "speed_multiplier")
```

**Option 3: Signal** — Connect to the config manager's signal for full control:

```gdscript
func _on_mod_init(ctx) -> void:
    ModdingAPI._config_manager.config_value_changed.connect(_on_config_changed)

func _on_config_changed(mod_id: String, value_name: String, new_value) -> void:
    if mod_id != context.mod_id:
        return
    context.log("Config changed: %s = %s" % [value_name, new_value])
```

#### In-game UI

Players can adjust config values from the main menu **Modules** tab. When a mod with a `.cfg` file is selected, a Configuration section appears with appropriate controls:
- **bool** → checkbox
- **int** / **float** → numeric spinner (respects `minValue`/`maxValue`)
- **string** → text input
- **Reset to Defaults** button restores all values

Changes are saved to disk immediately and take effect without restarting.

## Compatibility

- Built for SpaceSlog **v0.12.0.5**
- Coexists with the game's existing JSON data mod system
- Mods without `entry_script` in their `Mod_Info.json` are left to the base game's data mod system

## License

MIT — see [LICENSE](LICENSE).
