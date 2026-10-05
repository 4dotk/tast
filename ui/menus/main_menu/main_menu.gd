class_name MainMenu
extends Control

## Title screen for the game.

const TEST_ROOM_PATH := "res://test/test_room/test_room.tscn"

@onready var _title_label: Label = $Center/Box/TitleLabel
@onready var _test_button: Button = $Center/Box/TestButton
@onready var _exit_button: Button = $Center/Box/ExitButton


func _ready() -> void:
	_title_label.text = "They're Still There"
	_test_button.text = "Test"
	_exit_button.text = "Exit"
	# Test is a development shortcut: it only exists in debug builds.
	_test_button.visible = OS.is_debug_build()
	# Quitting does nothing in a browser.
	_exit_button.visible = not OS.has_feature("web")
	_test_button.pressed.connect(_on_test_button_pressed)
	_exit_button.pressed.connect(_on_exit_button_pressed)
	# Focus the first button that is actually visible (keyboard-only use).
	if _test_button.visible:
		_test_button.grab_focus()
	elif _exit_button.visible:
		_exit_button.grab_focus()


func _on_test_button_pressed() -> void:
	if OS.is_debug_build():
		# Path string, not preload: test/ is excluded from the web export.
		get_tree().change_scene_to_file(TEST_ROOM_PATH)


func _on_exit_button_pressed() -> void:
	get_tree().quit()
