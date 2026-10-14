#!/bin/sh
# Assembles darger.app in the checkout and links it into ~/Applications, so darger
# opens from Spotlight, the Dock, Finder's "Open With" and `open -a darger`.
# The bundle's executable is a stub that runs the darger binary built here, so
# `nimble build` and M-x darger-update keep the app current without re-running this.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
[ -x "$root/darger" ] || { echo "make-app: build first (nimble build -d:release)" >&2; exit 1; }
app=$root/darger.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
cat > "$app/Contents/MacOS/darger" <<STUB
#!/bin/sh
# darger.app launcher (see macos/make-app.sh). Older LaunchServices passed -psn_*; drop it.
for a; do shift; case \$a in -psn_*) ;; *) set -- "\$@" "\$a";; esac; done
exec "$root/darger" "\$@"
STUB
chmod +x "$app/Contents/MacOS/darger"
mkdir -p "$HOME/Applications"
ln -sfn "$app" "$HOME/Applications/darger.app"
# Register the bundle so Spotlight and `open -a darger` know it at once.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -f "$app" >/dev/null 2>&1 || true
echo "darger.app -> $HOME/Applications/darger.app (runs $root/darger)"
