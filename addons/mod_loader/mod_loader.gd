# ModLoader - A mod loader for GDScript
#
# Version 2.0.0
#
# Written in 2021 by harrygiel <harrygiel@gmail.com>,
# in 2021 by Mariusz Chwalba <mariusz@chwalba.net>,
# in 2022 by Vladimir Panteleev <git@cy.md>
# in 2023 by KANA <kai@kana.jetzt>
# in 2023 by Darkly77
#
# To the extent possible under law, the author(s) have
# dedicated all copyright and related and neighboring
# rights to this software to the public domain worldwide.
# This software is distributed without any warranty.
#
# You should have received a copy of the CC0 Public
# Domain Dedication along with this software. If not, see
# <http://creativecommons.org/publicdomain/zero/1.0/>.

extends Node


# Config
# =============================================================================

# Most of these settings should never need to change, aside from the DEBUG_*
# options (which should be `false` when distributing compiled PCKs)

# If true, a complete array of filepaths is stored for each mod. This is
# disabled by default because the operation can be very expensive, but may
# be useful for debugging
const DEBUG_ENABLE_STORING_FILEPATHS = false

# Path to the mod log file
# Find this log here: %appdata%/GAMENAME/mods.log
const MOD_LOG_PATH = "user://mods.log"

# This is where mod ZIPs are unpacked to
const UNPACKED_DIR = "res://mods-unpacked/"


# Set to true to require using "--enable-mods" to enable them
const REQUIRE_CMD_LINE = false

# Prefix for this file when using mod_log or dev_log
const LOG_NAME = "ModLoader"


# Vars
# =============================================================================

# Stores data for every found/loaded mod
var mod_data = {}

# Order for mods to be loaded in, set by `_get_load_order`
var mod_load_order = []

# Override for the path mods are loaded from. Only set if the CLI arg is present.
# Can be tested in the editor via: Project Settings > Display> Editor > Main Run Args
# Default: "res://mods"
# Set via: --mods-path
# Example: --mods-path="C://path/mods"
var os_mods_path_override = ""

# Override for the path config JSONs are loaded from
# Default: "res://configs"
# Set via: --configs-path
# Example: --configs-path="C://path/configs"
var os_configs_path_override = ""

# Any mods that are missing their dependancies are added to this
# Example property: "mod_id": ["dep_mod_id_0", "dep_mod_id_2"]
var mod_missing_dependencies = {}

# Things to keep to ensure they are not garbage collected (used by `save_scene`)
var _saved_objects = []


# Main
# =============================================================================

func _init():
	# if mods are not enabled - don't load mods
	if REQUIRE_CMD_LINE and not ModLoaderUtils.is_running_with_command_line_arg("--enable-mods"):
		return

	# Log game install dir
	ModLoaderUtils.log_info("game_install_directory: %s" % ModLoaderUtils.get_local_folder_dir(), LOG_NAME)

	# check if we want to use a different mods path that is provided as a command line argument
	var cmd_line_mod_path := ModLoaderUtils.get_cmd_line_arg_value("--mods-path")
	if cmd_line_mod_path != "":
		os_mods_path_override = cmd_line_mod_path
		ModLoaderUtils.log_info("The path mods are loaded from has been changed via the CLI arg `--mods-path`, to: " + cmd_line_mod_path, LOG_NAME)

	# Check for the CLI arg that overrides the configs path
	var cmd_line_configs_path = ModLoaderUtils.get_cmd_line_arg_value("--configs-path")
	if cmd_line_configs_path != "":
		os_configs_path_override = cmd_line_configs_path
		ModLoaderUtils.log_info("The path configs are loaded from has been changed via the CLI arg `--configs-path`, to: " + cmd_line_configs_path, LOG_NAME)

	# Loop over "res://mods" and add any mod zips to the unpacked virtual
	# directory (UNPACKED_DIR)
	var unzipped_mods = _load_mod_zips()
	if (unzipped_mods > 0):
		ModLoaderUtils.log_success("DONE: Loaded %s mod files into the virtual filesystem" % unzipped_mods, LOG_NAME)
	else:
		ModLoaderUtils.log_info("No zipped mods found", LOG_NAME)

	# Loop over UNPACKED_DIR. This triggers _init_mod_data for each mod
	# directory, which adds their data to mod_data.
	var setup_mods = _setup_mods()
	if (setup_mods > 0):
		ModLoaderUtils.log_success("DONE: Setup %s mods" % setup_mods, LOG_NAME)
	else:
		ModLoaderUtils.log_info("No mods were setup", LOG_NAME)

	# Set up mod configs. If a mod's JSON file is found, its data gets added
	# to mod_data.{dir_name}.config
	_load_mod_configs()

	# Loop over all loaded mods via their entry in mod_data. Verify that they
	# have all the required files (REQUIRED_MOD_FILES), load their meta data
	# (from their manifest.json file), and verify that the meta JSON has all
	# required properties (REQUIRED_META_TAGS)
	for dir_name in mod_data:
		var mod: ModData = mod_data[dir_name]
		mod.load_manifest()

	ModLoaderUtils.log_success("DONE: Loaded all meta data", LOG_NAME)

	# Run dependency checks after loading mod_manifest. If a mod depends on another
	# mod that hasn't been loaded, that dependent mod won't be loaded.
	for dir_name in mod_data:
		var mod: ModData = mod_data[dir_name]
		if not mod.is_loadable:
			continue
		_check_dependencies(dir_name, mod.manifest.dependencies)

	# Sort mod_load_order by the importance score of the mod
	_get_load_order()

	# Log mod order
	var mod_i = 1
	for mod in mod_load_order: # mod === mod_data
		mod = mod as ModData
		ModLoaderUtils.log_debug("mod_load_order -> %s) %s" % [mod_i, mod.dir_name], LOG_NAME)
		mod_i += 1

	# Instance every mod and add it as a node to the Mod Loader
	for mod in mod_load_order:
		ModLoaderUtils.log_info("Initializing -> %s" % mod.manifest.get_mod_id(), LOG_NAME)
		_init_mod(mod)

	ModLoaderUtils.log_debug_json_print("mod data", mod_data, LOG_NAME)

	ModLoaderUtils.log_success("DONE: Completely finished loading mods", LOG_NAME)


# Loop over "res://mods" and add any mod zips to the unpacked virtual directory
# (UNPACKED_DIR)
func _load_mod_zips()->int:
	# Path to the games mod folder
	var game_mod_folder_path = ModLoaderUtils.get_local_folder_dir("mods")

	var dir = Directory.new()
	if dir.open(game_mod_folder_path) != OK:
		ModLoaderUtils.log_error("Can't open mod folder %s." % game_mod_folder_path, LOG_NAME)
		return -1
	if dir.list_dir_begin() != OK:
		ModLoaderUtils.log_error("Can't read mod folder %s." % game_mod_folder_path, LOG_NAME)
		return -1

	var has_shown_editor_warning = false

	var zipped_mods_count = 0
	# Get all zip folders inside the game mod folder
	while true:
		# Get the next file in the directory
		var mod_zip_file_name = dir.get_next()

		# If there is no more file
		if mod_zip_file_name == '':
			# Stop loading mod zip files
			break

		# Ignore files that aren't ZIP or PCK
		if mod_zip_file_name.get_extension() != "zip" && mod_zip_file_name.get_extension() != "pck":
			continue

		# If the current file is a directory
		if dir.current_is_dir():
			# Go to the next file
			continue

		var mod_folder_path = game_mod_folder_path.plus_file(mod_zip_file_name)
		var mod_folder_global_path = ProjectSettings.globalize_path(mod_folder_path)
		var is_mod_loaded_success = ProjectSettings.load_resource_pack(mod_folder_global_path, false)

		# Notifies developer of an issue with Godot, where using `load_resource_pack`
		# in the editor WIPES the entire virtual res:// directory the first time you
		# use it. This means that unpacked mods are no longer accessible, because they
		# no longer exist in the file system. So this warning basically says
		# "don't use ZIPs with unpacked mods!"
		# https://github.com/godotengine/godot/issues/19815
		# https://github.com/godotengine/godot/issues/16798
		if OS.has_feature("editor") && !has_shown_editor_warning:
			ModLoaderUtils.log_warning(str(
				"Loading any resource packs (.zip/.pck) with `load_resource_pack` will WIPE the entire virtual res:// directory. ",
				"If you have any unpacked mods in ", UNPACKED_DIR, ", they will not be loaded. ",
				"Please unpack your mod ZIPs instead, and add them to ", UNPACKED_DIR), LOG_NAME)
			has_shown_editor_warning = true

		ModLoaderUtils.log_debug(str("Found mod ZIP: ", mod_folder_global_path), LOG_NAME)

		# If there was an error loading the mod zip file
		if !is_mod_loaded_success:
			# Log the error and continue with the next file
			ModLoaderUtils.log_error(str(mod_zip_file_name, " failed to load."), LOG_NAME)
			continue

		# Mod successfully loaded!
		ModLoaderUtils.log_success(str(mod_zip_file_name, " loaded."), LOG_NAME)
		zipped_mods_count += 1

	dir.list_dir_end()
	return zipped_mods_count


# Loop over UNPACKED_DIR and triggers `_init_mod_data` for each mod directory,
# which adds their data to mod_data.
func _setup_mods()->int:
	# Path to the unpacked mods folder
	var unpacked_mods_path = UNPACKED_DIR

	var dir = Directory.new()
	if dir.open(unpacked_mods_path) != OK:
		ModLoaderUtils.log_error("Can't open unpacked mods folder %s." % unpacked_mods_path, LOG_NAME)
		return -1
	if dir.list_dir_begin() != OK:
		ModLoaderUtils.log_error("Can't read unpacked mods folder %s." % unpacked_mods_path, LOG_NAME)
		return -1

	var unpacked_mods_count = 0
	# Get all unpacked mod dirs
	while true:
		# Get the next file in the directory
		var mod_dir_name = dir.get_next()

		# If there is no more file
		if mod_dir_name == '':
			# Stop loading mod zip files
			break

		# Only check directories
		if !dir.current_is_dir():
			continue

		if mod_dir_name == "." || mod_dir_name == "..":
			continue

		# Init the mod data
		_init_mod_data(mod_dir_name)
		unpacked_mods_count += 1

	dir.list_dir_end()
	return unpacked_mods_count


# Load mod config JSONs from res://configs
func _load_mod_configs():
	var found_configs_count = 0
	var configs_path = ModLoaderUtils.get_local_folder_dir("configs")

	# CLI override, set with `--configs-path="C://path/configs"`
	# (similar to os_mods_path_override)
	if (os_configs_path_override != ""):
		configs_path = os_configs_path_override

	for dir_name in mod_data:
		var json_path = configs_path.plus_file(dir_name + ".json")
		var mod_config = ModLoaderUtils.get_json_as_dict(json_path)

		ModLoaderUtils.log_debug(str("Config JSON: Looking for config at path: ", json_path), LOG_NAME)

		if mod_config.size() > 0:
			found_configs_count += 1

			ModLoaderUtils.log_info(str("Config JSON: Found a config file: '", json_path, "'"), LOG_NAME)
			ModLoaderUtils.log_debug(str("Config JSON: File data: ", JSON.print(mod_config)), LOG_NAME)

			# Check `load_from` option. This lets you specify the name of a
			# different JSON file to load your config from. Must be in the same
			# dir. Means you can have multiple config files for a single mod
			# and switch between them quickly. Should include ".json" extension.
			# Ignored if the filename matches the mod ID, or is empty
			if mod_config.has("load_from"):
				var new_path = mod_config.load_from
				if new_path != "" && new_path != str(dir_name, ".json"):
					ModLoaderUtils.log_info(str("Config JSON: Following load_from path: ", new_path), LOG_NAME)
					var new_config = ModLoaderUtils.get_json_as_dict(configs_path + new_path)
					if new_config.size() > 0 != null:
						mod_config = new_config
						ModLoaderUtils.log_info(str("Config JSON: Loaded from custom json: ", new_path), LOG_NAME)
						ModLoaderUtils.log_debug(str("Config JSON: File data: ", JSON.print(mod_config)), LOG_NAME)
					else:
						ModLoaderUtils.log_error(str("Config JSON: ERROR - Could not load data via `load_from` for ", dir_name, ", at path: ", new_path), LOG_NAME)

			mod_data[dir_name].config = mod_config

	if found_configs_count > 0:
		ModLoaderUtils.log_success(str("Config JSON: Loaded ", str(found_configs_count), " config(s)"), LOG_NAME)
	else:
		ModLoaderUtils.log_info(str("Config JSON: No mod configs were found"), LOG_NAME)


# Add a mod's data to mod_data.
# The mod_folder_path is just the folder name that was added to UNPACKED_DIR,
# which depends on the name used in a given mod ZIP (eg "mods-unpacked/Folder-Name")
func _init_mod_data(mod_folder_path):
	# The file name should be a valid mod id
	var dir_name = ModLoaderUtils.get_file_name_from_path(mod_folder_path, false, true)

	# Path to the mod in UNPACKED_DIR (eg "res://mods-unpacked/My-Mod")
	var local_mod_path = str(UNPACKED_DIR, dir_name)

	var mod := ModData.new(local_mod_path)
	mod.dir_name = dir_name
	mod_data[dir_name] = mod

	# Get the mod file paths
	# Note: This was needed in the original version of this script, but it's
	# not needed anymore. It can be useful when debugging, but it's also an expensive
	# operation if a mod has a large number of files (eg. Brotato's Invasion mod,
	# which has ~1,000 files). That's why it's disabled by default
	if DEBUG_ENABLE_STORING_FILEPATHS:
		mod.file_paths = ModLoaderUtils.get_flat_view_dict(local_mod_path)


# Run dependency checks on a mod, checking any dependencies it lists in its
# mod_manifest (ie. its manifest.json file). If a mod depends on another mod that
# hasn't been loaded, the dependent mod won't be loaded.
func _check_dependencies(mod_id:String, deps:Array):
	ModLoaderUtils.log_debug(str("Checking dependencies - mod_id: ", mod_id, " dependencies: ", deps), LOG_NAME)

	# loop through each dependency
	for dependency_id in deps:
		# check if dependency is missing
		if(!mod_data.has(dependency_id)):
			_handle_missing_dependency(mod_id, dependency_id)
			continue

		var dependency = mod_data[dependency_id]
		var dependency_mod_manifest = mod_data[dependency_id].manifest

		# Init the importance score if it's missing

		# increase importance score by 1
		dependency.importance = dependency.importance + 1
		ModLoaderUtils.log_debug(str("Dependency -> ", dependency_id, " importance -> ", dependency.importance), LOG_NAME)

		# check if dependency has dependencies
		if(dependency_mod_manifest.dependencies.size() > 0):
			_check_dependencies(dependency_id, dependency_mod_manifest.dependencies)


# Handle missing dependencies: Sets `is_loadable` to false and logs an error
func _handle_missing_dependency(mod_id, dependency_id):
	ModLoaderUtils.log_error(str("Missing dependency - mod_id -> ", mod_id, " dependency_id -> ", dependency_id), LOG_NAME)
	# if mod is not present in the missing dependencies array
	if(!mod_missing_dependencies.has(mod_id)):
		# add it
		mod_missing_dependencies[mod_id] = []

	mod_missing_dependencies[mod_id].append(dependency_id)
	# Flag the mod so it's not loaded later
	mod_data[mod_id].is_loadable = false


# Get the load order of mods, using a custom sorter
func _get_load_order():
	var mod_data_array = mod_data.values()

	# Add loadable mods to the mod load order array
	for mod in mod_data_array:
		if(mod.is_loadable):
			mod_load_order.append(mod)

	# Sort mods by the importance value
	mod_load_order.sort_custom(self, "_compare_importance")


# Custom sorter that orders mods by important
func _compare_importance(a, b):
	# if true a -> b
	# if false b -> a
	if(a.importance > b.importance):
		return true
	else:
		return false


# Instance every mod and add it as a node to the Mod Loader.
# Runs mods in the order stored in mod_load_order.
func _init_mod(mod: ModData):
	var mod_main_path = mod.get_required_mod_file_path(ModData.required_mod_files.MOD_MAIN)

	ModLoaderUtils.log_debug("Loading script from -> %s" % mod_main_path, LOG_NAME)
	var mod_main_script = ResourceLoader.load(mod_main_path)
	ModLoaderUtils.log_debug("Loaded script -> %s" % mod_main_script, LOG_NAME)

	var mod_main_instance = mod_main_script.new(self)
	# mod_main_instance.name = mod.mod_manifest.extra.godot.id
	mod_main_instance.name = mod.manifest.get_mod_id()

	ModLoaderUtils.log_debug("Adding child -> %s" % mod_main_instance, LOG_NAME)
	add_child(mod_main_instance, true)


# Helpers
# =============================================================================

# Helper functions to build mods

# Add a script that extends a vanilla script. `child_script_path` should point
# to your mod's extender script, eg "MOD/extensions/singletons/utils.gd".
# Inside that extender script, it should include "extends {target}", where
# {target} is the vanilla path, eg: `extends "res://singletons/utils.gd"`.
# Note that your extender script doesn't have to follow the same directory path
# as the vanilla file, but it's good practice to do so.
func install_script_extension(child_script_path:String):
	# Check path to file exists
	if !File.new().file_exists(child_script_path):
		ModLoaderUtils.log_error("The child script path '%s' does not exist" % [child_script_path], LOG_NAME)
		return

	var child_script = ResourceLoader.load(child_script_path)

	# Force Godot to compile the script now.
	# We need to do this here to ensure that the inheritance chain is
	# properly set up, and multiple mods can chain-extend the same
	# class multiple times.
	# This is also needed to make Godot instantiate the extended class
	# when creating singletons.
	# The actual instance is thrown away.
	child_script.new()

	var parent_script = child_script.get_base_script()
	var parent_script_path = parent_script.resource_path
	ModLoaderUtils.log_info("Installing script extension: %s <- %s" % [parent_script_path, child_script_path], LOG_NAME)
	child_script.take_over_path(parent_script_path)


# Add a translation file, eg "mytranslation.en.translation". The translation
# file should have been created in Godot already: When you improt a CSV, such
# a file will be created for you.
func add_translation_from_resource(resource_path: String):
	var translation_object = load(resource_path)
	TranslationServer.add_translation(translation_object)
	ModLoaderUtils.log_info(str("Added Translation from Resource -> ", resource_path), LOG_NAME)


func append_node_in_scene(modified_scene, node_name:String = "", node_parent = null, instance_path:String = "", is_visible:bool = true):
	var new_node
	if instance_path != "":
		new_node = load(instance_path).instance()
	else:
		new_node = Node.instance()
	if node_name != "":
		new_node.name = node_name
	if is_visible == false:
		new_node.visible = false
	if node_parent != null:
		var tmp_node = modified_scene.get_node(node_parent)
		tmp_node.add_child(new_node)
		new_node.set_owner(modified_scene)
	else:
		modified_scene.add_child(new_node)
		new_node.set_owner(modified_scene)


func save_scene(modified_scene, scene_path:String):
	var packed_scene = PackedScene.new()
	packed_scene.pack(modified_scene)
	ModLoaderUtils.log_debug(str("packing scene -> ", packed_scene), LOG_NAME)
	packed_scene.take_over_path(scene_path)
	ModLoaderUtils.log_debug(str("save_scene - taking over path - new path -> ", packed_scene.resource_path), LOG_NAME)
	_saved_objects.append(packed_scene)


# Get the config data for a specific mod. Always returns a dictionary with two
# keys: `error` and `data`.
# Data (`data`) is either the full config, or data from a specific key if one was specified.
# Error (`error`) is 0 if there were no errors, or > 0 if the setting could not be retrieved:
# 0 = No errors
# 1 = Invalid mod ID
# 2 = No custom JSON. File probably does not exist. Defaults will be used if available
# 3 = No custom JSON, and key was invalid when trying to get the default from your manifest defaults (`extra.godot.config_defaults`)
# 4 = Invalid key, although config data does exists
func get_mod_config(mod_id:String = "", key:String = "")->Dictionary:
	var error_num = 0
	var error_msg = ""
	var data = {}
	var defaults = null

	# Invalid mod ID
	if !mod_data.has(mod_id):
		error_num = 1
		error_msg = str("ERROR - Mod ID was invalid: ", mod_id)

	# Mod ID is valid
	if error_num == 0:
		var config_data = mod_data[mod_id].config
		defaults = mod_data[mod_id].manifest.config_defaults

		# No custom JSON file
		if config_data.size() == 0:
			error_num = 2
			error_msg = str("WARNING - No config file for ", mod_id, ".json. ")
			if key == "":
				data = defaults
				error_msg += "Using defaults (extra.godot.config_defaults)"
			else:
				if defaults.has(key):
					data = defaults[key]
					error_msg += str("Using defaults for key '", key, "' (extra.godot.config_defaults.", key, ")")
				else:
					error_num = 3
					# error_msg = str("WARNING - No config file for Invalid key '", key, "' for mod ID: ", mod_id)
					error_msg += str("Requested key '", key, "' is not present in the defaults (extra.godot.config_defaults.", key, ")")

		# JSON file exists
		if error_num == 0:
			if key == "":
				data = config_data
			else:
				if config_data.has(key):
					data = config_data[key]
				else:
					error_num = 4
					error_msg = str("WARNING - Invalid key '", key, "' for mod ID: ", mod_id)

	# Log if any errors occured
	if error_num != 0:
		ModLoaderUtils.log_debug(str("Config: ", error_msg), mod_id)

	return {
		"error": error_num,
		"error_msg": error_msg,
		"data": data,
	}
