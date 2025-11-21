# macOS PWA Integration Plan for Floorp

This document outlines the implementation plan for supporting Progressive Web Apps (PWAs) on macOS for Floorp. The implementation is inspired by Chromium's `os_integration` logic but adapted for Floorp's architecture (JavaScript-based OS integration via `OS.File`/`IOUtils`).

## 1. Objective

To allow Floorp PWAs to behave like native macOS applications. This involves creating a valid `.app` bundle structure, registering it with the OS, and handling the launch process so that the PWA appears with its own icon in the Dock and App Switcher (Cmd+Tab).

## 2. Reference Implementation (Chromium)

We have analyzed Chromium's implementation in `chrome/browser/web_applications/os_integration/mac`:

-   **`web_app_shortcut_creator.mm`**: Handles the creation of the `.app` directory structure, copying binaries, and updating resources.
-   **`bundle_info_plist.mm`**: Manages the `Info.plist` file, which is critical for the OS to recognize the app's identity.
-   **`app_shim_launch.mm`**: The native binary executable that acts as a bridge between the OS and the browser process.

## 3. Required Architecture: The `.app` Bundle

To achieve OS integration, we must programmatically generate the following directory structure for each installed PWA:

```text
~/Applications/Floorp Apps/<AppName>.app/
└── Contents/
    ├── Info.plist        # App metadata (ID, Name, Version)
    ├── PkgInfo           # "APPL????" string
    ├── MacOS/
    │   └── app_shim      # Executable script or binary to launch Floorp
    └── Resources/
        └── app.icns      # App icon (converted from manifest icons)
```

### 3.1. Info.plist Requirements

The `Info.plist` file determines how macOS treats the application. Key fields to generate:

| Key | Description | Value Example |
| :--- | :--- | :--- |
| `CFBundleDisplayName` | App Name | "My PWA" |
| `CFBundleIdentifier` | Unique App ID | `floorp.pwa.<unique_id>` |
| `CFBundleExecutable` | Executable Name | `app_shim` |
| `CFBundleIconFile` | Icon File Name | `app.icns` |
| `CFBundlePackageType` | Package Type | `APPL` |
| `LSUIElement` | Background App | `0` (False) for Dock presence |

**Crucial Note**: The `CFBundleIdentifier` must be unique and different from the main Floorp browser to ensure separate grouping in the Dock.

### 3.2. The Launch Shim

Chromium uses a compiled C++ binary (`app_mode_loader`). For the initial Floorp implementation, we can use a **Shell Script** as the executable in `Contents/MacOS/app_shim`.

**Draft Shell Script Content:**
```bash
#!/bin/bash
exec "/Applications/Floorp.app/Contents/MacOS/floorp" --start-ssb "APP_ID" "$@"
```

*Future consideration: Compile a small native binary if the shell script causes UX issues (e.g., terminal flashing).*

## 4. Security & Execution Requirements (High Priority)

macOS has strict security checks. Simply creating files is not enough; they must be trusted.

1.  **Remove Quarantine Attribute**:
    Files created by the browser are tagged with `com.apple.quarantine`. This prevents execution.
    *   **Action**: Execute `xattr -d com.apple.quarantine <path_to_app>` recursively after creation.

2.  **Executable Permissions**:
    The shim script must be executable.
    *   **Action**: Execute `chmod +x <path_to_shim>`.

3.  **Ad-hoc Code Signing**:
    On Apple Silicon (and recent macOS versions), executable binaries (even scripts in bundles) often require signing to run without error.
    *   **Action**: Execute `codesign --force --sign - <path_to_app>` to apply an ad-hoc signature.

## 5. Implementation Roadmap

### Phase 1: Bundle Structure Generator
Implement a `MacSupport` class in `browser-features/modules/modules/pwa/supports/Mac.sys.mjs`.
-   [ ] Implement `createAppBundle(manifest)` to generate folders.
-   [ ] Implement `writeInfoPList(manifest)` to generate the XML.
-   [ ] Create the shell script shim.

### Phase 2: Security Integration
-   [ ] Integrate `Subprocess.call` or equivalent to run `xattr`, `chmod`, and `codesign`.
-   [ ] Verify the app launches on both Intel and Apple Silicon Macs.

### Phase 3: Icon Processing
-   [ ] Implement logic to convert Web Icons (PNG) to `.icns` format, or use a simplified approach (setting the icon via file system attributes if `.icns` generation is too complex in pure JS).

### Phase 4: Advanced Integration
-   [ ] **File Handlers**: Add `CFBundleDocumentTypes` to `Info.plist`.
-   [ ] **Protocol Handlers**: Add `CFBundleURLTypes` to `Info.plist`.
-   [ ] **Uninstallation**: Listen for PWA removal events to delete the `.app` bundle.

