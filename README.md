# CDec

Luau bytecode decompiler. Deserializes bytecode with Iridium and lifts it back to readable Luau source. Runs on [Lune](https://github.com/lune-org/lune).

## Features

- Bytecode deserialization
- Lifts control flow: `if`/`elseif`/`else`, `while`, `repeat`, numeric `for`, generic `for`
- Closures, upvalues, varargs, `local function`
- Table constructors, method calls, concatenation, arithmetic and comparison folding
- Uses debug local names when the bytecode has them (`debugLevel = 2`), falls back to `v#` / `T#` / `U#`
- Falls back to a raw instruction listing if lifter fails

## Usage

- Terminal
```sh
lune run Example.luau <Input>
```

- In Game
```lua
  loadstring(game:HttpGet("https://github.com/RaiWorks-Official/CDec/releases/latest/download/CDec.luau"))()
  
  -- Once loaded, only run this
  decompile(script)
  -- or
  decompile("Bytecode")
```

## layout
```
 Main.luau -- Entry
 Example.luau -- Cli
 src
   Analyze.luau -- uhm
 library
   iridium -- deserializer
   Luau-Lifter -- Lifter
```

## Notes
- Lifter isnt finished, so without waiting for my update
- This was made with Claude Sonnet 5.5 Assistance so no need to investagate if this was vibecoded
### This is only for educational purposes only. i do not promote malicious or unethical use of this 
