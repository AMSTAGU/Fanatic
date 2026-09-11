# Tools

## GenerateAppIcon.swift

Redraws the app icon and rewrites `Fan/Assets.xcassets/AppIcon.appiconset`.
The mark is generated rather than hand-drawn, so the blade shape stays editable:
adjust `blade`, `hub` or `rotorDiameter` at the bottom of the file and re-run.

```sh
swiftc -O Tools/GenerateAppIcon.swift -o /tmp/genicon
/tmp/genicon "$PWD/Fan/Assets.xcassets/AppIcon.appiconset"
```

macOS caches app icons. After rebuilding, refresh it with:

```sh
touch build/Fan.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister -f build/Fan.app
```
