// Filtered TDB / singleton search for script menus.
// Lua cannot iterate types; this plugin can.
//
// Lua (after the plugin loads):
//   reflive.search_types("OniSense, !Letter")
//   reflive.search_singletons("Player")
//   reflive.tdb_count()

#include <cctype>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include <reframework/API.hpp>
#include <sol/sol.hpp>

using namespace reframework;

namespace {

// 0 = no cap. The Lua filter is the only cut.

struct Term {
    bool neg{false};
    std::string text;
};

struct Hit {
    std::string name;
    std::string kind;
    std::string type;
    void* address{nullptr};
};

static std::string trim(std::string_view s) {
    size_t a = 0;
    size_t b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) {
        ++a;
    }
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) {
        --b;
    }
    return std::string{s.substr(a, b - a)};
}

static std::string to_lower(std::string s) {
    for (char& c : s) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

static bool contains(std::string_view hay, std::string_view needle) {
    if (needle.empty()) {
        return true;
    }
    return to_lower(std::string{hay}).find(to_lower(std::string{needle})) != std::string::npos;
}

static std::vector<Term> parse_filter(std::string_view filter) {
    std::vector<Term> terms;
    std::string cur;
    auto flush = [&]() {
        auto t = trim(cur);
        cur.clear();
        if (t.empty()) {
            return;
        }
        Term term{};
        if (t[0] == '!') {
            term.neg = true;
            term.text = trim(t.substr(1));
        } else {
            term.text = std::move(t);
        }
        if (!term.text.empty()) {
            terms.push_back(std::move(term));
        }
    };
    for (char c : filter) {
        if (c == ',') {
            flush();
        } else {
            cur.push_back(c);
        }
    }
    flush();
    return terms;
}

static bool matches(std::string_view hay, const std::vector<Term>& terms) {
    if (terms.empty()) {
        return true;
    }
    for (const auto& term : terms) {
        const bool hit = contains(hay, term.text);
        if (term.neg && hit) {
            return false;
        }
        if (!term.neg && !hit) {
            return false;
        }
    }
    return true;
}

static uint32_t parse_max(sol::object max_obj) {
    if (!max_obj.valid() || max_obj == sol::lua_nil || !max_obj.is<double>()) {
        return 0;
    }
    auto n = static_cast<uint32_t>(max_obj.as<double>());
    return n;
}

static std::string parse_filter_text(sol::object filter_obj) {
    if (!filter_obj.valid() || filter_obj == sol::lua_nil) {
        return {};
    }
    if (filter_obj.is<std::string>()) {
        return trim(filter_obj.as<std::string>());
    }
    return {};
}

static std::string type_full_name(API::TypeDefinition* td) {
    if (!td) {
        return {};
    }
    try {
        return td->get_full_name();
    } catch (...) {
        return {};
    }
}

static sol::table to_lua(lua_State* l, const std::vector<Hit>& hits) {
    sol::state_view lua{l};
    sol::table out = lua.create_table(static_cast<int>(hits.size()), 0);
    for (size_t i = 0; i < hits.size(); ++i) {
        sol::table row = lua.create_table(0, 4);
        row["name"] = hits[i].name;
        row["kind"] = hits[i].kind;
        if (!hits[i].type.empty()) {
            row["type"] = hits[i].type;
        }
        if (hits[i].address) {
            row["address"] = static_cast<lua_Integer>(reinterpret_cast<std::uintptr_t>(hits[i].address));
        }
        out[i + 1] = row;
    }
    return out;
}

static sol::table search_types(sol::this_state s, sol::object filter_obj, sol::object max_obj) {
    const auto filter = parse_filter_text(filter_obj);
    if (filter.empty()) {
        return to_lua(s, {});
    }

    auto& api = API::get();
    if (!api) {
        return to_lua(s, {});
    }

    const auto terms = parse_filter(filter);
    const auto max_n = parse_max(max_obj);
    std::vector<Hit> hits;

    try {
        auto* tdb = api->tdb();
        if (!tdb) {
            return to_lua(s, {});
        }
        const auto n = tdb->get_num_types();
        for (uint32_t i = 0; i < n; ++i) {
            if (max_n > 0 && hits.size() >= max_n) {
                break;
            }
            auto* td = tdb->get_type(i);
            const auto name = type_full_name(td);
            if (name.empty() || !matches(name, terms)) {
                continue;
            }
            Hit hit{};
            hit.name = name;
            hit.kind = "type";
            hit.type = name;
            hits.push_back(std::move(hit));
        }
    } catch (...) {
        return to_lua(s, hits);
    }

    return to_lua(s, hits);
}

static sol::table search_singletons(sol::this_state s, sol::object filter_obj, sol::object max_obj) {
    auto& api = API::get();
    if (!api) {
        return to_lua(s, {});
    }

    const auto terms = parse_filter(parse_filter_text(filter_obj));
    const auto max_n = parse_max(max_obj);
    std::vector<Hit> hits;

    try {
        for (const auto& row : api->get_managed_singletons()) {
            if (max_n > 0 && hits.size() >= max_n) {
                break;
            }
            auto name = type_full_name(reinterpret_cast<API::TypeDefinition*>(row.t));
            if (name.empty() || !matches(name, terms)) {
                continue;
            }
            Hit hit{};
            hit.name = name;
            hit.kind = "managed";
            hit.type = name;
            hit.address = row.instance;
            hits.push_back(std::move(hit));
        }
        for (const auto& row : api->get_native_singletons()) {
            if (max_n > 0 && hits.size() >= max_n) {
                break;
            }
            std::string name = row.name ? row.name : "";
            if (name.empty()) {
                name = type_full_name(reinterpret_cast<API::TypeDefinition*>(row.t));
            }
            if (name.empty() || !matches(name, terms)) {
                continue;
            }
            Hit hit{};
            hit.name = name;
            hit.kind = "native";
            hit.type = name;
            hit.address = row.instance;
            hits.push_back(std::move(hit));
        }
    } catch (...) {
        return to_lua(s, hits);
    }

    return to_lua(s, hits);
}

static uint32_t tdb_count() {
    auto& api = API::get();
    if (!api) {
        return 0;
    }
    try {
        auto* tdb = api->tdb();
        return tdb ? tdb->get_num_types() : 0;
    } catch (...) {
        return 0;
    }
}

static void on_lua_state_created(lua_State* l) {
    try {
        API::LuaLock _{};
        sol::state_view lua{l};
        sol::table t = lua.create_named_table("reflive");
        t["search_types"] = [](sol::this_state s, sol::object filter, sol::object max_n) {
            return search_types(s, filter, max_n);
        };
        t["search_singletons"] = [](sol::this_state s, sol::object filter, sol::object max_n) {
            return search_singletons(s, filter, max_n);
        };
        t["tdb_count"] = []() {
            return tdb_count();
        };
        t["ready"] = []() {
            return true;
        };
    } catch (...) {
    }
}

} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    API::initialize(param);

    const auto* fn = param->functions;
    fn->on_lua_state_created(on_lua_state_created);
    fn->log_info("[reflive] loaded — reflive.search_types / search_singletons");

    return true;
}
