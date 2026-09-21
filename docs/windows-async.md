# Windows non-blocking API

Rivet's generated C++ client exposes two compatible styles for every RPC and shared State operation.

The historical API returns `std::future<T>` and remains available for existing code:

```cpp
rivet_app::API api(*backend);
auto value = api.increment(41).get();
```

For WinUI code, prefer the non-blocking completion companion. It returns the underlying RVT1 request id immediately, so the request can also be cancelled with `Backend::cancel(id)`:

```cpp
rivet_app::API api(*backend);
auto id = api.increment_async(
    41,
    [dispatcher](rivet_app::Result<std::int64_t> result) {
      try {
        auto value = result.get();
        dispatcher.TryEnqueue([value] {
          // Update WinUI here.
        });
      } catch (std::exception const& e) {
        // Surface the backend/decoding error.
      }
    });
```

Shared State gets the same generated surface, for example `get_counter_async(...)` and `set_counter_async(value, ...)`.

## Threading

RVT1 responses are decoded by Rivet's native reader thread. Normal completions therefore run on that reader thread. Submission failures or shutdown rejection may complete on the thread that encountered the failure. Completion handlers are deliberately **not UI-thread-affine**; dispatch through `DispatcherQueue` before touching WinUI objects.

Rivet isolates exceptions thrown by completion handlers so application callback bugs cannot terminate the transport reader. Type decoding happens before the generated completion is invoked, and decoding/backend errors are represented by `rivet_app::Result<T>`; calling `result.get()` rethrows the stored error.

The completion path does not create one native thread per RPC. It uses the same pending-request table, request ids, cancellation frames, reader thread, and shutdown behavior as the future path.

## Why this is not `IAsyncOperation<T>`

Rivet schema types include `Bytes`, recursive `List`, `Optional`, and `Any`. Mapping every possible generated type into a public WinRT ABI would force framework-specific container projections into the schema. The completion API keeps the generated C++ type model intact while making WinUI interaction non-blocking and cancellable. A future WinRT projection layer can be added separately without changing RVT1 or the Racket API.
