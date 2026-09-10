# refcursor

Tiny REFramework plugin. Scripts can lock the same cursor path the Insert overlay uses, without opening that menu.

Drop `ref_cursor.dll` into any RE Engine game's `reframework/plugins` folder.

## Lua

```lua
if refcursor then
    refcursor.request(true)   -- show engine cursor, block SetCursorPos warps
    -- ...
    refcursor.request(false)  -- restore
end
```

`refcursor.is_requested()` is true while any request is held. Reset Scripts clears the lock.

## Build

This target lives in the REFramework tree so it links the same Lua REF uses.

1. Configure REFramework with the framework / 64-bit options you already use (`REF_BUILD_FRAMEWORK`).
2. Build the `ref_cursor` target (Visual Studio or `cmake --build . --target ref_cursor`).
3. Copy `bin/ref_cursor/ref_cursor.dll` (Release) to:

   `<game>\reframework\plugins\ref_cursor.dll`

4. Launch the game. REFramework log should say `[refcursor] loaded`.
5. Drop `test_refcursor.lua` into `reframework/autorun` (or run the snippet from the Script Editor). Insert can stay closed.

## What it does

- `user32!SetCursorPos` → `ret` while requested (skipped if Insert already patched it).
- `PostMessage(hwnd, WM_APP+1, show, 1)` so the engine shows its cursor.

It does not draw ImGui, open Insert, or replace `dinput8.dll`.
