@tool
extends EditorPlugin

const AUTOLOAD := "Lucida"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/lucida/lucida.gd")


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD)
