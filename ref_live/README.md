# reflive

Tiny REFramework plugin. Scripts can search the TDB and singleton lists the way UE4SS Live View searches `GUObjectArray` — Lua has no type iterator.

Drop `ref_live.dll` into any RE Engine game's `reframework/plugins` folder.

## Lua

```lua
if reflive then
    local types = reflive.search_types("OniSense, !Letter")
    local singles = reflive.search_singletons("Player")
    print(reflive.tdb_count())
end
```

Each row is `{ name, kind, type?, address? }`.

- `search_types` refuses an empty filter (no full TDB dump).
- Filters: comma = AND, `!term` = NOT, case-insensitive substring.
- No result cap — the filter is the only cut.

Call and field edit stay in Lua (`obj:call` / `obj:set_field`) once you pin a live object.

## Build

This target lives in the REFramework tree so it links the same Lua REF uses.

1. Configure REFramework with `REF_BUILD_FRAMEWORK` (64-bit).
2. Build the `ref_live` target.
3. Copy `bin/ref_live/ref_live.dll` (Release) to:

   `<game>\reframework\plugins\ref_live.dll`

4. Launch the game. REFramework log should say `[reflive] loaded`.

It does not draw ImGui, open Insert, or replace `dinput8.dll`.
