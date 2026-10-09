# Windows native window interop

WinUI 3 desktop features often need the native `HWND`: global hotkeys,
clipboard listeners, `SetWindowSubclass`, precise `SetWindowPos` placement,
tray icons, and other Win32 ownership APIs all use it.

Generated Rivet windows expose the supported bridge directly:

```cpp
HWND hwnd = WindowHandle();
```

From another window type, call the underlying helper after that window has
run `InitializeComponent`:

```cpp
#include "system_services.hpp"

HWND hwnd = rivet::system::NativeWindowHandle(window);
```

The helper uses the Windows App SDK `IWindowNative::get_WindowHandle` ABI and
turns a missing interop interface, failed HRESULT, or null handle into a normal
C++/WinRT exception. The scaffold owns the required
`microsoft.ui.xaml.window.h` include and Windows system-adapter include path,
so product code does not need to recreate projection-specific boilerplate.

Do not find the application's own window by title. `FindWindowW` is ambiguous
when another window has the same title, breaks after localization or title
changes, and races window creation. The WinUI object is the authority for its
native handle.

Use the handle on the UI thread unless the target Win32 API explicitly permits
cross-thread access. Remove listeners, subclasses, and registered hotkeys
before the owning window is destroyed; an `HWND` is not a lifetime-owning
reference.

Example:

```cpp
MainWindow::MainWindow() {
  InitializeComponent();
  auto const hwnd = WindowHandle();
  if (!::AddClipboardFormatListener(hwnd)) {
    winrt::throw_last_error();
  }
}
```
