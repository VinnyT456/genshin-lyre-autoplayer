#include "settings.h"

#include <mach-o/dyld.h>

#include <cstdint>
#include <fstream>
#include <mutex>

#include <nlohmann/json.hpp>

namespace settings {
namespace {

std::mutex g_mutex;

// Directory containing the running executable.
std::string executable_dir() {
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string buffer(size, '\0');
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
        return ".";
    }
    buffer.resize(std::char_traits<char>::length(buffer.c_str()));
    const auto slash = buffer.find_last_of('/');
    return slash == std::string::npos ? "." : buffer.substr(0, slash);
}

nlohmann::json load_locked() {
    std::ifstream in(path());
    if (!in.is_open()) {
        return nlohmann::json::object();
    }
    try {
        nlohmann::json j;
        in >> j;
        return j.is_object() ? j : nlohmann::json::object();
    } catch (...) {
        return nlohmann::json::object();  // corrupt file → start fresh
    }
}

void save_locked(const nlohmann::json& j) {
    std::ofstream out(path(), std::ios::trunc);
    if (out.is_open()) {
        out << j.dump(2) << '\n';
    }
}

}  // namespace

std::string path() {
    static const std::string p = executable_dir() + "/hud-settings.json";
    return p;
}

bool has(const std::string& key) {
    std::lock_guard lock(g_mutex);
    return load_locked().contains(key);
}

bool get_bool(const std::string& key, bool fallback) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json j = load_locked();
    if (j.contains(key) && j[key].is_boolean()) {
        return j[key].get<bool>();
    }
    return fallback;
}

void set_bool(const std::string& key, bool value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json j = load_locked();
    j[key] = value;
    save_locked(j);
}

std::string get_string(const std::string& key, const std::string& fallback) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json j = load_locked();
    if (j.contains(key) && j[key].is_string()) {
        return j[key].get<std::string>();
    }
    return fallback;
}

void set_string(const std::string& key, const std::string& value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json j = load_locked();
    j[key] = value;
    save_locked(j);
}

std::vector<std::string> get_string_array(const std::string& key) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json j = load_locked();
    std::vector<std::string> out;
    if (j.contains(key) && j[key].is_array()) {
        for (const auto& item : j[key]) {
            if (item.is_string()) {
                out.push_back(item.get<std::string>());
            }
        }
    }
    return out;
}

void set_string_array(const std::string& key, const std::vector<std::string>& value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json j = load_locked();
    j[key] = value;
    save_locked(j);
}

}  // namespace settings
