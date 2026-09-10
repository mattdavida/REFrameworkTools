// Filtered TDB / singleton search, plus cheap hops for Live View.
// Lua cannot iterate types or invoke without hitching; this plugin can.
//
// Lua (after the plugin loads):
//   reflive.search_types("OniSense, !Letter", max, offset)
//   reflive.search_singletons("Player", max, offset)
//   reflive.call_getters(address, { "getMasterPlayer", "get_Context" })
//   reflive.chain({ singleton = "app.PlayerManager", steps = { { type = "method", name = "getMasterPlayer" } } })
//   reflive.summary(address, cap)
//   reflive.array_elements(address, offset, count)
//   reflive.resolve(address)
//   reflive.tdb_count()
//   reflive.agent_start("mhwilds")
//   reflive.agent_stop()

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <Windows.h>
#endif

#include <reframework/API.hpp>
#include <sol/sol.hpp>

using namespace reframework;

namespace {

constexpr uint32_t CHAIN_CAP = 256;
constexpr uint32_t ARRAY_DEFAULT = 32;
constexpr uint32_t SUMMARY_DEFAULT = 40;

struct Term {
    bool neg{false};
    std::string text;
};

struct Hit {
    std::string name;
    std::string kind;
    std::string type;
    std::string parent;
    void* address{nullptr};
    uint32_t fields{0};
    uint32_t methods{0};
    bool valuetype{false};
    bool is_enum{false};
    bool has_meta{false};
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

static uint32_t parse_u32(sol::object obj, uint32_t fallback = 0) {
    if (!obj.valid() || obj == sol::lua_nil) {
        return fallback;
    }
    if (obj.is<lua_Integer>()) {
        auto n = obj.as<lua_Integer>();
        return n > 0 ? static_cast<uint32_t>(n) : 0;
    }
    if (obj.is<double>()) {
        auto n = obj.as<double>();
        return n > 0 ? static_cast<uint32_t>(n) : 0;
    }
    return fallback;
}

static std::uintptr_t parse_address(sol::object obj) {
    if (!obj.valid() || obj == sol::lua_nil) {
        return 0;
    }
    if (obj.is<lua_Integer>()) {
        auto n = obj.as<lua_Integer>();
        return n > 0 ? static_cast<std::uintptr_t>(n) : 0;
    }
    if (obj.is<double>()) {
        auto n = obj.as<double>();
        return n > 0 ? static_cast<std::uintptr_t>(n) : 0;
    }
    if (obj.is<std::string>()) {
        auto s = trim(obj.as<std::string>());
        if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
            return static_cast<std::uintptr_t>(std::strtoull(s.c_str(), nullptr, 16));
        }
        return static_cast<std::uintptr_t>(std::strtoull(s.c_str(), nullptr, 10));
    }
    return 0;
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

static std::string short_type(const std::string& full) {
    if (full.empty()) {
        return "?";
    }
    auto gen = full.find('<');
    auto cut = gen == std::string::npos ? full.size() : gen;
    auto pos = full.rfind('.', cut);
    if (pos == std::string::npos) {
        return full;
    }
    return full.substr(pos + 1);
}

static std::string to_hex(void* p) {
    if (!p) {
        return {};
    }
    char buf[32];
    std::snprintf(buf, sizeof(buf), "0x%llX", static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(p)));
    return buf;
}

static void fill_type_meta(Hit& hit, API::TypeDefinition* td) {
    if (!td) {
        return;
    }
    try {
        hit.parent = type_full_name(td->get_parent_type());
        hit.fields = td->get_num_fields();
        hit.methods = td->get_num_methods();
        hit.valuetype = td->is_valuetype();
        hit.is_enum = td->is_enum();
        hit.has_meta = true;
    } catch (...) {
    }
}

static void push_hit(sol::table& row, const Hit& hit) {
    row["name"] = hit.name;
    row["kind"] = hit.kind;
    if (!hit.type.empty()) {
        row["type"] = hit.type;
        row["typeName"] = hit.type;
    }
    if (hit.address) {
        row["address"] = static_cast<lua_Integer>(reinterpret_cast<std::uintptr_t>(hit.address));
        row["hex"] = to_hex(hit.address);
    }
    if (hit.has_meta) {
        if (!hit.parent.empty()) {
            row["parent"] = hit.parent;
        }
        row["fields"] = static_cast<lua_Integer>(hit.fields);
        row["methods"] = static_cast<lua_Integer>(hit.methods);
        row["valuetype"] = hit.valuetype;
        row["enum"] = hit.is_enum;
    }
}

static sol::table to_lua(lua_State* l, const std::vector<Hit>& hits) {
    sol::state_view lua{l};
    sol::table out = lua.create_table(static_cast<int>(hits.size()), 0);
    for (size_t i = 0; i < hits.size(); ++i) {
        sol::table row = lua.create_table(0, 10);
        push_hit(row, hits[i]);
        out[i + 1] = row;
    }
    return out;
}

static void push_object_row(sol::table& row, API::ManagedObject* obj, std::string_view name, std::string_view kind) {
    Hit hit{};
    hit.name = std::string{name};
    hit.kind = std::string{kind};
    if (obj) {
        auto* td = obj->get_type_definition();
        hit.type = type_full_name(td);
        hit.address = obj;
        fill_type_meta(hit, td);
    }
    push_hit(row, hit);
}

static API::ManagedObject* as_managed(void* p) {
    if (!p) {
        return nullptr;
    }
    auto* obj = reinterpret_cast<API::ManagedObject*>(p);
    try {
        if (obj->is_managed_object()) {
            return obj;
        }
    } catch (...) {
    }
    return nullptr;
}

static API::ManagedObject* object_from_address(std::uintptr_t addr) {
    return as_managed(reinterpret_cast<void*>(addr));
}

static API::ManagedObject* find_managed_singleton(const std::string& name) {
    auto& api = API::get();
    if (!api || name.empty()) {
        return nullptr;
    }
    try {
        if (auto* obj = api->get_managed_singleton(name)) {
            if (auto* mo = as_managed(obj)) {
                return mo;
            }
        }
        for (const auto& row : api->get_managed_singletons()) {
            auto tn = type_full_name(reinterpret_cast<API::TypeDefinition*>(row.t));
            if (tn == name) {
                if (auto* mo = as_managed(row.instance)) {
                    return mo;
                }
            }
        }
    } catch (...) {
    }
    return nullptr;
}

static API::Method* find_method0(API::TypeDefinition* td, const std::string& name) {
    if (!td || name.empty()) {
        return nullptr;
    }
    for (auto* cur = td; cur; cur = cur->get_parent_type()) {
        try {
            if (auto* m = cur->find_method(name)) {
                if (m->get_num_params() == 0) {
                    return m;
                }
            }
        } catch (...) {
        }
    }
    return nullptr;
}

static API::Method* find_method1(API::TypeDefinition* td, const std::string& name) {
    if (!td || name.empty()) {
        return nullptr;
    }
    for (auto* cur = td; cur; cur = cur->get_parent_type()) {
        try {
            if (auto* m = cur->find_method(name)) {
                if (m->get_num_params() == 1) {
                    return m;
                }
            }
        } catch (...) {
        }
    }
    return nullptr;
}

static API::Field* find_field_walk(API::TypeDefinition* td, const std::string& name) {
    if (!td || name.empty()) {
        return nullptr;
    }
    for (auto* cur = td; cur; cur = cur->get_parent_type()) {
        try {
            if (auto* f = cur->find_field(name)) {
                return f;
            }
        } catch (...) {
        }
    }
    return nullptr;
}

static bool is_leaf_type(API::TypeDefinition* td) {
    if (!td) {
        return true;
    }
    try {
        return td->is_valuetype() || td->is_primitive() || td->is_enum();
    } catch (...) {
        return true;
    }
}

static const std::vector<void*> kNoArgs{};

static API::ManagedObject* invoke_object(API::Method* method, API::ManagedObject* obj, const std::vector<void*>& args = kNoArgs) {
    if (!method) {
        return nullptr;
    }
    try {
        auto* rt = method->get_return_type();
        if (is_leaf_type(rt) && rt && type_full_name(rt) != "System.String") {
            return nullptr;
        }
        auto ret = method->invoke(obj, args);
        if (ret.exception_thrown) {
            return nullptr;
        }
        return as_managed(ret.ptr);
    } catch (...) {
        return nullptr;
    }
}

static std::string format_invoke_value(API::Method* method, const InvokeRet& ret) {
    if (!method || ret.exception_thrown) {
        return {};
    }
    auto name = type_full_name(method->get_return_type());
    if (name == "System.Boolean") {
        return ret.byte ? "true" : "false";
    }
    if (name == "System.Byte" || name == "System.SByte") {
        return std::to_string(static_cast<int>(ret.byte));
    }
    if (name == "System.Int16" || name == "System.UInt16") {
        return std::to_string(ret.word);
    }
    if (name == "System.Int32" || name == "System.UInt32") {
        return std::to_string(ret.dword);
    }
    if (name == "System.Int64" || name == "System.UInt64") {
        return std::to_string(ret.qword);
    }
    if (name == "System.Single") {
        return std::to_string(ret.f);
    }
    if (name == "System.Double") {
        return std::to_string(ret.d);
    }
    if (name == "System.Void" || name.empty()) {
        return {};
    }
    return {};
}

static std::string format_field_value(API::Field* field, void* data) {
    if (!field || !data) {
        return {};
    }
    auto name = type_full_name(field->get_type());
    try {
        if (name == "System.Boolean") {
            return *reinterpret_cast<bool*>(data) ? "true" : "false";
        }
        if (name == "System.Byte") {
            return std::to_string(*reinterpret_cast<uint8_t*>(data));
        }
        if (name == "System.SByte") {
            return std::to_string(*reinterpret_cast<int8_t*>(data));
        }
        if (name == "System.Int16") {
            return std::to_string(*reinterpret_cast<int16_t*>(data));
        }
        if (name == "System.UInt16") {
            return std::to_string(*reinterpret_cast<uint16_t*>(data));
        }
        if (name == "System.Int32") {
            return std::to_string(*reinterpret_cast<int32_t*>(data));
        }
        if (name == "System.UInt32") {
            return std::to_string(*reinterpret_cast<uint32_t*>(data));
        }
        if (name == "System.Int64") {
            return std::to_string(*reinterpret_cast<int64_t*>(data));
        }
        if (name == "System.UInt64") {
            return std::to_string(*reinterpret_cast<uint64_t*>(data));
        }
        if (name == "System.Single") {
            return std::to_string(*reinterpret_cast<float*>(data));
        }
        if (name == "System.Double") {
            return std::to_string(*reinterpret_cast<double*>(data));
        }
    } catch (...) {
    }
    return {};
}

static API::ManagedObject* field_as_object(API::Field* field, API::ManagedObject* obj) {
    if (!field || !obj) {
        return nullptr;
    }
    try {
        auto* ft = field->get_type();
        if (is_leaf_type(ft) && type_full_name(ft) != "System.String") {
            return nullptr;
        }
        auto* owner = obj->get_type_definition();
        void* data = field->get_data_raw(obj, owner && owner->is_valuetype());
        if (!data) {
            return nullptr;
        }
        return as_managed(*reinterpret_cast<void**>(data));
    } catch (...) {
        return nullptr;
    }
}

static int32_t array_length(API::ManagedObject* obj) {
    if (!obj) {
        return -1;
    }
    try {
        auto* td = obj->get_type_definition();
        for (const char* name : {"get_Length", "get_Count"}) {
            if (auto* m = find_method0(td, name)) {
                auto ret = m->invoke(obj, kNoArgs);
                if (!ret.exception_thrown) {
                    return static_cast<int32_t>(ret.dword);
                }
            }
        }
    } catch (...) {
    }
    return -1;
}

static API::ManagedObject* array_item(API::ManagedObject* obj, int32_t index) {
    if (!obj) {
        return nullptr;
    }
    try {
        auto* td = obj->get_type_definition();
        int32_t i = index;
        if (auto* m = find_method1(td, "GetValue")) {
            if (auto* out = invoke_object(m, obj, {&i})) {
                return out;
            }
        }
        if (auto* m = find_method1(td, "get_Item")) {
            return invoke_object(m, obj, {&i});
        }
    } catch (...) {
    }
    return nullptr;
}

static bool is_system_array(API::TypeDefinition* td) {
    if (!td) {
        return false;
    }
    try {
        return td->is_derived_from("System.Array");
    } catch (...) {
        return false;
    }
}

static std::string table_string(const sol::table& t, const char* key) {
    sol::object o = t[key];
    if (o.valid() && o.is<std::string>()) {
        return o.as<std::string>();
    }
    return {};
}

static std::vector<std::string> parse_name_list(sol::object obj) {
    std::vector<std::string> out;
    if (!obj.valid() || !obj.is<sol::table>()) {
        return out;
    }
    sol::table t = obj;
    const auto n = t.size();
    out.reserve(n);
    for (size_t i = 1; i <= n; ++i) {
        sol::object v = t[i];
        if (v.valid() && v.is<std::string>()) {
            auto s = trim(v.as<std::string>());
            if (!s.empty()) {
                out.push_back(std::move(s));
            }
        }
    }
    return out;
}

static sol::table empty_list(lua_State* l) {
    sol::state_view lua{l};
    return lua.create_table();
}

static sol::table error_table(lua_State* l, std::string_view msg) {
    sol::state_view lua{l};
    sol::table out = lua.create_table();
    out["error"] = std::string{msg};
    return out;
}

static sol::table search_types(sol::this_state s, sol::object filter_obj, sol::object max_obj, sol::object offset_obj) {
    const auto filter = parse_filter_text(filter_obj);
    if (filter.empty()) {
        return to_lua(s, {});
    }

    auto& api = API::get();
    if (!api) {
        return to_lua(s, {});
    }

    const auto terms = parse_filter(filter);
    const auto max_n = parse_u32(max_obj);
    auto skip = parse_u32(offset_obj);
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
            if (skip > 0) {
                --skip;
                continue;
            }
            Hit hit{};
            hit.name = name;
            hit.kind = "type";
            hit.type = name;
            fill_type_meta(hit, td);
            hits.push_back(std::move(hit));
        }
    } catch (...) {
        return to_lua(s, hits);
    }

    return to_lua(s, hits);
}

static sol::table search_singletons(sol::this_state s, sol::object filter_obj, sol::object max_obj, sol::object offset_obj) {
    auto& api = API::get();
    if (!api) {
        return to_lua(s, {});
    }

    const auto terms = parse_filter(parse_filter_text(filter_obj));
    const auto max_n = parse_u32(max_obj);
    auto skip = parse_u32(offset_obj);
    std::vector<Hit> hits;

    auto take = [&](Hit&& hit) -> bool {
        if (skip > 0) {
            --skip;
            return true;
        }
        if (max_n > 0 && hits.size() >= max_n) {
            return false;
        }
        hits.push_back(std::move(hit));
        return max_n == 0 || hits.size() < max_n;
    };

    try {
        for (const auto& row : api->get_managed_singletons()) {
            auto* td = reinterpret_cast<API::TypeDefinition*>(row.t);
            auto name = type_full_name(td);
            if (name.empty() || !matches(name, terms)) {
                continue;
            }
            Hit hit{};
            hit.name = name;
            hit.kind = "managed";
            hit.type = name;
            hit.address = row.instance;
            fill_type_meta(hit, td);
            if (!take(std::move(hit))) {
                return to_lua(s, hits);
            }
        }
        for (const auto& row : api->get_native_singletons()) {
            std::string name = row.name ? row.name : "";
            auto* td = reinterpret_cast<API::TypeDefinition*>(row.t);
            if (name.empty()) {
                name = type_full_name(td);
            }
            if (name.empty() || !matches(name, terms)) {
                continue;
            }
            Hit hit{};
            hit.name = name;
            hit.kind = "native";
            hit.type = name;
            hit.address = row.instance;
            fill_type_meta(hit, td);
            if (!take(std::move(hit))) {
                return to_lua(s, hits);
            }
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

static sol::object resolve_object(sol::this_state s, sol::object addr_obj) {
    auto* obj = object_from_address(parse_address(addr_obj));
    if (!obj) {
        return sol::lua_nil;
    }
    sol::state_view lua{s};
    sol::table row = lua.create_table(0, 10);
    push_object_row(row, obj, type_full_name(obj->get_type_definition()), "managed");
    return row;
}

static sol::table call_getters(sol::this_state s, sol::object addr_obj, sol::object names_obj) {
    auto* obj = object_from_address(parse_address(addr_obj));
    if (!obj) {
        return empty_list(s);
    }
    const auto names = parse_name_list(names_obj);
    if (names.empty()) {
        return empty_list(s);
    }

    sol::state_view lua{s};
    sol::table out = lua.create_table();
    int n = 0;
    try {
        auto* td = obj->get_type_definition();
        for (const auto& name : names) {
            auto* method = find_method0(td, name);
            auto* child = invoke_object(method, obj);
            if (!child) {
                continue;
            }
            sol::table row = lua.create_table(0, 10);
            push_object_row(row, child, name, "get");
            out[++n] = row;
        }
    } catch (...) {
    }
    return out;
}

static sol::table crawl_fields(sol::this_state s, sol::object addr_obj, sol::object cap_obj) {
    auto* obj = object_from_address(parse_address(addr_obj));
    if (!obj) {
        return empty_list(s);
    }
    auto cap = parse_u32(cap_obj, 48);
    if (cap == 0) {
        cap = 48;
    }

    sol::state_view lua{s};
    sol::table out = lua.create_table();
    int n = 0;
    try {
        auto* td = obj->get_type_definition();
        for (auto* cur = td; cur && static_cast<uint32_t>(n) < cap; cur = cur->get_parent_type()) {
            for (auto* field : cur->get_fields()) {
                if (!field) {
                    continue;
                }
                bool skip = false;
                try {
                    skip = field->is_static() || field->is_literal();
                } catch (...) {
                    skip = true;
                }
                if (skip) {
                    continue;
                }
                const char* raw_name = nullptr;
                try {
                    raw_name = field->get_name();
                } catch (...) {
                    continue;
                }
                if (!raw_name) {
                    continue;
                }
                auto* child = field_as_object(field, obj);
                if (!child) {
                    continue;
                }
                sol::table row = lua.create_table(0, 10);
                push_object_row(row, child, raw_name, "field");
                out[++n] = row;
                if (static_cast<uint32_t>(n) >= cap) {
                    break;
                }
            }
        }
    } catch (...) {
    }
    return out;
}

static bool values_equal(const std::string& got, const std::string& want) {
    auto a = to_lower(got);
    auto b = to_lower(want);
    if (a == b) {
        return true;
    }
    if (b == "true" && (a == "1" || a == "true")) {
        return true;
    }
    if (b == "false" && (a == "0" || a == "false")) {
        return true;
    }
    return false;
}

static sol::table objects_to_results(lua_State* l, const std::vector<API::ManagedObject*>& objs) {
    sol::state_view lua{l};
    sol::table results = lua.create_table(static_cast<int>(objs.size()), 0);
    int n = 0;
    for (auto* obj : objs) {
        if (!obj) {
            continue;
        }
        sol::table row = lua.create_table(0, 10);
        push_object_row(row, obj, type_full_name(obj->get_type_definition()), "managed");
        results[++n] = row;
    }
    sol::table out = lua.create_table();
    out["count"] = n;
    out["results"] = results;
    return out;
}

static void cap_current(std::vector<API::ManagedObject*>& current) {
    if (current.size() > CHAIN_CAP) {
        current.resize(CHAIN_CAP);
    }
}

static std::string chain_step_label(size_t si, const std::string& step_type, const sol::table& step) {
    std::string label = std::to_string(si) + " " + (step_type.empty() ? "unknown" : step_type);
    auto name = table_string(step, "name");
    if (name.empty()) {
        name = table_string(step, "method");
    }
    if (!name.empty()) {
        label += " " + name;
    }
    return label;
}

static sol::table chain(sol::this_state s, sol::object spec_obj) {
    if (!spec_obj.valid() || !spec_obj.is<sol::table>()) {
        return error_table(s, "chain expects { singleton|address, steps }");
    }

    sol::table spec = spec_obj;
    API::ManagedObject* start = nullptr;

    auto singleton_name = table_string(spec, "singleton");
    if (singleton_name.empty()) {
        singleton_name = table_string(spec, "start");
    }
    if (!singleton_name.empty()) {
        start = find_managed_singleton(singleton_name);
    }
    if (!start) {
        start = object_from_address(parse_address(spec["address"]));
    }
    if (!start) {
        sol::object start_obj = spec["start"];
        if (start_obj.valid() && start_obj.is<sol::table>()) {
            sol::table st = start_obj;
            auto nested = table_string(st, "singleton");
            if (!nested.empty()) {
                start = find_managed_singleton(nested);
            }
            if (!start) {
                start = object_from_address(parse_address(st["address"]));
            }
        }
    }
    if (!start) {
        return error_table(s, "Could not resolve start object");
    }

    sol::object steps_obj = spec["steps"];
    std::vector<API::ManagedObject*> current{start};

    if (!steps_obj.valid() || steps_obj == sol::lua_nil) {
        return objects_to_results(s, current);
    }
    if (!steps_obj.is<sol::table>()) {
        return error_table(s, "steps must be an array");
    }

    sol::table steps = steps_obj;
    const auto step_n = steps.size();

    std::string step_label;
    try {
        for (size_t si = 1; si <= step_n; ++si) {
            sol::object step_obj = steps[si];
            if (!step_obj.valid() || !step_obj.is<sol::table>()) {
                continue;
            }
            sol::table step = step_obj;
            auto step_type = table_string(step, "type");
            step_label = chain_step_label(si, step_type, step);
            if (step_type.empty()) {
                return error_table(s, "step " + step_label + " missing type");
            }

            if (step_type == "method") {
                auto name = table_string(step, "name");
                if (name.empty()) {
                    return error_table(s, "method step missing name");
                }
                std::vector<API::ManagedObject*> next;
                for (auto* obj : current) {
                    auto* child = invoke_object(find_method0(obj->get_type_definition(), name), obj);
                    if (child) {
                        next.push_back(child);
                    }
                }
                current = std::move(next);
            } else if (step_type == "field") {
                auto name = table_string(step, "name");
                if (name.empty()) {
                    return error_table(s, "field step missing name");
                }
                std::vector<API::ManagedObject*> next;
                for (auto* obj : current) {
                    auto* child = field_as_object(find_field_walk(obj->get_type_definition(), name), obj);
                    if (child) {
                        next.push_back(child);
                    }
                }
                current = std::move(next);
            } else if (step_type == "array") {
                const auto offset = parse_u32(step["offset"]);
                auto count = parse_u32(step["count"], ARRAY_DEFAULT);
                if (count == 0) {
                    count = ARRAY_DEFAULT;
                }
                std::vector<API::ManagedObject*> next;
                for (auto* obj : current) {
                    if (!is_system_array(obj->get_type_definition())) {
                        continue;
                    }
                    const auto len = array_length(obj);
                    if (len <= 0) {
                        continue;
                    }
                    const auto begin = static_cast<int32_t>(offset);
                    auto end = begin + static_cast<int32_t>(count);
                    if (end > len) {
                        end = len;
                    }
                    for (int32_t i = begin; i < end; ++i) {
                        if (auto* el = array_item(obj, i)) {
                            next.push_back(el);
                        }
                        if (next.size() >= CHAIN_CAP) {
                            break;
                        }
                    }
                    if (next.size() >= CHAIN_CAP) {
                        break;
                    }
                }
                current = std::move(next);
            } else if (step_type == "filter") {
                auto method_name = table_string(step, "method");
                if (method_name.empty()) {
                    return error_table(s, "filter step missing method");
                }
                auto want = table_string(step, "value");
                if (want.empty()) {
                    want = "true";
                }
                std::vector<API::ManagedObject*> next;
                for (auto* obj : current) {
                    auto* method = find_method0(obj->get_type_definition(), method_name);
                    if (!method) {
                        continue;
                    }
                    try {
                        auto ret = method->invoke(obj, kNoArgs);
                        if (ret.exception_thrown) {
                            continue;
                        }
                        auto got = format_invoke_value(method, ret);
                        if (got.empty()) {
                            if (as_managed(ret.ptr)) {
                                got = "true";
                            }
                        }
                        if (values_equal(got, want)) {
                            next.push_back(obj);
                        }
                    } catch (...) {
                    }
                }
                current = std::move(next);
            } else if (step_type == "collect") {
                auto methods = parse_name_list(step["methods"]);
                sol::state_view lua{s};
                sol::table results = lua.create_table();
                int n = 0;
                for (auto* obj : current) {
                    sol::table entry = lua.create_table();
                    push_object_row(entry, obj, type_full_name(obj->get_type_definition()), "managed");
                    sol::table values = lua.create_table();
                    auto* td = obj->get_type_definition();
                    for (const auto& name : methods) {
                        auto* method = find_method0(td, name);
                        if (!method) {
                            values[name] = sol::lua_nil;
                            continue;
                        }
                        if (auto* child = invoke_object(method, obj)) {
                            sol::table child_row = lua.create_table(0, 10);
                            push_object_row(child_row, child, name, "get");
                            child_row["isObject"] = true;
                            values[name] = child_row;
                            continue;
                        }
                        try {
                            auto ret = method->invoke(obj, kNoArgs);
                            auto got = format_invoke_value(method, ret);
                            if (!got.empty()) {
                                values[name] = got;
                            } else {
                                values[name] = sol::lua_nil;
                            }
                        } catch (...) {
                            values[name] = sol::lua_nil;
                        }
                    }
                    entry["values"] = values;
                    results[++n] = entry;
                }
                sol::table out = lua.create_table();
                out["count"] = n;
                out["results"] = results;
                return out;
            } else {
                return error_table(s, "unknown step type: " + step_type);
            }

            cap_current(current);
            if (current.empty()) {
                return error_table(s, "Chain broken at step " + step_label + ": no results");
            }
        }
    } catch (const std::exception& e) {
        return error_table(s, "chain failed at step " + step_label + ": " + e.what());
    } catch (...) {
        return error_table(s, "chain failed at step " + step_label);
    }

    return objects_to_results(s, current);
}

static bool skip_method_name(std::string_view name) {
    return name == ".ctor" || name == ".cctor" || name == "Finalize" || name == "MemberwiseClone" || name == "Equals" ||
           name == "GetHashCode" || name == "GetType" || name.find(">g__") != std::string_view::npos ||
           name.find("<>") != std::string_view::npos;
}

static sol::table summary(sol::this_state s, sol::object addr_obj, sol::object cap_obj) {
    auto* obj = object_from_address(parse_address(addr_obj));
    if (!obj) {
        return error_table(s, "Could not resolve object");
    }

    const auto cap = parse_u32(cap_obj, SUMMARY_DEFAULT);
    sol::state_view lua{s};
    sol::table out = lua.create_table();

    try {
        auto* td = obj->get_type_definition();
        const auto type_name = type_full_name(td);
        out["type"] = type_name;
        out["typeName"] = type_name;
        out["kind"] = "managed";
        out["address"] = static_cast<lua_Integer>(reinterpret_cast<std::uintptr_t>(obj));
        out["hex"] = to_hex(obj);
        if (td) {
            auto parent = type_full_name(td->get_parent_type());
            if (!parent.empty()) {
                out["parent"] = parent;
            }
            out["fields"] = static_cast<lua_Integer>(td->get_num_fields());
            out["methods"] = static_cast<lua_Integer>(td->get_num_methods());
            out["valuetype"] = td->is_valuetype();
            out["enum"] = td->is_enum();
        }

        sol::table field_lines = lua.create_table();
        int fi = 0;
        for (auto* cur = td; cur && (cap == 0 || static_cast<uint32_t>(fi) < cap); cur = cur->get_parent_type()) {
            for (auto* field : cur->get_fields()) {
                if (!field) {
                    continue;
                }
                const char* raw_name = nullptr;
                try {
                    raw_name = field->get_name();
                } catch (...) {
                    continue;
                }
                if (!raw_name) {
                    continue;
                }
                auto* ft = field->get_type();
                const auto ft_name = type_full_name(ft);
                std::string line = std::string{raw_name} + ": " + short_type(ft_name);
                bool is_static = false;
                try {
                    is_static = field->is_static();
                } catch (...) {
                }
                if (is_static) {
                    line += " [static]";
                } else {
                    try {
                        void* data = field->get_data_raw(obj, td && td->is_valuetype());
                        auto value = format_field_value(field, data);
                        if (!value.empty()) {
                            line += " = " + value;
                        }
                    } catch (...) {
                    }
                }
                field_lines[++fi] = line;
                if (cap > 0 && static_cast<uint32_t>(fi) >= cap) {
                    break;
                }
            }
        }
        out["field_lines"] = field_lines;

        sol::table method_lines = lua.create_table();
        int mi = 0;
        for (auto* cur = td; cur && (cap == 0 || static_cast<uint32_t>(mi) < cap); cur = cur->get_parent_type()) {
            for (auto* method : cur->get_methods()) {
                if (!method) {
                    continue;
                }
                const char* raw_name = nullptr;
                try {
                    raw_name = method->get_name();
                } catch (...) {
                    continue;
                }
                if (!raw_name || skip_method_name(raw_name)) {
                    continue;
                }
                uint32_t params = 0;
                try {
                    params = method->get_num_params();
                } catch (...) {
                    continue;
                }
                auto ret = short_type(type_full_name(method->get_return_type()));
                std::string line = std::string{raw_name} + "(";
                if (params > 0) {
                    line += std::to_string(params);
                }
                line += ") -> " + ret;
                method_lines[++mi] = line;
                if (cap > 0 && static_cast<uint32_t>(mi) >= cap) {
                    break;
                }
            }
        }
        out["method_lines"] = method_lines;
    } catch (...) {
        out["error"] = "summary failed";
    }

    return out;
}

static sol::table array_elements(sol::this_state s, sol::object addr_obj, sol::object offset_obj, sol::object count_obj) {
    auto* obj = object_from_address(parse_address(addr_obj));
    if (!obj) {
        return error_table(s, "Could not resolve object");
    }
    if (!is_system_array(obj->get_type_definition())) {
        return error_table(s, "Object is not a System.Array (use _items / get_Array for List)");
    }

    const auto offset = parse_u32(offset_obj);
    auto count = parse_u32(count_obj, ARRAY_DEFAULT);
    if (count == 0) {
        count = ARRAY_DEFAULT;
    }

    sol::state_view lua{s};
    sol::table out = lua.create_table();
    const auto len = array_length(obj);
    if (len < 0) {
        return error_table(s, "Could not read array length");
    }

    const auto begin = static_cast<int32_t>(offset);
    auto end = begin + static_cast<int32_t>(count);
    if (end > len) {
        end = len;
    }

    sol::table elements = lua.create_table();
    int n = 0;
    for (int32_t i = begin; i < end; ++i) {
        sol::table row = lua.create_table();
        row["index"] = i;
        if (auto* el = array_item(obj, i)) {
            push_object_row(row, el, type_full_name(el->get_type_definition()), "element");
            row["isObject"] = true;
            row["isNull"] = false;
        } else {
            row["isObject"] = false;
            row["isNull"] = true;
        }
        elements[++n] = row;
    }

    out["total"] = len;
    out["offset"] = static_cast<lua_Integer>(offset);
    out["count"] = n;
    out["hasMore"] = end < len;
    out["elements"] = elements;
    return out;
}

#ifdef _WIN32
static std::wstring widen(const std::string& s) {
    if (s.empty()) {
        return L"";
    }
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (n <= 0) {
        return L"";
    }
    std::wstring out((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), n);
    return out;
}

static std::string narrow(const std::wstring& s) {
    if (s.empty()) {
        return "";
    }
    const int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) {
        return "";
    }
    std::string out((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), n, nullptr, nullptr);
    return out;
}

static bool safe_game_slug(const std::string& s) {
    if (s.empty() || s.size() > 80) {
        return false;
    }
    for (unsigned char c : s) {
        if (!std::isalnum(c) && c != '-' && c != '_') {
            return false;
        }
    }
    return true;
}

static std::wstring find_agent_exe() {
    wchar_t home[MAX_PATH]{};
    if (GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH) > 0) {
        std::wstring pipx = std::wstring(home) + L"\\.local\\bin\\liveview-agent.exe";
        if (GetFileAttributesW(pipx.c_str()) != INVALID_FILE_ATTRIBUTES) {
            return pipx;
        }
    }
    wchar_t found[MAX_PATH]{};
    if (SearchPathW(nullptr, L"liveview-agent.exe", nullptr, MAX_PATH, found, nullptr) > 0) {
        return found;
    }
    return L"";
}

static std::pair<bool, std::string> run_agent(const std::string& verb, const std::string& game) {
    const std::wstring exe = find_agent_exe();
    if (exe.empty()) {
        return {false, "liveview-agent not found. Run liveview-agent install."};
    }
    std::wstring cmd = L"\"" + exe + L"\" " + widen(verb);
    if (verb == "start") {
        if (!safe_game_slug(game)) {
            return {false, "bad -game value"};
        }
        cmd += L" -game " + widen(game);
    }
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::wstring mutable_cmd = cmd;
    const DWORD flags = CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
    if (!CreateProcessW(
            exe.c_str(),
            mutable_cmd.data(),
            nullptr,
            nullptr,
            FALSE,
            flags,
            nullptr,
            nullptr,
            &si,
            &pi)) {
        return {false, "CreateProcess failed (" + std::to_string((unsigned)GetLastError()) + ")"};
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return {true, verb == "start" ? ("starting for " + game) : "stopping"};
}
#else
static std::pair<bool, std::string> run_agent(const std::string&, const std::string&) {
    return {false, "agent start is Windows-only"};
}
static std::string narrow(const std::wstring&) {
    return "";
}
static std::wstring find_agent_exe() {
    return L"";
}
#endif

static void on_lua_state_created(lua_State* l) {
    try {
        API::LuaLock _{};
        sol::state_view lua{l};
        sol::table t = lua.create_named_table("reflive");
        t["search_types"] = [](sol::this_state s, sol::object filter, sol::object max_n, sol::object offset) {
            return search_types(s, filter, max_n, offset);
        };
        t["search_singletons"] = [](sol::this_state s, sol::object filter, sol::object max_n, sol::object offset) {
            return search_singletons(s, filter, max_n, offset);
        };
        t["call_getters"] = [](sol::this_state s, sol::object addr, sol::object names) {
            return call_getters(s, addr, names);
        };
        t["crawl_fields"] = [](sol::this_state s, sol::object addr, sol::object cap) {
            return crawl_fields(s, addr, cap);
        };
        t["chain"] = [](sol::this_state s, sol::object spec) {
            return chain(s, spec);
        };
        t["summary"] = [](sol::this_state s, sol::object addr, sol::object cap) {
            return summary(s, addr, cap);
        };
        t["array_elements"] = [](sol::this_state s, sol::object addr, sol::object offset, sol::object count) {
            return array_elements(s, addr, offset, count);
        };
        t["resolve"] = [](sol::this_state s, sol::object addr) {
            return resolve_object(s, addr);
        };
        t["tdb_count"] = []() {
            return tdb_count();
        };
        t["ready"] = []() {
            return true;
        };
        t["agent_exe"] = []() {
            return narrow(find_agent_exe());
        };
        t["agent_start"] = [](sol::object game) {
            std::string slug = "mhwilds";
            if (game.valid() && game.is<std::string>()) {
                const auto value = game.as<std::string>();
                if (!value.empty()) {
                    slug = value;
                }
            }
            const auto result = run_agent("start", slug);
            return std::make_tuple(result.first, result.second);
        };
        t["agent_stop"] = []() {
            const auto result = run_agent("stop", "");
            return std::make_tuple(result.first, result.second);
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
    fn->log_info("[reflive] loaded — search / chain / agent_start");

    return true;
}
