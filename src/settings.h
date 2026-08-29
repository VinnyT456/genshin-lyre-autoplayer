#pragma once

#include <string>
#include <vector>

// Simple local settings, stored as JSON in a file next to the executable
// (hud-settings.json) instead of macOS NSUserDefaults — so all state lives in
// the project folder and never leaks between machines or users.
namespace settings {

// Absolute path of the settings file (next to the running binary).
std::string path();

bool get_bool(const std::string& key, bool fallback);
void set_bool(const std::string& key, bool value);

std::vector<std::string> get_string_array(const std::string& key);
void set_string_array(const std::string& key, const std::vector<std::string>& value);

// True if the key exists at all (to distinguish "unset" from "false").
bool has(const std::string& key);

}  // namespace settings
