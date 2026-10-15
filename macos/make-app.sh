#!/bin/sh
# Assembles ~/Applications/darger.app from the darger binary built in this checkout, so
# darger opens from Spotlight, the Dock, Finder's "Open With" and `open -a darger`.
#
# The binary is copied into the bundle rather than run from the checkout: macOS lets
# LaunchServices start an executable that lives under ~/Documents (or Desktop, Downloads)
# only after a privacy prompt that never comes for an unsigned build, so the launch hangs
# before the first instruction. ~/Applications is outside those folders. The bundle's
# `darger` is a stub that tells the editor where the checkout is (DARGER_SOURCE, for
# M-x darger-update) and runs the copied binary. Run `nimble app` again after a
# `nimble build`; darger-update does so itself when started from the bundle.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
[ -x "$root/darger" ] || { echo "make-app: build first (nimble build -d:release)" >&2; exit 1; }
app=$HOME/Applications/darger.app
new=$app.new
rm -rf "$new"
mkdir -p "$new/Contents/MacOS" "$new/Contents/Resources"
cp macos/Info.plist "$new/Contents/Info.plist"
cp "$root/darger" "$new/Contents/MacOS/darger-bin"
cat > "$new/Contents/MacOS/darger" <<STUB
#!/bin/sh
# darger.app launcher (see macos/make-app.sh). Older LaunchServices passed -psn_*; drop it.
for a; do shift; case \$a in -psn_*) ;; *) set -- "\$@" "\$a";; esac; done
export DARGER_SOURCE="$root"
exec "\$(dirname "\$0")/darger-bin" "\$@"
STUB
chmod +x "$new/Contents/MacOS/darger"
# Swap the bundle in whole: a darger running from the old one keeps its mapped binary.
rm -rf "$app"
mv "$new" "$app"
rm -rf "$root/darger.app"  # an earlier layout kept the bundle here, linked from ~/Applications
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsregister" ] && "$lsregister" -f "$app" >/dev/null 2>&1 || true
echo "$app (source $root)"
