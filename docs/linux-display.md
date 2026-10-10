# Linux display policy

Rivet is **Wayland-first** on Linux. Generated applications remain ordinary
GTK4 programs; Rivet does not introduce a display abstraction or a shared
cross-platform widget layer.

## Support levels

| Path | Policy | Evidence |
|---|---|---|
| Native Wayland | Primary Linux target | Required CI launch with `GDK_BACKEND=wayland` and no `DISPLAY` |
| X11 backend | Best-effort GTK compatibility | Allowed when the distribution's GTK build provides it; not a release gate |
| X11 application through XWayland | Best-effort ecosystem compatibility | Owned by the compositor and XWayland, not a Rivet-specific runtime path |

Rivet does not set `GDK_BACKEND` in a shipped application. GTK therefore uses
the session's native backend in the normal way, and users retain an X11 escape
hatch on distributions that still provide one. The release gate sets
`GDK_BACKEND=wayland` only to prove that the GTK host does not pass CI through
an accidental X11 fallback.

Keeping the compatibility path does not mean maintaining two Rivet renderers.
The same GTK4 host and generated C++ client run on both. Rivet should not add
new X11-only dependencies, APIs, or feature branches merely to preserve legacy
desktop behavior.

## Compositor-sensitive features

Wayland deliberately does not expose several global capabilities that X11
applications historically assumed. Screen capture, global shortcuts, window
activation, background startup, and similar features must use the applicable
XDG portal or compositor protocol and must report capability absence honestly.
Applications must not silently fall back to broad X11 privileges.

StatusNotifierItem tray integration remains available where a desktop hosts
it. Global hotkeys, always-on-top overlays, and other compositor-specific
features are not implied by the GTK4 host baseline.

## CI contract

The Linux round-trip workflow:

1. builds and stages a generated GTK4 application;
2. starts Weston with its headless backend;
3. unsets `DISPLAY` and selects `GDK_BACKEND=wayland`;
4. packages and verifies the application, including the launch-survival smoke.

This is a deterministic protocol check, not a substitute for hardware and
desktop coverage. Linux production graduation still requires install, upgrade,
GPU, input, scaling, portal, GNOME, and KDE evidence across the declared
distribution matrix.

## Distribution lifecycle matrix

Rivet's support promise follows vendor maintenance instead of accumulating an
unbounded list of historical images:

| Family | Qualification policy | Automated release evidence |
| --- | --- | --- |
| Ubuntu | Supported LTS releases while they receive standard security maintenance | Ubuntu 24.04: deb lifecycle and AppImage launch under headless native Wayland |
| Debian | Current stable release during Debian's regular support period | Debian 13 is the qualification target; it is not promoted until its install gate exists |
| Fedora | Current and previous Fedora releases while upstream still maintains them | Fedora 44: rpm install, launch, and uninstall under headless native Wayland |

The matrix is reviewed for every Rivet minor release. A distribution enters the
support table only after its native package is installed by the real package
manager, launched outside the build tree through `GDK_BACKEND=wayland` with no
`DISPLAY`, and cleanly removed. AppImage is tested independently because its
dependency closure and replacement policy differ from deb/rpm. CI uploads the
package-manager transcript, exact installed version, compositor log, and
application log so a failed gate can be reproduced rather than guessed at.

Fedora advances on its roughly thirteen-month upstream lifecycle; CI pins a
specific maintained release instead of using `fedora:latest`. Ubuntu LTS and
Debian stable advance only in a reviewable matrix change. X11/XWayland remains
outside this release matrix.

## Removal threshold

X11 compatibility can be removed when upstream GTK or the supported
distribution baseline no longer provides it, or when retaining it creates a
measured security, packaging, or maintenance cost. A desktop's choice to stop
offering an Xorg login session is not by itself that threshold: native Wayland
sessions can still host legacy X11 applications through XWayland, while GTK4
applications such as Rivet normally connect to Wayland directly.
