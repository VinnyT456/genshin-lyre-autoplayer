#include "settings.h"

#include <mach-o/dyld.h>
#include <sys/stat.h>

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

// The parsed file is kept in memory, so reads cost no disk I/O or JSON
// parsing. It is re-read only if the file changes underneath us (edited by
// hand, or deleted to reset).
nlohmann::json g_cache;
bool g_loaded = false;
struct timespec g_stamp = {};
off_t g_size = -1;

bool file_changed_locked() {
    struct stat st {};
    if (stat(path().c_str(), &st) != 0) {
        return g_size != -1;
    }
    return st.st_size != g_size || st.st_mtimespec.tv_sec != g_stamp.tv_sec ||
           st.st_mtimespec.tv_nsec != g_stamp.tv_nsec;
}

void remember_stamp_locked() {
    struct stat st {};
    if (stat(path().c_str(), &st) == 0) {
        g_stamp = st.st_mtimespec;
        g_size = st.st_size;
    } else {
        g_stamp = {};
        g_size = -1;
    }
}

nlohmann::json& load_locked() {
    if (g_loaded && !file_changed_locked()) {
        return g_cache;
    }
    g_loaded = true;
    g_cache = nlohmann::json::object();
    std::ifstream in(path());
    if (in.is_open()) {
        try {
            nlohmann::json j;
            in >> j;
            if (j.is_object()) {
                g_cache = std::move(j);
            }
        } catch (...) {
            // corrupt file → start fresh
        }
    }
    remember_stamp_locked();
    return g_cache;
}

void save_locked(const nlohmann::json& j) {
    std::ofstream out(path(), std::ios::trunc);
    if (out.is_open()) {
        out << j.dump(2) << '\n';
    }
    out.close();
    remember_stamp_locked();
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
    const nlohmann::json& j = load_locked();
    if (j.contains(key) && j[key].is_boolean()) {
        return j[key].get<bool>();
    }
    return fallback;
}

void set_bool(const std::string& key, bool value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json& j = load_locked();
    j[key] = value;
    save_locked(j);
}

int get_int(const std::string& key, int fallback) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json& j = load_locked();
    if (j.contains(key) && j[key].is_number_integer()) {
        return j[key].get<int>();
    }
    return fallback;
}

void set_int(const std::string& key, int value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json& j = load_locked();
    j[key] = value;
    save_locked(j);
}

std::string get_string(const std::string& key, const std::string& fallback) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json& j = load_locked();
    if (j.contains(key) && j[key].is_string()) {
        return j[key].get<std::string>();
    }
    return fallback;
}

void set_string(const std::string& key, const std::string& value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json& j = load_locked();
    j[key] = value;
    save_locked(j);
}

std::string get_json(const std::string& key, const std::string& fallback) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json& j = load_locked();
    if (!j.contains(key)) {
        return fallback;
    }
    if (j[key].is_object() || j[key].is_array()) {
        return j[key].dump();
    }
    if (j[key].is_string()) {
        // Accept the pre-object format written by older dashboard builds.
        return j[key].get<std::string>();
    }
    return fallback;
}

void set_json(const std::string& key, const std::string& value) {
    std::lock_guard lock(g_mutex);
    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(value);
    } catch (...) {
        return;
    }
    nlohmann::json& j = load_locked();
    j[key] = std::move(parsed);
    save_locked(j);
}

std::vector<std::string> get_string_array(const std::string& key) {
    std::lock_guard lock(g_mutex);
    const nlohmann::json& j = load_locked();
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
    nlohmann::json& j = load_locked();
    j[key] = value;
    save_locked(j);
}

}  // namespace settings
