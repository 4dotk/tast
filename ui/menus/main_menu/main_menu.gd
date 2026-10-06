class_name MainMenu
extends Control

## Title screen for the game.

const TEST_ROOM_PATH := "res://test/test_room/test_room.tscn"
# Right-click level_4.tscn in the FileSystem dock > Copy Path, and paste it here if it differs.
const LEVEL_4_PATH := "res://levels/level_4.tscn"

@onready var _title_label: Label = $Center/Box/TitleLabel
@onready var _level_4_button: Button = $Center/Box/Level4Button
@onready var _test_button: Button = $Center/Box/TestButton
@onready var _exit_button: Button = $Center/Box/ExitButton


func _ready() -> void:
	_title_label.text = "They're Still There"
	_level_4_button.text = "Level 4"
	_test_button.text = "Test"
	_exit_button.text = "Exit"
	# Test is a development shortcut: it only exists in debug builds.
	_test_button.visible = OS.is_debug_build()
	# Quitting does nothing in a browser.
	_exit_button.visible = not OS.has_feature("web")
	_level_4_button.pressed.connect(_on_level_4_button_pressed)
	_test_button.pressed.connect(_on_test_button_pressed)
	_exit_button.pressed.connect(_on_exit_button_pressed)
	# Focus the first button that is actually visible (keyboard-only use).
	_level_4_button.grab_focus()


func _on_level_4_button_pressed() -> void:
	if not ResourceLoader.exists(LEVEL_4_PATH):
		push_error("MainMenu: Level 4 not found at %s - fix LEVEL_4_PATH." % LEVEL_4_PATH)
		return
	get_tree().change_scene_to_file(LEVEL_4_PATH)


func _on_test_button_pressed() -> void:
	if OS.is_debug_build():
		# Path string, not preload: test/ is excluded from the web export.
		get_tree().change_scene_to_file(TEST_ROOM_PATH)


func _on_exit_button_pressed() -> void:
	get_tree().quit()
