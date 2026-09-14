# Run Instructions
```
.\GenerateCsharpContracts.exe <args>

--yaml, -y                        [Required]:
                                  Path to the .yaml file that defines the contracts

--namespace, -n                   [Required]:
                                  Namespace on the generated classes and enums

--output, -o                      Path to the output directory (defaults to ".")

--models-directory                Directory and sub-namespace that the classes and enums will be generated into (defaults to "Models")
                                  Example: my-service/MyService.Shared/Models

--newtonsoft-version              Which Newtonsoft.Json version to install in the generated .csproj file (defaults to 13.0.4)

--nullable-disable                Toggle to disable nullable reference types.
                                  If this is passed in, the .csproj file will be .NET Standard 2.0 instead to be compatible
                                  with .NET Framework 4.8.

--sln-path, -s                    Optionally provide a path to a solution file.
                                  This path overrides the --output argument and will add the generated csproj to the solution.
                                  Assumes that `dotnet` is an available command.

--skip-csproj                     Skip .csproj file generation and create the C# files only.

--enums-omit-none                 By default, enums are generated with a `None` option with value 0 (default value in C#).
                                  Toggle this flag to disable this behavior.
                                  As a result, the first value in the enum list will be assigned value 0.
                                  Additionally, you can call out enums that you don't want this behavior applied to (--enum-behavior-except-for).
                                  Keep in mind, however, that flag enums will always declare `None = 0`.

--enum-behavior-except-for, -e    Call out any number of enums (comma or semicolon-delimited) that you don't want the blanket behavior for (whether or not we're generating `None = 0`).

Generates C# files from a .yaml contract file.
This creates the C# class/enum files that are defined in '#/components/schemas' in your .yaml file.
```

More specifically, this should generally work on creating the C# class/enum files that are defined in `'#/components/schemas'`.
Either Open API or Async API may define this section for model types, and that's all this code generator looks at.
Does not generate a swagger page or Open API .json spec file.
Does not generate .NET server boilerplate or client boilerplate—this is contracts-only.

See the help message with `.\GenerateCsharpContracts.exe`, `.\GenerateCsharpContracts.exe ?`, `.\GenerateCsharpContracts.exe --help`, or `.\GenerateCsharpContracts.exe -h`.

Example run commands (the output path will be created if it does not exist):
```
.\GenerateCsharpContracts.exe -y .\my-contracts.yaml -n MyService.Shared -o .\MyService.Shared
```
Run with solution path (overrides output and the resulting .csproj file will be added to the solution):
```
.\GenerateCsharpContracts.exe -y .\my-contracts.yaml -n MyService.Shared -s MyService.sln
```

# For The User
The aim of this code generator is to produce opinionated code as though it were written by hand.
That includes assuming nullable reference types unless opting out, disallowing nullable enum properties, and nicely-formatted code.

The generated code follows our project structure conventions:
The .sln file is expected to be at project's root with individual directories whose names mirror the .csproj files they contain.
The generated code takes the `--namespace` argument and creates a .csproj file with the name in the output directory.
Alternatively, if a path to a solution file is provided, then a directory matching the `--namespace` will be made first and then the matching .csproj file inside that.

The resulting C# files have `Models` appended to their namespace, generated into the `<namespace>/Models` directory (the name of the 'Models' directory and namespace can be overriden with the argument `--models-directory`):
```
my-service
├── MyService.sln
├── MyService
│   ├── MyService.csproj
│   └── Services
│       └── [*.cs]
└── MyService.Shared <-- created if doesn't exist
    ├── MyService.Shared.csproj <-- generated and added to solution if a solution path is provided
    └── Models
        └── [*.cs] <-- generated with namespace `MyService.Shared.Models`
```

## Formats And Features
Supported formats on integers are: `byte`, `int16`, `int32`, and `int64`.

Supported formats on numbers are `float` and `double`.

Supported formats on strings are: `uuid`, `uri`, `date-time`, and `datetime` (equivalent to `date-time`).

The type `dictionary` is allowed, where it is translated to `Dictionary<string, string?>`.

Enums also support flags, with the `bit-flag: true` property.

## Opinionated Generation
To opt out of nullable reference types, pass in the argument `--nullable-disable`.
As a result, the .csproj will be generated for `netstandard2.0`, since _the only reason to suppress nullable reference types should be for compatibility with .NET Framework 4.8._
That will reflect in the C# source files:
The `required` modifier goes away, and file-scoped namespacing is removed for the traditional curly-brace-denoted namespacing.

In regards to dictionaries, disallowing null values has historically been a thorn in our sides, specifically for Kafka contracts.
Nullable dictionary values are the default.
If non-nullable values are desired, then you can specify additional properties like so (or opt out of nullable reference types entirely):
```yaml
components:
  schemas:
    MyObj:
      properties:
        map:
          type: dictionary
          additionalProperties:
            type: string # will produce `Dictionary<string, string>`
```

Nullable enum properties are not allowed: This code generator assigns `None = 0` for flag and non-flag enums (subject to change).
0 is already recognized as the default enum value, which allows the user to make a decision when an enum property `== MyEnum.None`.
You can disable the `None = 0,` option with the flag `--enums-omit-none`.
If you do, the first item in the enum list will be assigned 0.
Nullable enums are still not allowed, as the generator assumes that the first item in the enum list is the default when `--enums-omit-none` is toggled.

The generated source files are produced without carriage returns.
These are added back in by git.
The files contain no tabs, but rather 4 spaces instead.

Nullable properties may have the `required` modifier, but they will not receive the `[Required]` attribute (subject to change).
The modifier forces a compile error if consuming code initializes the object without assigning _a_ value (even if that value is null).
The attribute, however, indicates to the API framework that a non-null value must be enforced, and these checks occur outside of the user's code.
With the framework already validating nullability, it doesn't make sense to force the user's code to have to suppress null reference warnings everywhere as a result.

## Pending Features
This code generator is not feature-complete:

Default values are not yet supported.
Data annotations are a work in progress. `Required`, `Url`, `MinLength`, and `MaxLength` are currently implemented.

No C# code is generated apart from the csproj file and contract classes/enums.
In the future, code for server-side controllers or client-side HttpClient/Kafka producer classes may be a possibility.

Regarding polymorphism, this generator creates `allOf` types by composing all of the properties that compose the `allOf` type (base class is applied in the event of 1 $ref in an `allOf` construct).
Generally, this generator will attempt to avoid inheritance by instead union-ing the composing properties into a single class.
`anyOf` and `oneOf` are not yet implemented, but plans are in place:
`anyOf` will be treated as equivalent to `oneOf`. Generally, using `anyOf` is discouraged.
`oneOf` will define a base class with each prong as an implementation.

# Build Instructions
1. Download latest stable version of [Zig](https://ziglang.org/download/). Currently, leverages 0.16.0. Earlier versions are not compatible.
2. After un-zipping, add the `zig` command to your `PATH` (or `$PATH`)
3. Go to the root directory of this repository
4. `zig build` - this builds the executable in Debug mode for your current architecture. You can specify different release modes with the `-Doptimize` argument (e.g. `-Doptimize=ReleaseSafe` with any of the following release modes: `Debug`, `ReleaseSafe`, `ReleaseFast`, or `ReleaseSmall`). For more info on the build system, see the [docs](https://ziglang.org/learn/build-system/#:~:text=Standard%20optimization%20options%20allow%20the,to%20create%20a%20release%20build).
For this service, I recommend `ReleaseSafe`:
```
zig build -Doptimize=ReleaseSafe
```

To modify the source code, VS code supports intellisense with the ZLS extension, or you can build it from source [here](https://github.com/zigtools/zls).

No unit tests have been written yet, and they would be greatly appreciated!
