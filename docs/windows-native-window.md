# Windows host integration

## Native window handle

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

For tray applications, do not reproduce the `SetWindowSubclass`,
`TaskbarCreated`, `TrackPopupMenu`, and `WM_COMMAND` recipe in each host.
`rivet::system::TrayController` owns that HWND-bound lifecycle. The application
still owns menu semantics by providing localized `TrayMenuItem` values and
callbacks; see the reference Taskboard's `MainWindow.xaml.cpp`.

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

## Non-blocking generated API

The generated C++ client exposes two compatible styles for every RPC and
shared State operation. The historical API returns `std::future<T>`:

```cpp
rivet_app::API api(*backend);
auto value = api.increment(41).get();
```

WinUI code should normally use the non-blocking completion companion. It
returns the RVT1 request ID immediately, which also permits cancellation with
`Backend::cancel(id)`:

```cpp
auto id = api.increment_async(
    41,
    [dispatcher](rivet_app::Result<std::int64_t> result) {
      try {
        auto value = result.get();
        dispatcher.TryEnqueue([value] {
          // Update WinUI here.
        });
      } catch (std::exception const& error) {
        // Surface the backend or decoding error.
      }
    });
```

Shared State has the same generated shape, such as
`get_counter_async(...)` and `set_counter_async(value, ...)`.

### Threading

RVT1 responses are decoded on Rivet's native reader thread. Normal completion
handlers therefore run there; submission failures or shutdown rejection may
complete on the thread that encountered the failure. Dispatch through
`DispatcherQueue` before touching WinUI objects. Rivet isolates exceptions
thrown by completion handlers, and `Result<T>::get()` rethrows backend or
decoding errors.

The completion path uses the existing pending-request table, request IDs,
cancellation frames, reader thread, and shutdown behavior; it does not create a
native thread per RPC. It intentionally does not return `IAsyncOperation<T>`:
projecting `Bytes`, recursive `List`, `Optional`, and `Any` through a public
WinRT ABI would force platform container policy into Rivet's schema.
