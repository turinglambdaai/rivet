# Windows platform

WinUI 3 / C++/WinRT host and native adapters. Products consume Rivet through
one of the two contracts below; both compile the same authoritative source
list, so they can never disagree about what the Windows host library
contains.

## Packaged consumption (primary)

Reference the released library projects and link `rivet::host` — this is what
`raco rivet new` scaffolds and what the host template
([host/RivetHost.vcxproj](host/RivetHost.vcxproj)) ships:

```xml
<ItemGroup>
  <ProjectReference
    Include="$(RIVET_ROOT)\platform\windows\rivet-host.vcxproj"
    Properties="RivetRuntimeLibrary=MultiThreadedDLL" />
</ItemGroup>
```

The `Properties=` facet forwards the downstream CRT choice (MSVC rejects
mixed `RuntimeLibrary` across a static link, LNK2038). Rivet never appears in
your `<ClCompile>` list; adding a Rivet translation unit upstream cannot
break your build. `raco rivet build` supplies `RIVET_ROOT` and
`RIVET_RACKET_INCLUDE`.

## Transitional vendored sources

Until prebuilt static libraries are published for every channel (#238), a
host that compiles Rivet sources directly must import the shared property
sheet instead of re-listing sources:

```xml
<Import
  Project="$(RivetRoot)\platform\windows\rivet-runtime-sources.props" />
```

The props file is the single author of the `<ClCompile>` set;
[rivet-host.vcxproj](rivet-host.vcxproj) imports the same file, and
`rivet/tests/host-package-linkage.rkt` keeps it in step with
`runtime/CMakeLists.txt`. When Rivet adds a runtime translation unit, a
props re-sync is a file update, not a hunt through hand-copied
`<ClCompile>` lines (see issue #280 and the podlens `valid_utf8` LNK2001).

Override `RivetSourceRoot` when the import happens from a checkout rooted
somewhere other than two levels above the props file:

```xml
<PropertyGroup>
  <RivetSourceRoot>C:\path\to\rivet\</RivetSourceRoot>
</PropertyGroup>
<ItemDefinitionGroup>
  <ClCompile>
    <AdditionalIncludeDirectories>$(RivetSourceRoot)runtime\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
  </ClCompile>
</ItemDefinitionGroup>
```

Importers supply their own include directories, `/utf-8`, CRT selection, and
the Windows App SDK / C++/WinRT NuGet packages — the props intentionally
carries the source list only.

## Layout

- `device/` — device identity, session service, and Schannel transport
- `runtime/` — Racket embedding backend and Win32 pipe transport
- `system/` — WinRT system service adapter
- `update/` — installer handoff and lifecycle helpers
- `chart/` — `rivet-chart.vcxproj` chart control (optional, referenced
  separately)
- `host/` — the scaffolded WinUI executable template
