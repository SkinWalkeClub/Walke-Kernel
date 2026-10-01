<p align="center">
  <img src="https://media.discordapp.net/attachments/1536026906015694938/1555027080616476702/image.png?backend=b2&ex=6abf0753&is=6abdb5d3&hm=d81fb37c3563ee47c99060b37c93ab96e6146b2b3d6c40a138480d45cd05b36a&=&format=webp&quality=lossless&width=1280&height=483" width="900" alt="Walke Serializer">
</p>

# Walke Kernel

A metatable control layer for your own client. It gives you one clean place to intercept how your client talks to the Roblox engine, instead of a pile of scripts all hooking the same metamethods and stepping on each other.

You add rules. A rule says "when this method is called, do this". Walke Kernel installs a single managed hook on the game metatable, runs your rules in order, and keeps the original behavior working for everything you did not touch.

## What it does

Almost everything a Roblox script does goes through a metamethod. `remote:FireServer(...)` goes through `__namecall`. Reading `part.Position` goes through `__index`. Walke Kernel hooks those once and routes every call through your rule list. For any call, a rule can:

- **log** it: record that it happened, with its arguments, then let it run normally.
- **block** it: stop the real call and return a value of your choice instead.
- **reroute** it: change the arguments, then call the real method with the new ones.
- **replace** it: run your own function, which gets the original so you can call it, transform its result, or ignore it.

Rules are checked top to bottom and the first one that matches wins. Everything that matches no rule passes straight through untouched.

## What it does NOT do

- **It works on your own client only.** It hooks your metatable, in your session. It does not reach the server or other players.
- **It is a framework, not a cheat.** It gives you the plumbing to intercept calls. What you do with that is on you.

## Requirements

Your executor needs `getrawmetatable` and, to unlock the metatable, `setreadonly`. It uses `hookmetamethod` when your executor has it, and falls back to a manual unlock-and-swap when it does not. `getnamecallmethod` is needed to see which method was called during `__namecall`. If `getrawmetatable` is missing, `hook` fails with a clear message instead of doing anything half-done.

## Load it

```lua
local Kernel = loadstring(game:HttpGet("https://raw.githubusercontent.com/SkinWalkeClub/Walke-Kernel/main/walkekernel.lua"))()
```

## Use it

```lua
local k = Kernel.new()

-- log every FireServer call
k:addRule({ id = "watch", method = "FireServer", action = "log" })

-- stop anything from kicking you, return nothing instead
k:addRule({ id = "antikick", method = "Kick", action = "block" })

-- install the hook on the game metatable
local ok, err = k:hook(game)
if not ok then warn("Walke Kernel: " .. err) end

-- later, see what happened
print(k:report())

-- when you are done
k:unhook()
```

## Rules

A rule is a table. It has a set of conditions and one action.

Match conditions (all that you set must hold):

- `method` - a method name, or a list of names, like `"FireServer"` or `{ "FireServer", "InvokeServer" }`
- `class` - the ClassName of the object, like `"RemoteEvent"`
- `name` - the object's Name
- `kind` - `"namecall"` for method calls or `"index"` for property reads
- `match` - a function `function(ctx) return true/false end` for anything custom

Actions:

- `action = "log"` - record and pass through
- `action = "block"` - do not call the original. Return `rule.returns` if set (a value, or a function `function(ctx, ...) return ... end`), otherwise nil.
- `action = "reroute"` - call the original with new arguments from `rule.remap = function(ctx, ...) return newArgs end`
- `action = "replace"` - run `rule.with = function(ctx, orig, self, ...) end`. You get `orig`, so you can call the real method, change its result, or skip it.

The `ctx` your functions receive has `method`, `class`, `name`, `kind`, `object`, `nargs`, and `fromExecutor` (whether the call came from your own script, when the executor supports `checkcaller`).

### Examples

Spy on remotes and print the arguments:

```lua
k:addRule({
    method = { "FireServer", "InvokeServer" },
    action = "replace",
    with = function(ctx, orig, self, ...)
        print(ctx.class, ctx.method, ...)
        return orig(self, ...)
    end,
})
```

Spoof a property read:

```lua
k:addRule({
    kind = "index",
    match = function(ctx) return ctx.method == "WalkSpeed" end,
    action = "replace",
    with = function() return 16 end,
})
```

Change an argument on the way out:

```lua
k:addRule({
    method = "FireServer",
    action = "reroute",
    remap = function(ctx, ...) return "safe", select(2, ...) end,
})
```

## Managing rules

```lua
local id = k:addRule({ method = "X", action = "log" })  -- returns the rule id
k:removeRule(id)   -- remove one rule
k:clearRules()     -- remove all rules
```

You can add and remove rules while the hook is live. You do not need to unhook to change behavior.

## Recursion is handled for you

This is the part that makes a metatable hook dangerous to write by hand. When your rule reads a property of the object, like `self.ClassName`, that read goes through `__index`, which is hooked, which could call your rule again, forever. Walke Kernel guards against this. While it is inside handling one call, any metamethod access from your rule or from the kernel's own bookkeeping goes straight to the original. So `self.ClassName` inside a rule gives you the real value and never loops.

The practical effect: you can read properties inside your rules freely. Just know that those reads see the real values, not other rules.

## API

```lua
Kernel.new()            -- create a registry
k:addRule(rule)         -- add a rule, returns its id
k:removeRule(id)        -- remove a rule by id
k:clearRules()          -- remove all rules
k:hook(target)          -- install the managed hook, returns (true) or (false, reason)
k:unhook()              -- restore the original metamethods
k:report()              -- a readable string: active state, hooks, rule count, recent activity
```

The registry also exposes `k.rules`, `k.log` (recent intercepted calls), `k.active`, `k.installed` (which metamethods are hooked), `k.maxLog`, and `k.logArgs` if you want to read or set them directly.

## Performance

`__index` fires constantly, sometimes thousands of times a frame in a busy game. Walke Kernel is built so the common case is cheap:

- When you have no rules, or the kernel is already inside handling a call, the intercepted call goes straight to the original with no extra work.
- A `log` rule is a direct pass-through. Once the call is recorded it tail-calls the original, with no protective wrapper around it, since a log rule has no callback of yours that could error. This keeps logging cheap and keeps the original's exact return values intact.
- The kernel only reads an object's ClassName and Name when at least one of your rules actually matches on `class`, `name`, or a custom `match` function. If all your rules match by `method` alone, those lookups are skipped entirely.
- The hook does not allocate a new closure on every call. Building the argument log only happens when a rule matches, and you can turn it off with `k.logArgs = false` if you want the leanest possible path (the call is still recorded, just without stringified arguments).

### Return values are preserved exactly

When a `block`, `reroute`, or `replace` rule runs your callback, the kernel wraps it so your rule can error without leaving the hook stuck. That wrapper preserves the exact number of return values, including a single `nil` or a trailing `nil`. This matters because a method like `thing:TryGet()` that legitimately returns `nil`, or one that returns `value, nil`, must keep that shape. A naive wrapper drops trailing nils and would turn a one-value `nil` return into zero values, which changes what the calling code sees. The kernel uses the arity-safe path so it does not.

The takeaway: keep your rules matching by `method` where you can, and the per-call cost stays low even in a render loop.

## Notes

- `hook(game)` is the usual target, but you can hook any object whose metatable you can reach.
- Only `__namecall` and `__index` are managed. Those cover method calls and property reads, which is the large majority of what scripts do.
- `unhook` restores the originals on both paths. On the manual path it puts the saved metamethods back directly. On the `hookmetamethod` path it re-hooks the saved originals through your executor, which is the correct way to undo a `hookmetamethod` install. After `unhook`, `k._restored` tells you which metamethods were put back.
- The log keeps the most recent 500 entries by default. Change `k.maxLog` if you want more or fewer.

## License

MIT. Weegee_MLG / The Skin Walke Team.
